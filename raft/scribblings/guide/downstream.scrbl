#lang scribble/manual
@(require "../utils.rkt")

@(define ev (make-downstream-eval))

@title[#:tag "downstream"]{Building on raft}

This chapter is for authors of native bindings: a Racket package that runs its
own C++ on raft's @tech{resources} and @tech{device arrays}. The first such
package will bind cuML, whose algorithms take a @tt{raft::handle_t} and raw
device pointers; the chapter builds a small one, the @deftech{k-means canary},
which lives in this repository under @tt{downstream/kmeans-canary}. It binds
three cuML functions (@tt{ML::kmeans::fit}, @tt{ML::kmeans::predict} and
@tt{ML::Datasets::make_blobs}) and nothing else, and it exists to prove the
interface works: its tests run k-means against @tt{cuml.cluster.KMeans} on the
same data, and fit it a thousand times to show memory stays flat.

The chapter starts with what the canary's users write, then builds the canary
from the C++ up: the native library, its build, its Racket module, and the
two rules a binding must keep, about lifetimes and about versions. It ends
with what is frozen and how the cuML binding will grow from here. The
Racket-side names are in @racketmodname[raft/unsafe]; the C side is in
@secref["ref-unsafe-c"].

The examples need the canary's native library, which @tt{nix develop} builds
and points @tt{RAFT_KMEANS_CANARY} at; @secref["ref-unsafe"] says how to build
it elsewhere.

@section[#:tag "downstream-client"]{k-means from Racket}

A user of the canary makes data, fits k-means to it and labels the points,
without touching a pointer:

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

@racket[blobs] makes 300 points around three random centres with
@tt{ML::Datasets::make_blobs}, on the GPU, with their true cluster in
@racket[truth]. @racket[kmeans-fit] runs @tt{ML::kmeans::fit} with cuML's
default initialisation (scalable k-means++) and returns the centroids, the
inertia (the sum of squared distances to the nearest centroid) and the number
of iterations. @racket[kmeans-predict] labels each point with its nearest
centroid. The results are ordinary raft arrays, allocated through
@racket[(current-device-resources)] like any other.

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

The numbers differ because the data does: Python's @tt{make_blobs} is written
in CuPy with its own generator, and returns column-major data and
@tt{float32} labels, where the canary binds the C++ @tt{make_blobs} and
returns row-major data and @racket['int32] labels. The k-means calls are the
same: given the same data, init and seed, the canary and @tt{KMeans} agree
exactly, which the canary's twin test checks on eight data sets (adjusted
Rand index 1, inertia and centroids within @racket[1e-4]). Two smaller
differences: @tt{KMeans} draws a random seed when @tt{random_state} is
@tt{None}, where @racket[kmeans-fit]'s @racket[#:seed] defaults to 0; and
@tt{fit} also computes @tt{labels_}, which the canary leaves to
@racket[kmeans-predict].

@section[#:tag "downstream-cpp"]{The native library}

The canary's C API is a header, @tt{include/kmeans_canary.h}. Every function
takes the handle as @tt{void*}, arrays as @tt{const rr_view*}, and answers an
@tt{int} status, the conventions @tt{libraftrkt}'s own entry points use:

@listing["C"]|{
#include "raftrkt/abi.h"
#include "raftrkt/array.h"

KC_API const char* kc_last_error(void);
KC_API int kc_last_error_kind(void);

KC_API int kc_check_abi(const rr_abi_tag* loaded);

KC_API int kc_fit(void* handle, const rr_view* x, const rr_view* sample_weight,
                  const rr_view* centroids, int32_t init, int32_t max_iter,
                  double tol, int32_t n_init, double oversampling_factor,
                  uint64_t seed, double* inertia, int32_t* n_iter);
}|

Each entry point is a C function whose body runs inside
@tt{raftrkt::translate_exceptions} (from @tt{raftrkt/error.hpp}), so no C++
exception crosses into Racket: a throw becomes @tt{RR_ERROR}, with the message
and its kind in the canary's own per-thread @tt{raftrkt::error_slot}.
@tt{kc_last_error} and @tt{kc_last_error_kind} read that slot. The body
recovers the handle, selects its device, and checks that every array is on
it:

@listing["C++"]|{
int kc_fit(void* handle, const rr_view* x, const rr_view* sample_weight,
           const rr_view* centroids, int32_t init, int32_t max_iter,
           double tol, int32_t n_init, double oversampling_factor,
           uint64_t seed, double* inertia, int32_t* n_iter) {
  return raftrkt::translate_exceptions(kc::last_error_slot(), [&] {
    auto& inertia_out = *raftrkt::require(inertia, "inertia");
    auto& n_iter_out = *raftrkt::require(n_iter, "n_iter");
    inertia_out = 0;
    n_iter_out = 0;
    const raft::handle_t& h = kc::handle_of(handle);
    const kc::device_scope scope{raft::resource::get_device_id(h)};
    kc::require_device({x, sample_weight, centroids});
    const fit_options options{init, max_iter, tol, n_init, oversampling_factor,
                              seed};
    on_floats(x, "X", [&](auto tag) {
      fit<decltype(tag)>(h, x, sample_weight, centroids, options, inertia_out,
                         n_iter_out);
    });
    raft::resource::sync_stream(h);
  });
}
}|

The work is in a template over the element type. The views become typed
pointers through @tt{raftrkt::matrix_data} and @tt{raftrkt::vector_data}
(from @tt{raftrkt/view.hpp}), which refuse a view of the wrong element type,
layout or extents before cuML sees it. cuML's @tt{int} overloads take the
extents, so the views are read with an @tt{int} index, which refuses extents
that do not fit one:

@listing["C++"]|{
template <typename T>
void fit(const raft::handle_t& handle, const rr_view* x,
         const rr_view* sample_weight, const rr_view* centroids,
         const fit_options& options, double& inertia, int32_t& n_iter) {
  const T* data =
      raftrkt::matrix_data<const T, int>(x, "X", layout::row_major);
  const int n = static_cast<int>(x->shape[0]);
  const int d = static_cast<int>(x->shape[1]);
  T* centers = raftrkt::matrix_data<T, int>(centroids, "centroids",
                                            layout::row_major,
                                            raftrkt::any_extent, d);
  const int k = clusters_in(*centroids);
  ...
  ML::kmeans::KMeansParams params = params_for(k);
  params.init = init_method(options.init);
  params.rng_state.seed = options.seed;
  ...
  ML::kmeans::fit(handle, params, data, n, d, w, centers, result, iterations);
}
}|

What the checks refuse reaches the user as @racket[exn:fail:raft], with the
name of the Racket procedure in front of the canary's message. cuML's k-means
reads row-major data, so a column-major copy is refused, as is data cuML has
no k-means for:

@examples[#:eval ev #:label #f
(eval:error (kmeans-fit (contiguous X #:layout 'col-major) #:n-clusters 3))
(eval:error (kmeans-fit (list*->device-matrix '((1 2) (3 4)) #:dtype 'int32)))
(eval:error (kmeans-fit X #:n-clusters 301))
]

The cuML wrapper converts instead: @tt{KMeans.fit} copies Fortran-order input
into C order and casts integer input to @tt{float32}, before its Cython hands
cuML a raw pointer. The canary leaves the choice to its caller, who can call
@racket[contiguous] on purpose, because a binding that copies silently hides
a cost the caller cannot see.

@section[#:tag "downstream-build"]{The build}

The canary is a CMake project. It needs three things from raft's flake: the
headers, which @tt{packages.raft-dev} ships with a CMake package; the RAPIDS
package set, @tt{packages.rapids}, which holds RAFT, RMM, cuML and the
libraries cuML loads; and the CUDA packages both were built with. It does not
link @tt{libraftrkt}; the handle, the views and the ABI tag reach it from
Racket at run time:

@listing["CMake"]|{
find_package(raftrkt CONFIG REQUIRED)
find_package(CUDAToolkit REQUIRED)
find_library(CUML_LIBRARY NAMES cuml REQUIRED)
find_path(CUML_INCLUDE_DIR cuml/cluster/kmeans.hpp REQUIRED)

add_library(kmeans_canary SHARED src/canary.cpp src/pool.cpp)
set_target_properties(kmeans_canary PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_link_libraries(kmeans_canary PRIVATE raftrkt::headers cuml_runtime)
target_link_options(kmeans_canary PRIVATE "LINKER:--exclude-libs,ALL"
                                          "LINKER:--no-undefined")
}|

@tt{raftrkt::headers} brings @tt{raft::raft}, and with it RMM, CCCL and the
CUDA runtime headers, from the same RAPIDS prefix. cuML is linked as a plain
library because the cuML wheel's own CMake package asks for Treelite and
nvForest packages that a run-time prefix does not carry. In the flake, the
canary is one more derivation over the same inputs:

@listing["Nix"]|{
kmeansCanary = cudaPackages.backendStdenv.mkDerivation {
  pname = "kmeans-canary";
  src = canarySource;
  buildInputs = [ rapids shim shim.dev pkgs.gtest ] ++ cudaDevLibs;
  ...
};
}|

The point of taking @tt{rapids} from raft's flake is that there is only one:
the canary and @tt{libraftrkt} compile against the same RAFT, RMM and CCCL
headers, byte for byte, and load the same @tt{librmm.so}. A package outside
this repository, such as the cuML binding, takes raft's flake as an input and
uses its @tt{packages.rapids} and @tt{packages.raft-dev} the same way.

@section[#:tag "downstream-racket"]{The Racket module}

The canary's Racket side is two modules in the @tt{kmeans-canary} package.
@tt{private/native.rkt} loads the library, binds its functions, makes a
checker for their status, and checks the ABI tag as the module loads:

@racketblock[
(define canary-library (ffi-lib (getenv "RAFT_KMEANS_CANARY")))
(define-ffi-definer define-kc canary-library
  #:make-c-id convention:hyphen->underscore)

(define-kc kc-last-error (_fun -> _bytes/nul-terminated))
(define-kc kc-last-error-kind (_fun -> _int))
(define call/kc (status-checker kc-last-error kc-last-error-kind))

(define-kc kc-check-abi (_fun _pointer -> _int))
(define-kc kc-fit
  (_fun _pointer _pointer _pointer _pointer _int32 _int32 _double _int32
        _double _uint64
        (inertia : (_ptr o _double)) (n-iter : (_ptr o _int32))
        -> (status : _int)
        -> (values status inertia n-iter)))

(call/kc 'kmeans-canary (lambda () (kc-check-abi (raft-abi-pointer))))
]

@racket[status-checker] turns a non-zero status into @racket[exn:fail:raft]
with the canary's message and kind, read in the same atomic section as the
call, and returns the other results on success. @tt{main.rkt} is the public
API. Each procedure allocates its outputs with raft's constructors, on the
resources it runs on, takes the handle with
@racket[resources->handle-pointer], and passes the arrays through
@racket[with-array-views]:

@racketblock[
(define (kmeans-fit X
                    #:n-clusters [n-clusters 8]
                    #:init [init 'scalable-k-means++]
                    ...
                    #:sample-weight [sample-weight #f]
                    #:resources [resources (current-device-resources)])
  (define centroids (initial-centroids X init n-clusters resources))
  ...
  (define handle (resources->handle-pointer resources))
  (define-values (inertia n-iter)
    (with-array-views ([x X] [w sample-weight] [c centroids])
      (call/kc 'kmeans-fit
               (lambda ()
                 (kc-fit handle x w c code max-iter (exact->inexact tol)
                         runs factor seed)))))
  (values centroids inertia n-iter))
]

The optional @racket[sample-weight] needs no special case:
@racket[with-array-views] binds @racket[#f] to @racket[#f], which reaches C
as @tt{NULL}. Sample weights work like cuML's: weighting every point equally
changes nothing.

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

cuML's own Python wrapper does the same three things in Cython: it takes a
@tt{handle_t*} from a pylibraft @tt{DeviceResources} (@tt{getHandle()}),
passes raw device pointers and counts, and lets Cython's @tt{except +} turn a
C++ exception into a Python one. The differences are where the checks live.
cuML checks shapes and dtypes in Python before the call (@tt{check_inputs}),
and its C++ trusts the pointers it gets. A Racket binding passes a descriptor,
and the C++ checks it, so a binding cannot pass an array cuML would misread.

@section[#:tag "downstream-lifetimes"]{Lifetimes and streams}

A native call borrows three things from Racket, and each has a rule.

@bold{The arrays.} The views point into device memory that each array's
finalizer frees. @racket[with-array-views] keeps every array reachable until
its body returns, so no collection during the call can free what the call
reads, and clears the views when the body exits, so a view kept by mistake
holds a @tt{NULL} pointer and device @racket[-1], which the C side refuses,
instead of an address that may since have been freed:

@examples[#:eval ev #:label #f
(define kept (with-array-views ([c centroids]) c))
(list (ptr-ref kept _pointer) (ptr-ref kept _int32 'abs 16))
]

@bold{The stream.} raft queues work asynchronously on each resources
object's own stream. @racket[with-array-views] waits, by polling, until the
work queued on each array's stream has finished before it binds the views,
so the canary's call may run on any stream and still see finished data. In
the other direction, the canary synchronises its handle's stream before it
returns, so its outputs are finished when the Racket procedure returns.
Arrays allocated on other resources work the same way:

@examples[#:eval ev #:label #f
(define-values (X2 truth2)
  (with-device-resources ([r (device-resources)])
    (blobs 50 2 #:centers 2 #:seed 1 #:resources r)))
(define-values (c2 inertia2 n-iter2) (kmeans-fit X2 #:n-clusters 2))
(shape c2)
]

@bold{The handle.} The pointer from @racket[resources->handle-pointer] is
valid while its resources are unreleased. The canary allocates its outputs on
the resources it runs on, and every array holds its resources' handle alive,
so a call on the arrays' own resources always has a live handle.

The memory itself comes from one pool. The first raft resources on a device
install RMM's CUDA async memory resource as the device's current resource,
and cuML allocates its scratch memory from whatever resource is current, so
k-means' workspace is drawn from the same pool as raft's arrays and is
returned to it. The canary carries a probe for this, which its tests use:

@examples[#:eval ev #:label #f
(require kmeans-canary/pool)
(canary-current-is-async?)
(define-values (in-use high-before reserved-before) (canary-pool-bytes))
(canary-pool-reset-high!)
(define-values (c3 inertia3 n-iter3) (kmeans-fit X #:n-clusters 3 #:seed 42))
(define-values (after peak reserved-after) (canary-pool-bytes))
(list (> peak in-use) (> peak after))
]

The pool's peak during the fit was above its use before and after: cuML's
scratch memory came from the pool raft installed, and went back to it. This
works because RMM's
per-device registry is shared by every library in the process; it is a
GNU-unique symbol, which the canary's tests find in both
@tt{libkmeans_canary.so} and @tt{libcuml.so} (#10). The canary's memory test
fits a thousand times and checks that the pool's use returns to where it
started and that every buffer the fits allocated was freed.

@python|{
import rmm
rmm.mr.get_current_device_resource()
# <rmm.pylibrmm.memory_resource._memory_resource.CudaMemoryResource ...>
}|

In Python nothing installs a pool: cuML allocates from RMM's initial
resource, plain @tt{cudaMalloc}, until the program sets another with
@tt{rmm.mr.set_current_device_resource}.

@section[#:tag "downstream-abi"]{Versions in lockstep}

RAFT has no versioned C++ namespace, and the layout of @tt{raft::handle_t}
changes between releases. A native library that receives a handle from
@tt{libraftrkt} must have been compiled against identical RAFT, RMM and CCCL
headers, which is why the canary builds against raft's own @tt{rapids}. The
ABI tag makes a mismatch fail at load instead of corrupting memory later.
@racket[raft-abi] shows the tag:

@examples[#:eval ev #:label #f
(raft-abi)
]

The canary's C++ computes the tag of the headers it was compiled against,
with @tt{raftrkt::compiled_abi()}, and compares it with the tag
@tt{libraftrkt} reports, which its Racket module passes in with
@racket[raft-abi-pointer] as it loads:

@listing["C++"]|{
int kc_check_abi(const rr_abi_tag* loaded) {
  return raftrkt::translate_exceptions(
      kc::last_error_slot(), [&] { raftrkt::require_abi(loaded); });
}
}|

A mismatch stops @racket[(require kmeans-canary)] with a message naming the
first field that differs, such as @tt{kmeans-canary: RAFT: built against
26.08.00, but libraftrkt has 26.10.00; build both against the same rapids
package set}; the examples of @racket[raft-abi-pointer] provoke one. Python has no such
check: each RAPIDS wheel pins the others' versions (@tt{libcuml-cu13} 26.8.0
requires @tt{libraft-cu13==26.8.*}), and pip enforces it at install time.

@section[#:tag "downstream-next"]{What is frozen, and what comes next}

The interface the canary uses is frozen at ABI version 1: the C structs and
entry points of @secref["ref-unsafe-c"], the headers @tt{raftrkt/view.hpp},
@tt{raftrkt/error.hpp} and @tt{raftrkt/abi.h}, and the four exports of
@racketmodname[raft/unsafe]. Changing any of them changes the version in
@racket[raft-abi] and the canary, in the same pull request, so a downstream
library built against the old interface is refused when it loads rather than
misreading a struct.

The cuML binding will grow from the canary. It is its own package and
repository, which takes raft's flake as an input for @tt{packages.rapids} and
@tt{packages.raft-dev}, and its native library follows the canary's pattern:
an @tt{error_slot}, @tt{translate_exceptions} around each entry point, views
checked by @tt{view.hpp}, outputs allocated with raft's constructors on the
resources the call runs on. Its first leg turns the canary into a full k-means
binding (@tt{fit_predict} and @tt{transform} as well), and then DBSCAN,
agglomerative clustering and HDBSCAN follow (the plan's section 12).

Two things will change around it without changing this interface. Contracts
on raft's procedures, and on the binding's, arrive in a later leg, until when
a wrong kind of argument may surface Racket's or the FFI's own errors. And the
stream API (@status{L2, #13}) will let a binding queue work on an array's
stream and record an event instead of waiting, so a chain of cuML calls need
not synchronise between each; until then, @racket[with-array-views] waits and
the binding synchronises before it returns.
