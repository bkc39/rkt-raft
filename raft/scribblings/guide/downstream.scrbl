#lang scribble/manual
@(require "../utils.rkt")

@(define ev (make-downstream-eval))

@title[#:tag "downstream"]{Building on raft}

This chapter is for authors of native bindings: packages that run their own
C++ on raft's @tech{resources} and @tech{device arrays}. It builds the
@deftech{k-means canary} (@tt{downstream/kmeans-canary}), a minimal cuML
binding of @tt{ML::kmeans::fit}, @tt{ML::kmeans::predict} and
@tt{ML::Datasets::make_blobs}, whose tests check it against
@tt{cuml.cluster.KMeans} and fit it a thousand times to show memory stays
flat. The Racket names are in @racketmodname[raft/unsafe], the C side in
@secref["ref-unsafe-c"]. The examples need the canary's library, which
@tt{nix develop} builds and points @tt{RAFT_KMEANS_CANARY} at
(@secref["ref-unsafe"] says how to build it elsewhere).

@section[#:tag "downstream-client"]{k-means from Racket}

A user of the canary never touches a pointer:

@examples[#:eval ev #:label #f
(require kmeans-canary)
(define-values (X truth) (blobs 300 2 #:centers 3 #:cluster-std 0.6 #:seed 7))
(list (shape X) (dtype X) (layout X))
(define-values (centroids inertia n-iter) (kmeans-fit X #:n-clusters 3 #:seed 42))
(list (shape centroids) (dtype centroids))
(list (~r inertia #:precision '(= 2)) n-iter)
(define-values (labels score) (kmeans-predict centroids X))
(for/list ([k (in-range 3)])
  (count (lambda (label) (= label k)) (device-vector->list labels)))
]

@racket[blobs] makes points around random centres on the GPU, with their true
clusters in @racket[truth]; @racket[kmeans-fit] returns the centroids, the
inertia and the iteration count; @racket[kmeans-predict] labels each point.
The results are ordinary raft arrays on @racket[(current-device-resources)].

@python|{
import cupy as cp
from cuml.cluster import KMeans
from cuml.datasets import make_blobs

X, truth = make_blobs(n_samples=300, n_features=2, centers=3,
                      cluster_std=0.6, random_state=7)
X.shape, X.dtype, X.flags.f_contiguous   # ((300, 2), dtype('float32'), True)
km = KMeans(n_clusters=3, random_state=42).fit(X)
km.cluster_centers_.shape                # (3, 2)
round(float(km.inertia_), 2), km.n_iter_ # (236.38, 2)
labels = km.predict(X)
cp.bincount(labels).tolist()             # [111, 96, 93]
}|

The numbers differ because Python's @tt{make_blobs} has its own generator; on
the same data, init and seed, the canary's twin test finds the two agree.

@section[#:tag "downstream-cpp"]{The native library}

The C API is @tt{include/kmeans_canary.h}. Every function takes the handle
as @tt{void*} and arrays as @tt{const rr_view*}, and answers an @tt{int}
status. The listings are read from the canary's files when the manual is
built:

@excerpt["C" "downstream/kmeans-canary/include/kmeans_canary.h"
         "KC_API const char* kc_last_error(void);"
         "                  uint64_t seed, double* inertia, int32_t* n_iter);"]

Each entry point runs inside @tt{raftrkt::translate_exceptions}, which turns
a C++ throw into @tt{RR_ERROR}, with the message and kind in the canary's
per-thread @tt{error_slot} for @tt{kc_last_error} and
@tt{kc_last_error_kind}. The rest comes from the frozen headers:
@tt{handle_of} recovers the handle, @tt{device_scope} selects its device,
@tt{require_on_device} refuses an array on another device, and
@tt{sync_guard} synchronises the stream on every exit, so no array is handed
back while cuML's work on it still runs:

@excerpt["C++" "downstream/kmeans-canary/src/canary.cpp"
         "int kc_fit(void* handle, const rr_view* x, const rr_view* sample_weight,"
         "}"]

@tt{raftrkt::matrix_data} and @tt{raftrkt::vector_data} turn views into
typed pointers, refusing the wrong element type, layout or extents. The
canary calls cuML's @tt{int} overloads, so it also refuses extents that do
not fit an @tt{int}:

@excerpt["C++" "downstream/kmeans-canary/src/canary.cpp"
         "fit_result fit(const raft::handle_t& handle, const fit_arrays& arrays,"
         "}"
         #:before 1]

A refusal reaches the user as @racket[exn:fail:raft], prefixed with the
Racket procedure's name:

@examples[#:eval ev #:label #f
(eval:error (kmeans-fit (contiguous X #:layout 'col-major) #:n-clusters 3))
(eval:error (kmeans-fit (list*->device-matrix '((1 2) (3 4)) #:dtype 'int32)))
(eval:error (kmeans-fit X #:n-clusters 301))
]

cuML's Python copies or casts such input; the canary leaves that to its
caller.

@section[#:tag "downstream-build"]{The build}

The canary is a CMake project built against raft's flake: the headers and
their CMake package in @tt{packages.raft-dev}, and the RAPIDS libraries in
@tt{packages.rapids}. It does not link @tt{libraftrkt}; the handle, the views
and the ABI tag reach it from Racket at run time:

@excerpt["CMake" "downstream/kmeans-canary/CMakeLists.txt"
         "find_package(raftrkt CONFIG REQUIRED)"
         ")"]

cuML is imported as a plain library, because the wheel's CMake package asks
for Treelite and nvForest packages a run-time prefix lacks. Like
@tt{libraftrkt}, the library exports only its own @tt{kc_} entry points
(RAFT's and RMM's namespaces stay visible, so RMM's registry is shared),
hides its static CUDA runtime, and refuses undefined symbols:

@excerpt["CMake" "downstream/kmeans-canary/CMakeLists.txt"
         "add_library(kmeans_canary SHARED src/canary.cpp src/pool.cpp)"
         "kc_strict(kmeans_canary)"]

In the flake it is one more derivation over the same inputs:

@excerpt["Nix" "flake.nix"
         "      kmeansCanary = cudaPackages.backendStdenv.mkDerivation {"
         "      };"]

So the canary and @tt{libraftrkt} compile against the same headers and load
the same @tt{librmm.so}. A package outside this repository, such as the cuML
binding, takes raft's flake as an input and uses its @tt{packages.rapids} and
@tt{packages.raft-dev} the same way.

@section[#:tag "downstream-racket"]{The Racket module}

@tt{private/native.rkt} loads the library from @tt{RAFT_KMEANS_CANARY},
binds its functions, makes a @racket[status-checker], and checks the ABI tag
as it loads:

@excerpt["Racket" "downstream/kmeans-canary/kmeans-canary/private/native.rkt"
         "(define-ffi-definer define-kc"
         "        -> (values status inertia n-iter)))"]

@excerpt["Racket" "downstream/kmeans-canary/kmeans-canary/private/native.rkt"
         "(call/kc 'kmeans-canary"
         "(call/kc 'kmeans-canary (lambda () (kc-check-abi (raft-abi-pointer))))"]

@tt{main.rkt} is the public API. Each procedure allocates its outputs on the
resources it runs on and makes the call inside @racket[with-array-views],
whose @racket[#:resources] clause binds the handle:

@excerpt["Racket" "downstream/kmeans-canary/kmeans-canary/main.rkt"
         "(define (kmeans-fit X"
         "  (values centroids inertia n-iter))"]

A @racket[#:init] matrix is copied into the centroids and its rows set the
cluster count; @racket[#:n-clusters] is ignored. An absent
@racket[sample-weight] is @racket[#f], which reaches C as @tt{NULL}. Equal
weights change nothing:

@examples[#:eval ev #:label #f
(define ones (flvector->device-vector (make-flvector 300 1.0) #:dtype 'float32))
(define-values (weighted-centroids weighted weighted-iterations)
  (kmeans-fit X #:n-clusters 3 #:seed 42 #:sample-weight ones))
(< (abs (- weighted inertia)) (* 1e-4 inertia))
]

@python|{
# cuml/cluster/kmeans.pyx, KMeans.fit, abridged
handle = self.handle if self._multi_gpu else get_handle()
cdef handle_t* handle_ = <handle_t *><size_t>handle.getHandle()
cdef lib.KMeansParams params
_kmeans_init_params(self, params)
n_iter = _kmeans_fit(handle_[0], params, X, sample_weight, centers)
# _kmeans_fit passes <float *>X.data.ptr and <int>n_rows to lib.fit
}|

cuML's Cython passes raw pointers after checking in Python; a Racket binding
passes a descriptor that the C++ checks.

@section[#:tag "downstream-lifetimes"]{Lifetimes and streams}

A native call borrows three things from Racket.

@bold{The arrays.} @racket[with-array-views] holds every array reachable
until its body exits, then clears the views, so a view kept by mistake holds
a @tt{NULL} pointer and device @racket[-1], which the C side refuses:

@examples[#:eval ev #:label #f
(define kept (with-array-views ([c centroids]) c))
(list (ptr-ref kept _pointer) (ptr-ref kept _int32 'abs 16))
]

@bold{The handle.} A pointer from @racket[resources->handle-pointer] does not
hold its resources, whose finalizer frees the handle. A binding takes it with
@racket[#:resources], which holds them for the call.

@bold{The stream.} @racket[with-array-views] waits for each array's queued
work before it binds the views, and @tt{sync_guard} synchronises on every
exit, so arrays from any resources work:

@examples[#:eval ev #:label #f
(define-values (X2 truth2)
  (with-device-resources ([r (device-resources)])
    (blobs 50 2 #:centers 2 #:seed 1 #:resources r)))
(define-values (c2 inertia2 n-iter2) (kmeans-fit X2 #:n-clusters 2))
(shape c2)
]

The first raft resources on a device install RMM's CUDA async memory
resource as current, and cuML allocates its scratch memory from the current
resource, so k-means' workspace comes from raft's pool and returns to it:

@examples[#:eval ev #:label #f
(require kmeans-canary/pool)
(canary-current-is-async?)
(define-values (in-use high-before reserved-before) (canary-pool-bytes))
(canary-pool-reset-high!)
(define-values (c3 inertia3 n-iter3) (kmeans-fit X #:n-clusters 3 #:seed 42))
(define-values (after peak reserved-after) (canary-pool-bytes))
(list (> peak in-use) (> peak after))
]

This needs RMM's per-device registry to be one symbol shared by
@tt{libkmeans_canary.so} and @tt{libcuml.so}, which the canary's tests check
(#10).

@python|{
import rmm
rmm.mr.get_current_device_resource()
# <rmm.pylibrmm.memory_resource._memory_resource.CudaMemoryResource ...>
}|

In Python, cuML uses plain @tt{cudaMalloc} until the program sets a resource.

@section[#:tag "downstream-abi"]{Versions in lockstep}

RAFT has no versioned C++ namespace, and @tt{raft::handle_t}'s layout changes
between releases, so a library that receives a handle must be compiled
against the same RAFT, RMM and CCCL headers as @tt{libraftrkt}. The ABI tag
makes a mismatch fail at load:

@examples[#:eval ev #:label #f
(raft-abi)
]

The canary compares @tt{raftrkt::compiled_abi()} with the tag its Racket
module passes in with @racket[raft-abi-pointer]:

@excerpt["C++" "downstream/kmeans-canary/src/canary.cpp"
         "int kc_check_abi(const rr_abi_tag* loaded) {"
         "}"]

A mismatch stops @racket[(require kmeans-canary)], naming the first field
that differs. The tag compares release numbers and the handle's size, and
says nothing of the RAFT that @tt{libcuml.so} was built with; hence the rule
is one @tt{rapids} package set, not merely matching tags.

Python has no such check: pip enforces each wheel's pinned versions at
install time.

@section[#:tag "downstream-next"]{What is frozen, and what comes next}

ABI version 1 freezes the interface the canary uses (@secref["ref-unsafe-c"]
lists it). A change bumps the version in @racket[raft-abi] and the canary in
the same pull request, so a stale library is refused at load.

The cuML binding is its own package, which takes raft's flake as an input
and follows the canary's pattern. It starts by growing the canary into a
full k-means binding (@tt{fit_predict}, @tt{transform}, the @tt{int64_t}
overloads), then adds DBSCAN, agglomerative clustering and HDBSCAN.

Three things change around it without changing this interface: contracts
arrive in a later leg; the stream API (@status{L2, #13}) will let chained
calls skip the synchronisation on each exit; and a long call, which
@racket[status-checker] runs in atomic mode, will learn to release the place
(#21).
