#lang scribble/manual
@(require "../utils.rkt")

@(define ev (make-raft-eval))

@title[#:tag "concepts"]{Concepts}

Where data lives, what a resources object and an array are, how memory comes
back, and what an error looks like. A name marked with a leg, such as
@status{L3}, is not there yet.

@section[#:tag "concepts-memory"]{Device memory and host memory}

Racket values live in host memory, managed by Racket's garbage collector. A
RAFT array lives in device memory, managed by RMM, the RAPIDS memory manager.
Data crosses between them only by an explicit copy: build data in Racket,
copy it to the device once, compute there, and copy back only the results.
A conversion such as @racket[list->device-vector] or
@racket[device-vector->list] is always a copy, and nothing else
is.

A round trip is @racket[(device-vector->list (list->device-vector xs))];
@racket[#:dtype] chooses the element type on the device.

@section[#:tag "concepts-resources"]{Resources and streams}

Every RAFT operation takes a @deftech{resources} object, the C++
@tt{raft::handle_t}: the device, the CUDA stream the work is queued on, the
cuBLAS, cuSOLVER and cuSPARSE handles (created on first use) and scratch
memory. cuML takes the same object.

A @deftech{stream} is an ordered queue of GPU work. Each resources object owns
one, so everything done with it runs in order. Operations return once queued;
the program waits only when a value reaches the host or on
@racket[resources-sync!].

@racket[current-device-resources] keeps one resources object per
Racket thread and device; the array constructors and conversions take
@racket[#:resources] to override it.
@secref["resources"] shows them in client code.

A resources object always owns its stream, and every buffer allocated through
it keeps that stream alive.

@section[#:tag "concepts-arrays"]{Arrays}

@subsection[#:tag "concepts-buffers-views"]{Buffers and views}

A @deftech{buffer} is one RMM allocation, the only thing with a finalizer. An
@deftech{array} is a plain Racket value over a buffer: shape, strides, offset
and element type, as RAFT's @tt{mdspan} is over its @tt{mdarray}. Slicing or
transposing @status{L3} makes a new array over the same buffer, without a
copy. @racket[(device-matrix 1000 128)] is a new, uninitialised
1000-by-128 matrix.

@subsection[#:tag "concepts-dtypes"]{Element types}

Each array has one element type, its @deftech{dtype}: @racket['float32],
@racket['float64], @racket['int32] or @racket['int64]. Conversions infer it
(exact integers give @racket['int64], other reals @racket['float64]), and
@racket[#:dtype] overrides it. cuML mostly runs in
@racket['float32]: half the memory, and far faster on consumer GPUs.

@subsection[#:tag "concepts-layout"]{Row-major and column-major layout}

@deftech{Row-major} order stores each row contiguously, as C does;
@deftech{column-major} order stores each column contiguously, as Fortran and
BLAS do:

@examples[#:eval ev #:label #f
(define m '((1 2 3)
            (4 5 6)))
(define (row-major rows) (apply append rows))
(define (column-major rows) (apply append (apply map list rows)))
(row-major m)
(column-major m)
]

An array records its layout as @deftech{strides}, the step along each axis:
@racket['(3 1)] row-major, @racket['(1 2)] column-major. Racket counts
strides in elements, not bytes, as RAFT and DLPack do.

RAFT's kernels and cuML's entry points expect a particular layout (k-means
reads row-major, the least-squares solvers column-major), and the binding
never converts silently: a wrong layout raises, and @racket[(contiguous X
#:layout 'col-major)] copies explicitly. Converting host data
with @racket[#:layout 'col-major] packs it in column order on
the host instead. @secref["arrays"] does both.

@section[#:tag "concepts-reclaiming"]{How memory is reclaimed}

You never free an array. When a buffer becomes unreachable, its finalizer
returns the allocation to RMM, on its own stream and device, from whatever
OS thread it runs on. The collector cannot see device memory, so each buffer
reports its size as @deftech{phantom bytes}, and holding a lot
of device memory triggers collections as host memory does.

That finalizer is the default, and it is correct on its own: everything is
released exactly once. What it lacks is a timeline: it runs at some
collection after the last use, in no particular order. A resources object
also holds state no byte count describes, its CUDA stream and the library
handles RAFT creates on first use, which dropped resources keep until a
collection finds them.

The @tt{with-} forms give a managed object's lifetime a clear timeline: they
release it at a known point, when the body returns, raises, escapes or
yields, and refuse control that jumps back in. The finalizer stays as the
backstop, for a thread killed inside the body. @racket[with-device-resources]
scopes resources (@secref["res-batch"]); a form for arrays arrives in
@status{L3}.

@section[#:tag "concepts-errors"]{Errors}

Every failure in RAFT, RMM, CUDA or the native library raises
@racket[exn:fail:raft]. Its message starts with the name of the
Racket function you called; its kind (@racket['out-of-memory],
@racket['cuda], @racket['logic] or @racket['generic]) lets the memory manager
retry an allocation after an out-of-memory failure.

There are no contracts yet, so a wrong argument is reported by RAFT or the
native library in their words. Anything that could corrupt memory is refused
before the GPU is touched: copying 16 bytes into an 8-byte buffer raises
@tt{copy: 16 bytes do not fit a buffer of 8 bytes}. A failed CUDA call is
named, as in @tt{cudaGetDeviceCount: ...}.

@section[#:tag "concepts-mapping"]{Racket and RAFT C++}

The names line up as follows. The status column says when each Racket name
arrives.

@tabular[#:sep @hspace[2]
         #:style 'boxed
         #:row-properties '(bottom-border ())
 (list (list @bold{Racket} @bold{RAFT C++} @bold{Status})
       (list @racket[raft-version]
             @elem{@tt{RAFT_VERSION_MAJOR}, @tt{_MINOR}, @tt{_PATCH}}
             "here")
       (list @racket[raft-abi]
             @elem{@tt{rr_abi()}, ours}
             "here")
       (list @racket[device-count]
             @tt{cudaGetDeviceCount}
             "here")
       (list @racket[device-resources]
             @tt{raft::handle_t}
             "here")
       (list @racket[current-device-resources]
             @tt{raft::device_resources_manager}
             "here")
       (list @racket[with-device-resources]
             "no counterpart"
             "here")
       (list @racket[resources-sync!]
             @tt{raft::resource::sync_stream}
             "here")
       (list "the default memory resource"
             @tt{rmm::mr::set_per_device_resource}
             "here, installed on first use")
       (list @racket[cuda-async-memory-resource]
             @tt{rmm::mr::cuda_async_memory_resource}
             @status{L2})
       (list @racket[exn:fail:raft]
             @elem{@tt{raft::exception}, @tt{rmm::bad_alloc}}
             "here")
       (list @racket[device-matrix]
             @tt{raft::make_device_matrix}
             "here")
       (list @racket[device-vector]
             @tt{raft::make_device_vector}
             "here")
       (list @elem{@racket[shape], @racket[dtype], @racket[layout]}
             @elem{@tt{extents()}, @tt{value_type}, the layout policy}
             "here")
       (list @elem{@racket[strides], @racket[numel]}
             @elem{@tt{stride(i)}, @tt{size()}}
             "here")
       (list @racket[contiguous?]
             "the layout policy"
             "here")
       (list @racket[contiguous]
             @elem{@tt{raft::copy} between layouts}
             "here")
       (list @elem{@racket[list->device-vector], @racket[device-vector->list]}
             @elem{a host buffer and @tt{cudaMemcpyAsync}}
             "here")
       (list @elem{@racket[list*->device-matrix], @racket[device-matrix->list*]}
             @elem{a host buffer and @tt{cudaMemcpyAsync}}
             "here")
       (list @elem{@racket[flvector->device-vector], @racket[device-vector->flvector]}
             @tt{cudaMemcpyAsync}
             "here")
       (list @elem{@racket[device-array->list*], @racket[device-array->vector*]}
             @elem{a copy to the host}
             "here")
       (list @elem{@racket[matrix->device-matrix], @racket[array->device-array]}
             @elem{a host buffer and @tt{cudaMemcpyAsync}}
             "here")
       (list @racket[resources->handle-pointer]
             @elem{@tt{raft::handle_t*}, from @tt{rr_resources_handle}}
             "here")
       (list @racket[with-array-views]
             @elem{@tt{rr_view}, read by @tt{raftrkt/view.hpp}}
             "here")
       (list @racket[status-checker]
             @elem{@tt{raftrkt::translate_exceptions} and an @tt{error_slot}}
             "here")
       (list @racket[raft-abi-pointer]
             @elem{@tt{rr_abi()}, @tt{raftrkt::require_abi}}
             "here"))]
