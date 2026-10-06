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

@python|{
import numpy as np
from pylibraft.common import device_ndarray

device_ndarray(np.array([1.5, -2.25, 0.0])).copy_to_host()   # array([ 1.5 , -2.25,  0.  ])
}|

Racket will spell it @racket[(device-vector->list (list->device-vector xs))]
, and the conversion takes @racket[#:dtype] where Python picks
the type when it builds the NumPy array.

@section[#:tag "concepts-resources"]{Resources and streams}

Every RAFT operation takes a @deftech{resources} object, the C++
@tt{raft::handle_t} (pylibraft's @tt{DeviceResources}): the device, the CUDA
stream the work is queued on, the cuBLAS, cuSOLVER and cuSPARSE handles
(created on first use) and scratch memory. cuML takes the same object.

A @deftech{stream} is an ordered queue of GPU work. Each resources object owns
one, so everything done with it runs in order. Operations return once queued;
the program waits only when a value reaches the host or on
@racket[resources-sync!], where pylibraft syncs after every call
made without an explicit handle.

@racket[current-device-resources] keeps one resources object per
Racket thread and device; the array constructors and conversions take
@racket[#:resources] to override it, as pylibraft takes @tt{handle=}.
@secref["resources"] shows them in client code.

@python|{
from pylibraft.common import DeviceResources, Stream

stream = Stream()                           # keep it: the handle does not
handle = DeviceResources(stream=stream)     # its own stream and library handles
...                                         # pass handle=handle to each call
handle.sync()                               # wait for everything queued on it
}|

Without @tt{stream}, @tt{DeviceResources()} shares CUDA's per-thread default
stream, and it does not keep its @tt{Stream} alive. A Racket resources object
always owns its stream, and every buffer allocated through it keeps that
stream alive.

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
as NumPy does (exact integers give @racket['int64], other reals
@racket['float64]), and @racket[#:dtype] overrides it. cuML mostly runs in
@racket['float32]: half the memory, and far faster on consumer GPUs.

@subsection[#:tag "concepts-layout"]{Row-major and column-major layout}

@deftech{Row-major} order stores each row contiguously, as C and NumPy do;
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
strides in elements, as RAFT and DLPack do; NumPy and CuPy count bytes.

@python|{
import numpy as np
m = np.array([[1, 2, 3], [4, 5, 6]], dtype=np.float64)
m.ravel(order="K").tolist()                     # [1.0, 2.0, 3.0, 4.0, 5.0, 6.0]
np.asfortranarray(m).ravel(order="K").tolist()  # [1.0, 4.0, 2.0, 5.0, 3.0, 6.0]
m.strides, np.asfortranarray(m).strides         # ((24, 8), (8, 16)), in bytes
}|

RAFT's kernels and cuML's entry points expect a particular layout (k-means
reads row-major, the least-squares solvers column-major), and the binding
never converts silently: a wrong layout raises, and @racket[(contiguous X
#:layout 'col-major)] copies explicitly. Converting host data
with @racket[#:layout 'col-major] @status{L1c} packs it in column order on
the host instead. @secref["arrays"] makes the copy.

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

@python|{
X = device_ndarray.empty((1000, 128), dtype=np.float32)
del X          # CPython frees it now, through the reference count
}|

CPython frees an array when its last reference goes; Racket frees it at a
later collection, unless a @tt{with-} form releases it first.

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

@section[#:tag "concepts-mapping"]{Racket, RAFT C++ and pylibraft}

The names line up as follows. The status column says when each Racket name
arrives.

@tabular[#:sep @hspace[2]
         #:style 'boxed
         #:row-properties '(bottom-border ())
 (list (list @bold{Racket} @bold{RAFT C++} @bold{Python} @bold{Status})
       (list @racket[raft-version]
             @elem{@tt{RAFT_VERSION_MAJOR}, @tt{_MINOR}, @tt{_PATCH}}
             @tt{pylibraft.__version__}
             "here")
       (list @racket[raft-abi]
             @elem{@tt{rr_abi()}, ours}
             "no counterpart"
             "here")
       (list @racket[device-count]
             @tt{cudaGetDeviceCount}
             @tt{cp.cuda.runtime.getDeviceCount()}
             "here")
       (list @racket[device-resources]
             @tt{raft::handle_t}
             @tt{pylibraft.common.DeviceResources}
             "here")
       (list @racket[current-device-resources]
             @tt{raft::device_resources_manager}
             @tt{handle=None}
             "here")
       (list @racket[with-device-resources]
             "no counterpart"
             @elem{@tt{del handle}}
             "here")
       (list @racket[resources-sync!]
             @tt{raft::resource::sync_stream}
             @tt{DeviceResources.sync()}
             "here")
       (list "the default memory resource"
             @tt{rmm::mr::set_per_device_resource}
             @tt{rmm.mr.set_current_device_resource}
             "here, installed on first use")
       (list @racket[cuda-async-memory-resource]
             @tt{rmm::mr::cuda_async_memory_resource}
             @tt{rmm.mr.CudaAsyncMemoryResource()}
             @status{L2})
       (list @racket[exn:fail:raft]
             @elem{@tt{raft::exception}, @tt{rmm::bad_alloc}}
             @elem{@tt{RuntimeError}, @tt{MemoryError}}
             "here")
       (list @racket[device-matrix]
             @tt{raft::make_device_matrix}
             @tt{device_ndarray.empty((r, c))}
             "here")
       (list @racket[device-vector]
             @tt{raft::make_device_vector}
             @tt{device_ndarray.empty((n,))}
             "here")
       (list @elem{@racket[shape], @racket[dtype], @racket[layout]}
             @elem{@tt{extents()}, @tt{value_type}, the layout policy}
             @elem{@tt{.shape}, @tt{.dtype}, @tt{.c_contiguous}}
             "here")
       (list @elem{@racket[strides], @racket[numel]}
             @elem{@tt{stride(i)}, @tt{size()}}
             @elem{@tt{.strides} (in bytes, or @tt{None}), NumPy's @tt{.size}}
             "here")
       (list @racket[contiguous?]
             "the layout policy"
             @elem{NumPy's @tt{flags.c_contiguous}, @tt{flags.f_contiguous}}
             "here")
       (list @racket[contiguous]
             @elem{@tt{raft::copy} between layouts}
             @elem{@tt{cp.ascontiguousarray}, @tt{cp.asfortranarray}}
             "here")
       (list @elem{@racket[list->device-vector], @racket[device-vector->list]}
             @elem{a host buffer and @tt{cudaMemcpyAsync}}
             @elem{@tt{device_ndarray(np.array(xs))}, @tt{.copy_to_host().tolist()}}
             "here")
       (list @elem{@racket[list*->device-matrix], @racket[device-matrix->list*]}
             @elem{a host buffer and @tt{cudaMemcpyAsync}}
             @elem{@tt{device_ndarray(np.array(rows))}, @tt{.copy_to_host().tolist()}}
             "here")
       (list @elem{@racket[flvector->device-vector], @racket[device-vector->flvector]}
             @tt{cudaMemcpyAsync}
             @elem{@tt{device_ndarray(np.asarray(xs))}, @tt{.copy_to_host()}}
             "here")
       (list @tt{device-array->list*}
             @elem{a copy to the host}
             @tt{.copy_to_host().tolist()}
             @status{L1c})
       (list @tt{matrix->device-matrix}
             @elem{a host copy, then @tt{raft::copy}}
             @tt{device_ndarray(np.array(A))}
             @status{L1c}))]
