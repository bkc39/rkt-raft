#lang scribble/manual
@(require "../utils.rkt")

@(define ev (make-raft-eval))

@title[#:tag "concepts"]{Concepts}

This chapter explains the model the library is built on: where data lives,
what a @emph{resources} object is, what an array is, how memory comes back,
and what an error looks like. Most of the names it mentions do not exist yet;
each is marked with the leg that adds it (@status{L1a} to @status{L3}) and is
described here, not called, so the chapter can be read as the design before
the code.

@section[#:tag "concepts-memory"]{Device memory and host memory}

A GPU has its own memory. Racket values (lists, vectors, flvectors,
@racketmodname[math/matrix] matrices) live in host memory, managed by Racket's
garbage collector. A RAFT array lives in device memory, managed by RMM, the
RAPIDS memory manager. Kernels only read device memory, so data crosses from
one side to the other by an explicit copy over the PCIe bus, and comes back the
same way.

The workflow is always the same three steps: build or load data in Racket,
copy it to the device once, run as many GPU operations as you like on it there,
and copy back only the results you want to look at. The copies are the
expensive part, so the API makes them visible: a conversion such as
@racket[list->device-vector] or @racket[device-vector->list] @status{L1b} is
always a copy, and nothing else is.

In Python the round trip is one line:

@python|{
import numpy as np
from pylibraft.common import device_ndarray

device_ndarray(np.array([1.5, -2.25, 0.0])).copy_to_host()   # array([ 1.5 , -2.25,  0.  ])
}|

Racket will spell it @racket[(device-vector->list (list->device-vector xs))]
@status{L1b}. Both sides pack the values into a contiguous host buffer before
the copy. In Python that buffer is the NumPy array you build, and its element
type is chosen there; in Racket the conversion packs the list itself and takes
@racket[#:dtype].

@section[#:tag "concepts-resources"]{Resources and streams}

Every RAFT operation takes a @deftech{resources} object, the C++
@tt{raft::handle_t} (pylibraft calls it @tt{DeviceResources}). It is the
operation's context: the device it runs on, the CUDA stream it is queued on,
the cuBLAS, cuSOLVER and cuSPARSE handles it needs (created on first use), and
the scratch memory it may borrow. cuML takes the same object, which is why the
Racket resources will be a real @tt{raft::handle_t}: a later cuML binding can
use it unchanged.

A @deftech{stream} is an ordered queue of GPU work. Operations queued on one
stream run in order; work on two streams may overlap. Each resources object
owns one stream, so everything done with it is ordered. Operations return as
soon as they are queued, and the program waits only when a value has to reach
the host: converting an array back to Racket data, printing one, or calling
@racket[resources-sync!] @status{L1a}. pylibraft instead synchronizes after
every call made without an explicit handle; Racket does not copy that, because
waiting after every call leaves the GPU idle between operations.

You will rarely make one by hand. @racket[current-device-resources]
@status{L1a} keeps one per Racket thread and device, created on first use, and
every operation takes @racket[#:resources] to override it, the way pylibraft
takes @tt{handle=}.

@python|{
from pylibraft.common import DeviceResources, Stream

stream = Stream()                           # keep it: the handle does not
handle = DeviceResources(stream=stream)     # its own stream and library handles
...                                         # pass handle=handle to each call
handle.sync()                               # wait for everything queued on it
}|

The two sides differ twice here. Without a @tt{stream} argument,
@tt{DeviceResources()} queues its work on CUDA's per-thread default stream,
which every handle made on that thread shares. And a handle does not keep its
@tt{Stream} alive: @tt{DeviceResources(stream=Stream())} fails at the next
@tt{sync()} with @tt{cudaErrorContextIsDestroyed}, once the temporary is
collected. A Racket resources object always owns its stream, and every buffer
allocated through it keeps that stream alive, because a buffer's finalizer
releases its memory on that stream, from whatever OS thread it runs on.

@section[#:tag "concepts-arrays"]{Arrays}

@subsection[#:tag "concepts-buffers-views"]{Buffers and views}

RAFT separates owning memory (@tt{mdarray}) from looking at it
(@tt{mdspan}). The Racket model keeps the split. A @deftech{buffer} is one
native RMM allocation: it is the only thing with a finalizer and the only
thing the garbage collector is told about. An @deftech{array} is a plain
Racket value that points into a buffer and says how to read it: shape,
strides, offset and element type. Slicing or transposing an array
@status{L3} builds a new Racket value over the same buffer; it never calls into
the native library and never copies.

The first arrays are @racket[device-matrix] and @racket[device-vector]
@status{L1b}, named after their type the way @racket[vector] and
@racket[string] are: @racket[(device-matrix 1000 128)] is a new, uninitialised
1000-by-128 matrix, ready to be an operation's output.

@subsection[#:tag "concepts-dtypes"]{Element types}

Each array has one element type, its @deftech{dtype}: @racket['float32],
@racket['float64], @racket['int32] or @racket['int64] to begin with. When
converting Racket data, the type is inferred as NumPy does (exact integers give
@racket['int64], any other real number @racket['float64]), and
@racket[#:dtype] overrides it. cuML is mostly used in @racket['float32]: it
halves the memory, and consumer GPUs run @racket['float64] arithmetic at a
small fraction of their @racket['float32] speed.

@subsection[#:tag "concepts-layout"]{Row-major and column-major layout}

Device memory is one-dimensional, so a matrix needs a rule for laying out its
rows and columns. @deftech{Row-major} order stores each row contiguously, as C
and NumPy do by default; @deftech{column-major} order stores each column
contiguously, as Fortran, BLAS and LAPACK do. The same 2-by-3 matrix in each:

@examples[#:eval ev #:label #f
(define m '((1 2 3)
            (4 5 6)))
(define (row-major rows) (apply append rows))
(define (column-major rows) (apply append (apply map list rows)))
(row-major m)
(column-major m)
]

An array records its layout as @deftech{strides}: how many elements to step
to move one place along each axis. Row-major 2-by-3 has strides
@racket['(3 1)], column-major @racket['(1 2)]. Racket counts strides in
elements, as RAFT, DLPack and PyTorch do; NumPy and CuPy count bytes.

@python|{
import numpy as np
m = np.array([[1, 2, 3], [4, 5, 6]], dtype=np.float64)
m.ravel(order="K").tolist()                     # [1.0, 2.0, 3.0, 4.0, 5.0, 6.0]
np.asfortranarray(m).ravel(order="K").tolist()  # [1.0, 4.0, 2.0, 5.0, 3.0, 6.0]
m.strides, np.asfortranarray(m).strides         # ((24, 8), (8, 16)), in bytes
}|

Layout matters because RAFT's kernels are compiled for a layout, and cuML's
entry points expect a particular one: k-means and DBSCAN read row-major data,
while cuML's least-squares solvers force column-major. The binding never
converts silently. An operation given a layout it was not compiled for raises
an error naming the operation, and @racket[contiguous] @status{L1b} makes the
copy explicit: @racket[(contiguous X #:layout 'col-major)]. Converting host
data with @racket[#:layout 'col-major] @status{L1c} packs it in column order
on the host, so no transpose runs on the GPU at all.

@section[#:tag "concepts-reclaiming"]{How memory is reclaimed}

You never free an array. When a buffer becomes unreachable, Racket's garbage
collector runs its finalizer, which hands the allocation back to RMM on the
stream it was allocated on, after selecting the buffer's device, since
finalizers can run on any OS thread. A buffer also keeps its resources object's
stream alive, so it can outlive the resources it was made with.

The collector cannot see device memory: to it, a buffer is a small Racket
object, so it would happily let gigabytes of dead buffers pile up on the GPU
before collecting. Each buffer therefore reports its size to the collector as
@deftech{phantom bytes} @status{L1b}, the way Racket's own foreign allocations
can, so that holding a lot of device memory triggers collections just as
holding a lot of host memory does.

When release has to happen at a known point, a @tt{with-} form releases on
exit, whether the body returns, raises or escapes, and the finalizer stays as
a backstop: @racket[with-device-resources] @status{L1a} for resources, and a
form for arrays @status{L3}.

@python|{
X = device_ndarray.empty((1000, 128), dtype=np.float32)
del X          # CPython frees it now, through the reference count
}|

CPython frees an array the moment its last reference goes; Racket frees it at
the next collection that finds it unreachable. Code that allocates in a loop
does not need to care, because the phantom bytes make collections come sooner;
code that wants memory back at an exact point uses a @tt{with-} form.

@section[#:tag "concepts-errors"]{Errors}

Every failure inside RAFT, RMM, CUDA or the native library raises one
exception type, @racket[exn:fail:raft] @status{L1a}, whose message is the name
of the Racket function you called followed by RAFT's own message, or the
native library's. It also records a kind (@racket['out-of-memory],
@racket['cuda], @racket['logic] or @racket['generic]), because the memory
manager will retry an allocation once after an out-of-memory failure. A C++
exception never reaches Racket: the native library catches every one and turns
it into an error status, since an exception unwinding into Racket would abort
the process. The message of the last failure is kept per OS thread and read in
the same atomic step as the call, so another Racket thread cannot overwrite it
in between.

There are no contracts yet: argument checking arrives once the API has
settled. Until then a wrong argument is reported by RAFT or by the native
library, in their words. What the native library does already check is
anything that could corrupt memory or crash: an element type, layout or rank
it cannot handle, or an output that is too small, is refused before the GPU is
touched. Copying 16 bytes into an 8-byte buffer, for example, raises
@racket[exn:fail:raft] with the message
@tt{copy: rr_copy_h2d: 16 bytes do not fit a buffer of 8 bytes}, where
@tt{copy} is the Racket function that asked for the copy and
@tt{rr_copy_h2d} the native entry point that refused it.

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
       (list @racket[device-resources]
             @tt{raft::handle_t}
             @tt{pylibraft.common.DeviceResources}
             @status{L1a})
       (list @racket[current-device-resources]
             @tt{raft::device_resources_manager}
             @tt{handle=None}
             @status{L1a})
       (list @racket[resources-sync!]
             @tt{raft::resource::sync_stream}
             @tt{DeviceResources.sync()}
             @status{L1a})
       (list @racket[cuda-async-memory-resource]
             @tt{rmm::mr::cuda_async_memory_resource}
             @tt{rmm.mr.CudaAsyncMemoryResource}
             @status{L1a})
       (list @racket[exn:fail:raft]
             @elem{@tt{raft::exception}, @tt{rmm::bad_alloc}}
             @elem{@tt{RuntimeError}, @tt{MemoryError}}
             @status{L1a})
       (list @racket[device-matrix]
             @tt{raft::make_device_matrix}
             @tt{device_ndarray.empty((r, c))}
             @status{L1b})
       (list @racket[device-vector]
             @tt{raft::make_device_vector}
             @tt{device_ndarray.empty((n,))}
             @status{L1b})
       (list @elem{@racket[shape], @racket[dtype], @racket[layout]}
             @elem{@tt{extents()}, @tt{value_type}, the layout policy}
             @elem{@tt{.shape}, @tt{.dtype}, @tt{order=}}
             @status{L1b})
       (list @racket[contiguous]
             @tt{raft::linalg::transpose}
             @elem{@tt{cp.ascontiguousarray}, @tt{np.asfortranarray}}
             @status{L1b})
       (list @elem{@racket[list->device-vector], @racket[device-vector->list]}
             @elem{@tt{raft::copy} from and to the host}
             @elem{@tt{device_ndarray(np.array(xs))}, @tt{.copy_to_host().tolist()}}
             @status{L1b})
       (list @racket[device-array->list*]
             @elem{@tt{raft::copy} to the host}
             @tt{.copy_to_host().tolist()}
             @status{L1b})
       (list @racket[matrix->device-matrix]
             @elem{a host copy, then @tt{raft::copy}}
             @tt{device_ndarray(np.array(A))}
             @status{L1c}))]
