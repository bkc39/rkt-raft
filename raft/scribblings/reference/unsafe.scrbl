#lang scribble/manual
@(require "../utils.rkt")

@(define ev (make-downstream-eval))

@title[#:tag "ref-unsafe"]{Downstream interface: @racketmodname[raft/unsafe]}

@defmodule[raft/unsafe]

This module is for native bindings that run their own C++ on raft's resources
and arrays, such as a cuML binding. It provides the @tt{raft::handle_t} to
run on, a descriptor for each array, a checker that turns a native status
into @racket[exn:fail:raft], and the ABI tag. @racketmodname[raft] does not
re-export it.

It is unsafe as @racketmodname[ffi/unsafe] is: nothing checks that a
binding's foreign declarations match its C code, so passing a view where the
C function expects a handle crashes the process. The C headers check views,
not pointer types.

@secref["downstream"] builds the k-means canary on this module. The
interface is frozen at ABI version 1 (@secref["ref-unsafe-c"]).

The examples call the canary's library: set @tt{RAFT_KMEANS_CANARY} to
@tt{libkmeans_canary.so} to run them. They share these bindings, in which handles and views cross as plain
@racket[_pointer]s:

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

@section[#:tag "ref-unsafe-status"]{Checking native calls}

@defproc[(status-checker [last-error (-> (or/c bytes? string?))]
                         [last-error-kind (-> exact-integer?)]
                         [#:exn exn
                                (-> string? continuation-mark-set? symbol? exn?)
                                exn:fail:raft])
         (-> symbol? (-> any) any)]{

Returns a procedure @racket[(check who thunk)] for one native library's
calls. @racket[check] calls @racket[thunk], whose first result is the C
status. On @racket[0] (@tt{RR_OK}) it returns the thunk's other results.
Otherwise it raises @racket[(exn message marks kind)]: the message is
@racket[who], a colon and @racket[(last-error)], decoded as UTF-8 with
@racket[#\uFFFD] for what does not decode; the kind is @racket['generic],
@racket['out-of-memory], @racket['cuda] or @racket['logic] for
@racket[(last-error-kind)] 0 to 3, and @racket['generic] for any other code.
@racket[last-error] and @racket[last-error-kind] are called only after a
failure.

The call and both reads run in one @racket[call-as-atomic], because the C
side keeps its last error per OS thread, which the place's Racket threads
share. The native call therefore holds up the place's other threads until it
returns.

@examples[#:eval ev
(define check (status-checker kc-last-error kc-last-error-kind))
(check 'kmeans-canary (lambda () (kc-check-abi (raft-abi-pointer))))
]

A failure raises with the library's message. The handle here comes from the
thread's default resources, which the thread holds; a binding uses
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

With @racket[#:exn], a package raises its own subtype of
@racket[exn:fail:raft]:

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

Returns a pointer to @tt{libraftrkt}'s @tt{rr_abi_tag} in static storage,
the C struct that @racket[raft-abi] reads: the tag's version (the first field), the
RAFT, RMM, CCCL and CUDA runtime releases, the size of @tt{raft::handle_t}
and the number of RAFT resource types. A downstream library passes it to its
native code at load, which compares it with the tag of the headers it was
compiled against (@tt{raftrkt::require_abi}).

@examples[#:eval ev
(raft-abi-pointer)
(ptr-ref (raft-abi-pointer) _int32 0)
(raft-abi-version (raft-abi))
]

The canary's load check returns nothing when the headers match:

@examples[#:eval ev #:label #f
(check 'kmeans-canary (lambda () (kc-check-abi (raft-abi-pointer))))
]

A mismatch is refused, naming the first field that differs. Here a copy of
the tag is edited to look like RAFT 26.10 (the third @tt{int32}), then like a
handle of another size (the seventh @tt{int64} slot):

@examples[#:eval ev #:label #f
(define (forged-tag type index value)
  (define tag (make-bytes 56))
  (memcpy tag (raft-abi-pointer) 56)
  (ptr-set! tag type index value)
  tag)
(eval:error (check 'kmeans-canary (lambda () (kc-check-abi (forged-tag _int32 2 10)))))
(define bigger-handle (add1 (raft-abi-handle-size (raft-abi))))
(eval:error
 (check 'kmeans-canary (lambda () (kc-check-abi (forged-tag _int64 6 bigger-handle)))))
]}

@section[#:tag "ref-unsafe-handle"]{The handle}

@defproc[(resources->handle-pointer [resources device-resources?]) cpointer?]{

Returns a pointer to the @tt{raft::handle_t} of @racket[resources], with
their stream, library handles and workspace: what cuML's C++ takes as
@tt{const raft::handle_t&}. Released resources raise @racket[exn:fail:raft]
of kind @racket['logic].

The pointer is borrowed and does not hold @racket[resources]: once they are
unreachable, their finalizer frees the handle. A binding therefore takes the
handle with @racket[with-array-views]'s @racket[#:resources]; this procedure
suits code that holds the resources some other way, as
@racket[(current-device-resources)] does for its thread.

@examples[#:eval ev
(resources->handle-pointer (current-device-resources))
(ptr-equal? handle (resources->handle-pointer (current-device-resources)))
]

Each resources object has its own handle, and so its own stream:

@examples[#:eval ev #:label #f
(define other (device-resources))
(ptr-equal? handle (resources->handle-pointer other))
]

A binding allocates its outputs on the resources it runs on, so they share
one stream; @racket[#:resources] binds the same pointer:

@examples[#:eval ev #:label #f
(define Y (device-matrix 6 2 #:resources other))
(define classes (device-vector 6 #:dtype 'int32 #:resources other))
(with-array-views #:resources [on-other other] ([y Y] [k classes])
  (check 'blobs (lambda () (kc-make-blobs on-other y k 2 0.1 0 -1.0 1.0 3)))
  (ptr-equal? on-other (resources->handle-pointer other)))
(sort (remove-duplicates (device-vector->list classes)) <)
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
binds @racket[handle-id] to the resources' @tt{raft::handle_t} pointer (as
from @racket[resources->handle-pointer]) and each @racket[id] to a pointer to
an @tt{rr_view} of its array, filled by @tt{rr_buffer_view}
(@secref["ref-unsafe-c"]); and evaluates the @racket[body]s, whose results
are the form's. An @racket[array-expr] of @racket[#f] binds @racket[#f],
which a @racket[_pointer] argument passes as @tt{NULL}, for an optional
array. Released resources or a released array raise @racket[exn:fail:raft]
before the body runs. Two identical names among the @racket[id]s and
@racket[handle-id] are a syntax error.

The arrays and the resources stay managed by the garbage collector: the form
frees neither, and their finalizers are the default and correct on their
own. What the form gives a native call is a clear timeline for what it
borrows: from the start of the body until it exits, the views are valid and
the arrays and the resources are held reachable; at exit the views are
cleared and the form's hold ends, and the arrays return to ordinary
reclamation. To release the resources themselves at a known point, scope
them with @racket[with-device-resources] around the form.

Every exit (a return, a raise, an escape, a generator's @racket[yield])
clears each view: its @tt{data} becomes @tt{NULL} and its device and memory
@racket[-1], so the C side refuses a view kept past the form. The handle
pointer is not cleared, so it must not escape the body. Control that jumps
back into the body raises @racket[exn:fail:raft] of kind @racket['logic].

Before binding a view, the form waits, by polling, for the work queued on
the array's stream. It does not wait after the body: a native call that
returns with work still queued must run on the arrays' own resources or
synchronise before it returns.

@examples[#:eval ev
(define labels (device-vector 300 #:dtype 'int32))
(define score
  (with-array-views #:resources [handle (current-device-resources)]
                    ([c fitted] [x X] [w #f] [y labels])
    (check 'kmeans-predict (lambda () (kc-predict handle c x w 1 y)))))
(< (abs (- score inertia)) (* 1e-3 inertia))
(length (remove-duplicates (device-vector->list labels)))
]

A view holds the element type code (@tt{RR_DTYPE_FLOAT32} is 0), the rank,
the shape and the strides at the offsets of @secref["ref-unsafe-c"]:

@examples[#:eval ev #:label #f
(define F (contiguous X #:layout 'col-major))
(with-array-views ([f F])
  (list (ptr-ref f _int32 'abs 8)
        (ptr-ref f _int32 'abs 20)
        (list (ptr-ref f _int64 'abs 24) (ptr-ref f _int64 'abs 32))
        (list (ptr-ref f _int64 'abs 88) (ptr-ref f _int64 'abs 96))))
]

The C side checks each view against what the call needs, and a cleared view
is refused:

@examples[#:eval ev #:label #f
(eval:error
 (with-array-views ([x F] [c (device-matrix 3 2)])
   (check 'kmeans-fit (lambda () (kc-fit handle x #f c 0 300 1e-4 1 0.0 42)))))
(define stale (with-array-views ([x X]) x))
(eval:error
 (with-array-views ([c fitted] [y labels])
   (check 'kmeans-predict (lambda () (kc-predict handle c stale #f 1 y)))))
]}

@section[#:tag "ref-unsafe-c"]{The C interface}

The C side is the public C headers of @tt{libraftrkt} (@tt{core.h},
@tt{array.h}, @tt{memory.h}, gathered by @tt{c_api.h}), the ABI header and
two header-only C++ helpers, shipped with a CMake package
(@tt{find_package(raftrkt)} defines @tt{raftrkt::headers}, which links
@tt{raft::raft}). A downstream library compiles against them and the same
RAPIDS 26.08 libraries and headers as @tt{libraftrkt}, and does not link
@tt{libraftrkt}.

@bold{The handle.} @tt{int rr_resources_handle(rr_resources* resources,
void** out)} sets @racket[out] to @tt{NULL}, then to the
@tt{raft::handle_t*}. Like every entry point, it answers @tt{RR_OK} (0) or
@tt{RR_ERROR} (1), with the reason in @tt{rr_last_error()} and
@tt{rr_last_error_kind()}.

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
       (list @tt{int64_t strides[8]} "88" "in elements, axis 0 first"))]

@tt{int rr_buffer_view(const rr_buffer* buffer, uint64_t offset, rr_view*
view)} is the one way a view gets its pointer: the caller fills @tt{dtype},
@tt{rank}, @tt{shape} and @tt{strides}, and the call checks them against the
buffer and fills @tt{data}, @tt{device} and @tt{memory}, or on refusal
@tt{NULL}, @tt{-1} and @tt{-1}. @tt{data} is valid only while the buffer
lives, and only for work ordered on the buffer's stream.

@bold{@tt{raftrkt/abi.h}.} The @tt{rr_abi_tag} struct (56 bytes: twelve
@tt{int32_t} fields and the @tt{int64_t} handle size), @tt{RR_ABI_VERSION}
(1), and, for C and C++, @tt{int rr_abi_compare(const rr_abi_tag* built,
const rr_abi_tag* loaded, char* why, size_t why_size)}, which answers 0 when
the tags agree and otherwise 1, writing the first difference into @tt{why}.
For C++, @tt{raftrkt::compiled_abi()} is the tag of the headers being
compiled (@tt{libraftrkt} builds its own the same way), and
@tt{raftrkt::require_abi(loaded)} throws @tt{raftrkt::logic_error} when they
differ:

@listing["C++"]|{
extern "C" int kc_check_abi(const rr_abi_tag* loaded) {
  return raftrkt::translate_exceptions(kc::last_error_slot(),
                                       [&] { raftrkt::require_abi(loaded); });
}
}|

@bold{@tt{raftrkt/error.hpp}.} The error convention, so a downstream
library's errors look like @tt{libraftrkt}'s:

@itemlist[
 @item{@tt{raftrkt::error_slot}: a fixed 4 KiB message buffer and a kind. The
       library owns one per OS thread (@tt{thread_local}) and exports the two
       readers @racket[status-checker] calls.}
 @item{@tt{int raftrkt::translate_exceptions(error_slot& slot, Fn&& fn)}:
       clears the slot, runs @tt{fn}, and answers @tt{RR_OK}; if @tt{fn}
       throws, records the message (truncated at a UTF-8 character boundary,
       without allocating) and its kind, and answers @tt{RR_ERROR}.}
 @item{@tt{raftrkt::classify}: the kind of an exception.
       @tt{rmm::out_of_memory}, @tt{std::bad_alloc}, CUDA errors with status
       @tt{cudaErrorMemoryAllocation} and RAFT's cuBLAS, cuSOLVER and
       cuSPARSE errors with status @tt{*_STATUS_ALLOC_FAILED} are
       @racket['out-of-memory]; other CUDA, RMM and RAFT CUDA, cuBLAS,
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
       scope. @tt{finish()} synchronises and throws on failure; on a throw,
       the destructor synchronises and swallows a second error, so the first
       is reported.}]

@bold{@tt{raftrkt/view.hpp}.} Views to typed pointers and RAFT views. Each
takes the argument's name for its messages and throws
@tt{raftrkt::logic_error}:

@itemlist[
 @item{@tt{T* raftrkt::matrix_data<T, Index>(const rr_view* view, const char*
       name, raftrkt::layout l, int64_t rows = any_extent, int64_t cols =
       any_extent)}: refuses a @tt{NULL} or unbound view, a rank other than 2,
       an element type other than @tt{T}'s (@tt{const T} reads the same
       type), a layout other than @tt{l} (an axis of extent 1 fits either),
       extents other than those asked for, and extents or an element count
       that do not fit @tt{Index}.}
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
@tt{rr_last_error} convention; the three headers above; the four exports of
this module; and the rules a downstream entry point keeps: run inside
@tt{translate_exceptions}, select the handle's device, refuse arrays on
another device, read arrays only through @tt{view.hpp}, and synchronise the
handle's stream on every exit. A change to any of them is a new ABI version,
with the canary changed in the same pull request. int8, uint8 and half
arrays, which cuVS takes, need new dtype codes and so ABI version 2 (#8).
