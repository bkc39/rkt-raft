#lang scribble/manual
@(require "../utils.rkt")

@(define ev (make-downstream-eval))

@title[#:tag "ref-unsafe"]{Downstream interface: @racketmodname[raft/unsafe]}

@defmodule[raft/unsafe]

This module is for authors of native bindings that run their own C++ on
raft's resources and arrays: a cuML binding, a custom kernel, a solver from
another CUDA library. It hands such a binding the three things a native call
needs, the @tt{raft::handle_t} to run on, a descriptor for each array, and a
way to turn the native library's error status into @racket[exn:fail:raft],
plus the ABI tag the native library checks when it loads.
@racketmodname[raft] does not re-export it.

It is unsafe in the sense of @racketmodname[ffi/unsafe]: these procedures hand
out raw pointers, and nothing checks that a downstream binding declares its
foreign functions to match its C code. A binding that passes a view where its
C function expects a handle crashes the process. The C side checks what memory
safety needs (the headers in @secref["ref-unsafe-c"] refuse a view of the wrong
element type, layout or extents), but it cannot check a pointer's type.

The guide chapter @secref["downstream"] builds the k-means canary, a minimal
cuML binding, on this module step by step. @bold{This interface is frozen}
at ABI version 1: the four exports below, the C declarations in
@secref["ref-unsafe-c"] and the three C++ headers. Any change to them bumps
the version in @racket[raft-abi], and the canary with it.

@bold{Running these examples.} The examples call the canary's native library,
@tt{libkmeans_canary.so}, the way a downstream binding calls its own.
@tt{nix develop} builds it (the flake's @tt{packages.kmeans-canary}) and sets
@tt{RAFT_KMEANS_CANARY} to its path. To render the manual anywhere else, build
it with @tt{nix build .#kmeans-canary} and set @tt{RAFT_KMEANS_CANARY} to
@tt{result/lib/libkmeans_canary.so}; without it, rendering these pages fails.

The examples share the bindings a downstream module writes for the canary's
C functions, which follow the @tt{rr_} conventions: an @tt{int} status, the
error in a per-thread slot, out-parameters for results.

@examples[#:eval ev #:label #f
(define canary (ffi-lib (getenv "RAFT_KMEANS_CANARY")))
(define-ffi-definer define-kc canary #:make-c-id convention:hyphen->underscore)
(define-kc kc-last-error (_fun -> _bytes/nul-terminated))
(define-kc kc-last-error-kind (_fun -> _int))
(define-kc kc-check-abi (_fun _pointer -> _int))
(define-kc kc-make-blobs
  (_fun _pointer _pointer _pointer _int32 _double _int32 _double _double _uint64 -> _int))
(define-kc kc-fit
  (_fun _pointer _pointer _pointer _pointer _int32 _int32 _double _int32 _double _uint64
        (inertia : (_ptr o _double)) (n-iter : (_ptr o _int32))
        -> (status : _int) -> (values status inertia n-iter)))
(define-kc kc-predict
  (_fun _pointer _pointer _pointer _pointer _int32 _pointer (inertia : (_ptr o _double))
        -> (status : _int) -> (values status inertia)))
]

Handles and views cross as plain @racket[_pointer]s; the C side gives them
their types.

@section[#:tag "ref-unsafe-status"]{Checking native calls}

@defproc[(status-checker [last-error (-> (or/c bytes? string?))]
                         [last-error-kind (-> exact-integer?)]
                         [#:exn exn
                                (-> string? continuation-mark-set? symbol? exn?)
                                exn:fail:raft])
         (-> symbol? (-> any) any)]{

Returns a procedure @racket[(check who thunk)] for the calls into one native
library. @racket[check] calls @racket[thunk], whose first result is the C
status: @racket[0] (@tt{RR_OK}) on success. On success @racket[check] returns
the thunk's other results. On any other status it reads the library's error
message with @racket[last-error] and its kind with @racket[last-error-kind],
and raises @racket[(exn message marks kind)], where the message is
@racket[who], a colon and the library's text, and the kind is
@racket['generic], @racket['out-of-memory], @racket['cuda] or @racket['logic]
for the codes @tt{RR_ERROR_GENERIC} (0) to @tt{RR_ERROR_LOGIC} (3); any other
code is @racket['generic]. A message given as a byte string is decoded as
UTF-8, with @racket[#\uFFFD] for anything that does not decode.

The call and both reads happen in one atomic section
(@racket[call-as-atomic]). The C side keeps its last error per OS thread, and
coroutine threads of a place share one OS thread, so without it another
Racket thread's call could overwrite the message before it is read; inside
the atomic section no other thread runs and the calling thread does not move
to another OS thread.
The atomic section also means the native call holds up the place's other
Racket threads until it returns, as a non-blocking foreign call does anyway.
@racket[last-error] and @racket[last-error-kind] are called only after a
failure.

The usual checker, for the canary's library:

@examples[#:eval ev
(define check (status-checker kc-last-error kc-last-error-kind))
(check 'kmeans-canary (lambda () (kc-check-abi (raft-abi-pointer))))
]

A failing call raises with the native library's message, prefixed by the
name the binding gives. Here k-means is handed integer data, which the canary
refuses before cuML sees it. The handle here comes from the thread's default
resources, which the thread keeps reachable; a binding takes it with
@racket[with-array-views]'s @racket[#:resources] instead
(@secref["ref-unsafe-handle"]):

@examples[#:eval ev #:label #f
(define ints (list*->device-matrix '((1 2) (3 4) (5 6)) #:dtype 'int32))
(define centers (device-matrix 2 2))
(define handle (resources->handle-pointer (current-device-resources)))
(eval:error
 (with-array-views ([x ints] [c centers])
   (check 'kmeans-fit
          (lambda () (kc-fit handle x #f c 0 300 1e-4 1 0.0 42)))))
(with-handlers ([exn:fail:raft? exn:fail:raft-kind])
  (with-array-views ([x ints] [c centers])
    (check 'kmeans-fit (lambda () (kc-fit handle x #f c 0 300 1e-4 1 0.0 42)))))
]

The thunk's other results are the call's outputs: a foreign function that
returns its status and two out-parameters as three values hands the two
outputs back. A downstream package can raise its own subtype of
@racket[exn:fail:raft], so its callers can tell its errors apart:

@examples[#:eval ev #:label #f
(struct exn:fail:canary exn:fail:raft ())
(define check/canary
  (status-checker kc-last-error kc-last-error-kind #:exn exn:fail:canary))
(define X (device-matrix 300 2))
(define truth (device-vector 300 #:dtype 'int32))
(with-array-views ([x X] [y truth])
  (check/canary 'blobs (lambda () (kc-make-blobs handle x y 3 0.5 1 -10.0 10.0 7))))
(define fitted (device-matrix 3 2))
(define-values (inertia n-iter)
  (with-array-views ([x X] [c fitted])
    (check/canary 'kmeans-fit (lambda () (kc-fit handle x #f c 0 300 1e-4 1 0.0 42)))))
(list (> inertia 0) (>= n-iter 1))
(with-handlers ([exn:fail:canary? (lambda (e) (list 'canary (exn-message e)))])
  (with-array-views ([x X] [c (device-matrix 3 5)])
    (check/canary 'kmeans-fit (lambda () (kc-fit handle x #f c 0 300 1e-4 1 0.0 42)))))
]}

@section[#:tag "ref-unsafe-abi"]{The ABI tag}

@defproc[(raft-abi-pointer) cpointer?]{

Returns a pointer to @tt{libraftrkt}'s @tt{rr_abi_tag}, the C struct that
@racket[raft-abi] reads: the facts a downstream native library must share with
@tt{libraftrkt} to receive its handle and arrays (the RAFT, RMM and CCCL
releases, the CUDA runtime, the size of @tt{raft::handle_t} and the number of
RAFT resource types, and the version of the tag). The tag lives in static
storage, so the pointer stays valid as long as the process runs.

A downstream library passes it to its own native code when it loads, and the
native code compares it with the tag it computed from the headers it was
compiled against (@tt{raftrkt::require_abi} in @tt{raftrkt/abi.h}). Doing the
comparison in C, against the headers themselves, is the point: a Racket-side
check could only compare what the downstream library recorded about itself.

The first field is the tag's version, the same number @racket[raft-abi]
reports:

@examples[#:eval ev
(raft-abi-pointer)
(ptr-ref (raft-abi-pointer) _int32 0)
(hash-ref (raft-abi) 'abi-version)
]

At load, the canary's module runs this check; it returns nothing when the
headers match:

@examples[#:eval ev #:label #f
(check 'kmeans-canary (lambda () (kc-check-abi (raft-abi-pointer))))
]

A library built against other headers is refused, naming the first field
that differs. Here a copy of the tag is edited to look like RAFT 26.10 (the
third @tt{int32} is the minor version), and then like a handle of another
size (the seventh @tt{int64} slot), which a version check alone would miss:

@examples[#:eval ev #:label #f
(define (forged-tag type index value)
  (define tag (make-bytes 56))
  (memcpy tag (raft-abi-pointer) 56)
  (ptr-set! tag type index value)
  tag)
(eval:error (check 'kmeans-canary (lambda () (kc-check-abi (forged-tag _int32 2 10)))))
(define bigger-handle (add1 (hash-ref (raft-abi) 'handle-size)))
(eval:error
 (check 'kmeans-canary (lambda () (kc-check-abi (forged-tag _int64 6 bigger-handle)))))
]}

@section[#:tag "ref-unsafe-handle"]{The handle}

@defproc[(resources->handle-pointer [resources device-resources?]) cpointer?]{

Returns a pointer to the @tt{raft::handle_t} that @racket[resources] wrap
(@tt{rr_resources_handle}). It is the handle most of cuML's C++ API takes as
@tt{const raft::handle_t&}, with the resources' own stream, cuBLAS, cuSOLVER
and cuSPARSE handles and workspace. A downstream binding passes it as a
@racket[_pointer] and its C++ casts it back.

The pointer is borrowed, and it does not keep @racket[resources] reachable:
once the program drops them, their finalizer frees the handle at the next
collection, whether or not the pointer is still in use. So a binding takes the
handle with @racket[with-array-views]'s @racket[#:resources] clause, which
binds this same pointer and keeps the resources reachable until the body
returns; this procedure on its own suits code that holds the resources some
other way, as @racket[(current-device-resources)] does for its thread.
Released resources raise @racket[exn:fail:raft] of kind @racket['logic],
naming this procedure. This is pylibraft's @tt{DeviceResources.getHandle()},
which cuML's Cython casts to a @tt{handle_t*} the same way, and which leaves
keeping the @tt{DeviceResources} alive to its caller too.

@examples[#:eval ev
(resources->handle-pointer (current-device-resources))
(ptr-equal? handle (resources->handle-pointer (current-device-resources)))
]

Each resources object has its own handle, so work given separate resources is
queued on separate streams:

@examples[#:eval ev #:label #f
(define other (device-resources))
(ptr-equal? handle (resources->handle-pointer other))
]

A binding allocates its outputs on the resources it runs on, so the handle,
the arrays and their frees share one stream. Here the canary's
@tt{make_blobs} fills arrays allocated on @racket[other], with the handle
taken by @racket[with-array-views], which is the same pointer:

@examples[#:eval ev #:label #f
(define Y (device-matrix 6 2 #:resources other))
(define classes (device-vector 6 #:dtype 'int32 #:resources other))
(with-array-views #:resources [on-other other] ([y Y] [k classes])
  (check 'blobs (lambda () (kc-make-blobs on-other y k 2 0.1 0 -1.0 1.0 3)))
  (ptr-equal? on-other (resources->handle-pointer other)))
(sort (remove-duplicates (device-vector->list classes)) <)
]

Released resources have no handle:

@examples[#:eval ev #:label #f
(define finished (with-device-resources ([r (device-resources)]) r))
(eval:error (resources->handle-pointer finished))
]}

@section[#:tag "ref-unsafe-views"]{Array views}

@defform[(with-array-views maybe-resources ([id array-expr] ...) body ...+)
         #:grammar ([maybe-resources code:blank
                                     (code:line #:resources [handle-id resources-expr])])
         #:contracts ([array-expr (or/c device-array? #f)]
                      [resources-expr device-resources?])]{

Evaluates @racket[resources-expr], if given, and each @racket[array-expr];
then binds @racket[handle-id] to the resources' @tt{raft::handle_t} pointer
(the one @racket[resources->handle-pointer] returns) and each @racket[id] to a
pointer to an @tt{rr_view} describing its array, and evaluates the
@racket[body]s, whose results are the form's results. The resources stay
reachable until the body ends, like the arrays, so their finalizer cannot free
the handle during the native call; released resources raise
@racket[exn:fail:raft] naming @racket[with-array-views]. A binding takes its
handle this way. An @racket[array-expr] that evaluates to
@racket[#f] binds @racket[#f], which a @racket[_pointer] argument passes as
@tt{NULL}: the way to pass an optional array, such as cuML's sample weights.

Each view is filled by @tt{rr_buffer_view}, so its @tt{data} pointer is the
array's first element on the device and its element type, rank, shape and
strides (in elements) are the array's; see @secref["ref-unsafe-c"] for the
struct. The view lives in memory the garbage collector does not move, and
every array stays reachable until the body ends, so the memory a view points
to cannot be freed by the array's finalizer during the native call.

Before binding a view, the form waits, by polling, until the work already
queued on the array's stream has finished, so a native call on any stream
sees the array's contents. It does not wait after the body: a native call
that queues work and returns before it finishes must run on the arrays' own
resources, or synchronise its stream before it returns; the canary
synchronises on every exit, a raise included.

On every exit from the body (a return, a raise, an escape, a generator's
@racket[yield]) each view is cleared: its @tt{data} becomes @tt{NULL} and its
device and memory @racket[-1], so a view kept past the form is refused by the
C side instead of pointing at memory that may be freed. Control that jumps
back into the body afterwards raises @racket[exn:fail:raft] of kind
@racket['logic], naming @racket[with-array-views]; it never binds the views
again. A released array raises before the body runs. Two @racket[id]s, or
@racket[handle-id] and an @racket[id], with the same name are a syntax error.

The views are what a native call takes. Here the canary's @tt{predict}
receives the fitted centroids, the data and an output vector, with no sample
weights:

@examples[#:eval ev
(define labels (device-vector 300 #:dtype 'int32))
(define score
  (with-array-views #:resources [handle (current-device-resources)]
                    ([c fitted] [x X] [w #f] [y labels])
    (check 'kmeans-predict (lambda () (kc-predict handle c x w 1 y)))))
(< (abs (- score inertia)) (* 1e-3 inertia))
(length (remove-duplicates (device-vector->list labels)))
]

A view is the C struct the native side receives. Reading it shows what
crosses: the element type code (@tt{RR_DTYPE_FLOAT32} is 0), the rank, the
shape and the strides, at the byte offsets @tt{raftrkt/array.h} fixes:

@examples[#:eval ev #:label #f
(define F (contiguous X #:layout 'col-major))
(with-array-views ([f F])
  (list (ptr-ref f _int32 'abs 8)
        (ptr-ref f _int32 'abs 20)
        (list (ptr-ref f _int64 'abs 24) (ptr-ref f _int64 'abs 32))
        (list (ptr-ref f _int64 'abs 88) (ptr-ref f _int64 'abs 96))))
]

The C side checks every view against what the call needs: cuML's k-means
reads row-major data, and the column-major copy is refused with the layout it
has:

@examples[#:eval ev #:label #f
(eval:error
 (with-array-views ([x F] [c (device-matrix 3 2)])
   (check 'kmeans-fit (lambda () (kc-fit handle x #f c 0 300 1e-4 1 0.0 42)))))
]

A view that escapes the form has been cleared, so passing it later is refused
rather than reading freed memory:

@examples[#:eval ev #:label #f
(define stale (with-array-views ([x X]) x))
(eval:error
 (with-array-views ([c fitted] [y labels])
   (check 'kmeans-predict (lambda () (kc-predict handle c stale #f 1 y)))))
]}

@section[#:tag "ref-unsafe-c"]{The C interface}

The C side of the interface is three public C headers of @tt{libraftrkt}
(@tt{core.h}, @tt{array.h}, @tt{memory.h}, gathered by @tt{c_api.h}), the ABI
header, and two header-only C++ helpers. They ship in the flake's
@tt{packages.raft-dev}, with a CMake package: @tt{find_package(raftrkt)}
defines @tt{raftrkt::headers}, which links @tt{raft::raft}. A downstream
library compiles against @tt{packages.raft-dev} and @tt{packages.rapids}, the
same RAPIDS package set @tt{libraftrkt} links, and does not link
@tt{libraftrkt} itself: the handle, the views and the ABI tag reach it from
Racket.

@bold{The handle.} @tt{int rr_resources_handle(rr_resources* resources,
void** out)} stores the @tt{raft::handle_t*} in @racket[out]. Like every entry
point, it answers @tt{RR_OK} (0) or @tt{RR_ERROR} (1) and leaves the reason
in @tt{rr_last_error()} and @tt{rr_last_error_kind()}; @racket[out] is set to
@tt{NULL} first.

@bold{Views.} An @tt{rr_view} is 152 bytes:

@tabular[#:sep @hspace[2]
         #:style 'boxed
         #:row-properties '(bottom-border ())
 (list (list @bold{Field} @bold{Offset} @bold{Meaning})
       (list @tt{void* data} "0" "the first element, base plus byte offset already applied")
       (list @tt{int32_t dtype} "8" @elem{@tt{RR_DTYPE_FLOAT32} 0, @tt{FLOAT64} 1,
                                          @tt{INT32} 2, @tt{INT64} 3})
       (list @tt{int32_t memory} "12" @elem{@tt{RR_MEMORY_DEVICE} (2) for every array today})
       (list @tt{int32_t device} "16" "the CUDA device")
       (list @tt{int32_t rank} "20" @elem{0 to @tt{RR_MAX_RANK} (8)})
       (list @tt{int64_t shape[8]} "24" "the extents; entries past the rank are 0")
       (list @tt{int64_t strides[8]} "88" "in elements, NumPy's order"))]

@tt{int rr_buffer_view(const rr_buffer* buffer, uint64_t offset, rr_view*
view)} is the one way a view gets its pointer: the caller fills
@tt{dtype}, @tt{rank}, @tt{shape} and @tt{strides}, and the call checks them
against the buffer and fills @tt{data}, @tt{device} and @tt{memory}. A refused
call leaves @tt{data} @tt{NULL} and the other two @tt{-1}. @tt{data} is valid
only while the buffer lives, and only for work ordered on the buffer's stream.
@racket[with-array-views] makes these calls for Racket code.

@bold{@tt{raftrkt/abi.h}.} The @tt{rr_abi_tag} struct (56 bytes: twelve
@tt{int32_t} fields and the @tt{int64_t} handle size), @tt{RR_ABI_VERSION}
(1), and, for C as well as C++,
@tt{int rr_abi_compare(const rr_abi_tag* built, const rr_abi_tag* loaded, char*
why, size_t why_size)}, which answers 0 when the tags agree and otherwise 1,
writing the first difference into @tt{why}. For C++ it adds
@tt{raftrkt::compiled_abi()}, the tag of the headers being compiled, and
@tt{raftrkt::require_abi(loaded)}, which throws @tt{raftrkt::logic_error}
when they differ. @tt{libraftrkt} builds its own tag with
@tt{compiled_abi()}, so both sides compute it the same way.

@listing["C++"]|{
extern "C" int kc_check_abi(const rr_abi_tag* loaded) {
  return raftrkt::translate_exceptions(kc::last_error_slot(),
                                       [&] { raftrkt::require_abi(loaded); });
}
}|

@bold{@tt{raftrkt/error.hpp}.} The error convention, header-only, so a
downstream library's errors look like @tt{libraftrkt}'s:

@itemlist[
 @item{@tt{raftrkt::error_slot}: a fixed 4 KiB message buffer and a kind. The
       downstream library owns one per OS thread (@tt{thread_local}) and
       exports two functions that read it, which @racket[status-checker]
       calls.}
 @item{@tt{int raftrkt::translate_exceptions(error_slot& slot, Fn&& fn)}:
       clears the slot, runs @tt{fn}, and answers @tt{RR_OK}; if @tt{fn}
       throws, records the message (truncated at a UTF-8 character boundary,
       without allocating) and its kind, and answers @tt{RR_ERROR}.}
 @item{@tt{raftrkt::classify}: the kind of an exception.
       @tt{rmm::out_of_memory}, @tt{std::bad_alloc} and any CUDA error whose
       status is @tt{cudaErrorMemoryAllocation} are @racket['out-of-memory];
       so are RAFT's cuBLAS, cuSOLVER and cuSPARSE errors whose status is
       @tt{*_STATUS_ALLOC_FAILED}; other CUDA, RMM and RAFT CUDA, cuBLAS,
       cuSOLVER and cuSPARSE errors are @racket['cuda];
       @tt{std::logic_error} and @tt{raft::logic_error} are @racket['logic];
       anything else is @racket['generic].}
 @item{@tt{raftrkt::logic_error}, @tt{raftrkt::cuda_error},
       @tt{raftrkt::cuda_check(status, call)} and
       @tt{raftrkt::require(pointer, name)}, which throws
       @tt{"name is NULL"}.}
 @item{@tt{raftrkt::device_scope}: makes a device current for its scope,
       throwing if @tt{cudaSetDevice} fails, and restores the previous one.}
 @item{@tt{raftrkt::sync_guard}: synchronises a stream on every exit from its
       scope. @tt{finish()} synchronises and throws on failure; if the scope
       is left by a throw instead, the destructor synchronises and swallows a
       second error, so the first is the one reported and no array is handed
       back while work queued on it still runs.}]

@bold{@tt{raftrkt/view.hpp}.} Views to typed pointers and RAFT views, after
the checks memory safety needs. Each takes the argument's name for its
messages, and throws @tt{raftrkt::logic_error}:

@itemlist[
 @item{@tt{T* raftrkt::matrix_data<T, Index>(const rr_view* view, const char*
       name, raftrkt::layout l, int64_t rows = any_extent, int64_t cols =
       any_extent)}: refuses a @tt{NULL} or unbound view, a rank other than 2,
       an element type other than @tt{T}'s (@tt{const T} reads the same
       type), a layout other than @tt{l} (an axis of extent 1 fits either),
       extents other than those asked for, and extents, or an element count, that do not fit
       @tt{Index}.}
 @item{@tt{T* raftrkt::vector_data<T, Index>(const rr_view* view, const char*
       name, int64_t n = any_extent)}: the same for a contiguous rank-1
       view.}
 @item{@tt{raftrkt::matrix_view<T, Layout, Index>} and
       @tt{raftrkt::vector_view<T, Index>}: the same checks, answering a
       @tt{raft::device_matrix_view} or @tt{raft::device_vector_view}.}
 @item{@tt{raftrkt::has_layout(view, l)}, @tt{raftrkt::dtype_code<T>} and
       @tt{raftrkt::dtype_name(code)}.}
 @item{@tt{raftrkt::handle_of(void* handle)}: the @tt{raft::handle_t} a
       pointer from @racket[with-array-views] or
       @racket[resources->handle-pointer] carries, refusing @tt{NULL};
       @tt{raftrkt::device_of(handle)}: its device.}
 @item{@tt{raftrkt::require_on_device(device, {{"X", x}, ...})}: refuses a
       bound view on another device, naming it.}]

@listing["C++"]|{
const T* data = raftrkt::matrix_data<const T, int>(x, "X", raftrkt::layout::row_major);
T* centers = raftrkt::matrix_data<T, int>(centroids, "centroids", raftrkt::layout::row_major,
                                          raftrkt::any_extent, d);
auto m = raftrkt::matrix_view<const float, raft::col_major, int64_t>(a, "A");
}|

@bold{What is frozen.} @tt{rr_view}, @tt{RR_MAX_RANK} and the dtype and memory
codes; @tt{rr_buffer_view}; @tt{rr_resources_handle}; @tt{rr_abi_tag},
@tt{rr_abi} and @tt{RR_ABI_VERSION}; the status codes, error kinds and
@tt{rr_last_error} convention; the three headers @tt{raftrkt/view.hpp},
@tt{raftrkt/error.hpp} and @tt{raftrkt/abi.h}; the four exports of this
module; and the rules a downstream entry point keeps, which the canary's
entry points show: run inside @tt{translate_exceptions}, select the
handle's device, refuse arrays on another device, read arrays only through
@tt{view.hpp}, and synchronise the handle's stream on every exit. Only the
four element types above are in it: int8, uint8 and half arrays, which cuVS
takes, need new dtype codes and so ABI version 2 (#8). A change to any of them is a new ABI version, and the k-means canary
in @tt{downstream/kmeans-canary} changes with it, in the same pull request.
