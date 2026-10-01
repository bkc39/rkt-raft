#lang scribble/manual
@(require "../utils.rkt")

@(define ev (make-raft-eval))

@title[#:tag "resources"]{Resources and the GPU}

Every RAFT operation runs with a @tech{resources} object: the device it runs
on, the CUDA @tech{stream} it is queued on, and the library handles it needs.
This chapter builds the skeleton of a batch program around them, one piece at
a time. The program checks its GPU, gives each batch resources of its own,
fans batches out to worker threads, times them, and reports what failed.

The operations themselves, on device arrays, arrive in the next chapter
@status{L1b}, so here the batches only check their rows. Everything around
them stays the same once real work goes in, each operation given the batch's
resources with @racket[#:resources].

@section[#:tag "res-devices"]{Finding the GPU}

@racket[device-count] asks the driver how many CUDA devices this process can
see. They are numbered from 0, after @tt{CUDA_VISIBLE_DEVICES} has hidden
any. Resources can be made on any of them, and on no other:

@examples[#:eval ev #:label #f
(device-count)
(eval:error (device-resources #:device 4))
]

@python|{
import cupy as cp

cp.cuda.runtime.getDeviceCount()   # 1
cp.cuda.Device(4).use()            # CUDARuntimeError: cudaErrorInvalidDevice:
                                   #   invalid device ordinal
}|

Both sides count the same devices and refuse the same missing one; they
differ in what they report. CuPy passes on CUDA's own error from switching to
the device. This library compares the number with the driver's count before
it makes anything there, and raises @racket[exn:fail:raft] of kind
@racket['logic], named after the Racket procedure you called (see
@secref["res-errors"]).

@section[#:tag "res-default"]{The default resources}

Most code never makes resources. @racket[current-device-resources] returns
the calling thread's default for a device, creating it the first time it is
asked for, and every operation that takes @racket[#:resources] falls back to
it:

@examples[#:eval ev #:label #f
(define r (current-device-resources))
r
(resources-device r)
(eq? r (current-device-resources))
]

@python|{
from pylibraft.common import DeviceResources

handle = DeviceResources()      # queues on cudaStreamPerThread
handle.sync()
# each pylibraft function takes handle=handle; called without one, it makes a
# DeviceResources of its own and syncs it before returning
}|

The two sides differ in three ways:

@itemlist[
 @item{@bold{A default.} pylibraft has none: a function called without
       @tt{handle=} makes a @tt{DeviceResources} for that one call. Racket
       keeps one per thread and device, so a stream and the library handles
       are created once.}
 @item{@bold{Waiting.} That one-call @tt{DeviceResources} is synced before
       the function returns, so every such call waits for the GPU. Racket
       never waits on your behalf.}
 @item{@bold{The stream.} @tt{DeviceResources()} without a stream queues on
       @tt{cudaStreamPerThread}, CUDA's per-thread default stream, which any
       other code on that OS thread may also use. Each Racket resources
       object owns a stream of its own.}]

@section[#:tag "res-batch"]{Resources for a batch job}

A batch job that should not share its stream with anything else, and should
give its resources back the moment it is done, makes its own and scopes them
with @racket[with-device-resources]. The resources are released when the
form is left, whether the batch returns or fails:

@examples[#:eval ev #:label #f
(define (process-batch rows)
  (with-device-resources ([r (device-resources)])
    (for ([row (in-list rows)])
      (unless (= (length row) 2)
        (error 'process-batch "row ~a has ~a columns" row (length row))))
    (resources-sync! r)
    (length rows)))
(process-batch '((1.0 2.0) (3.0 4.0)))
(eval:error (process-batch '((1.0 2.0) (3.0))))
]

@python|{
from pylibraft.common import DeviceResources

def process_batch(rows):
    handle = DeviceResources()
    for row in rows:
        if len(row) != 2:
            raise ValueError(f"row {row} has {len(row)} columns")
    handle.sync()
    return len(rows)

process_batch([[1.0, 2.0], [3.0, 4.0]])   # 2
process_batch([[1.0, 2.0], [3.0]])        # ValueError: row [3.0] has 1 columns
}|

Python needs no form for this: CPython frees the handle by reference counting
as soon as the function lets go of it. Racket frees resources that are not
scoped when the garbage collector finds them unreachable, at a time of its
choosing; @racket[with-device-resources] is how you choose the time
yourself.

@section[#:tag "res-threads"]{One resources object per worker thread}

Batches can run in Racket threads. Each thread gets its own default
resources, and with them its own stream, because the default lives in a
thread cell rather than a parameter: a new thread does not inherit its
parent's, so two threads never queue on one stream by accident.

@examples[#:eval ev #:label #f
(define (run-workers n job)
  (define results
    (for/list ([i (in-range n)])
      (define done (make-channel))
      (thread (lambda () (channel-put done (job i))))
      done))
  (map channel-get results))
(define (worker i)
  (define r (current-device-resources))
  (resources-sync! r)
  r)
(define used (run-workers 3 worker))
used
(define everyone (cons (current-device-resources) used))
(length (remove-duplicates everyone eq?))
]

The three workers and the main thread hold four different resources objects.

@python|{
import threading
from pylibraft.common import DeviceResources

local = threading.local()

def thread_resources():
    if not hasattr(local, "handle"):
        local.handle = DeviceResources()
    return local.handle

def run_workers(n, job):
    results = [None] * n
    def run(i):
        results[i] = job(i)
    threads = [threading.Thread(target=run, args=(i,)) for i in range(n)]
    for t in threads: t.start()
    for t in threads: t.join()
    return results

def worker(i):
    handle = thread_resources()
    handle.sync()
    return handle

used = run_workers(3, worker)
len({id(h) for h in used + [thread_resources()]})   # 4
}|

Python has no per-thread default, so the thread-local cache is yours to
write. Racket threads made the usual way take turns on one OS thread, and a
thread made with @racket[#:pool 'own] runs on an OS thread of its own; either
kind gets its own default, and the work the threads queue on their four
streams can overlap on the GPU. When a thread waits in
@racket[resources-sync!], the others keep running.

@section[#:tag "res-sync"]{Waiting for the GPU}

Operations return as soon as they are queued, not when the GPU has finished
them. A program waits only when it has to: when a result is converted back to
Racket data, which waits by itself, or when it calls @racket[resources-sync!].
Call it before stopping a clock, or the time measured is only the time it
took to queue the work:

@examples[#:eval ev #:label #f
(define (timed r thunk)
  (define start (current-inexact-milliseconds))
  (define result (thunk))
  (resources-sync! r)
  (values result (- (current-inexact-milliseconds) start)))
(define-values (answer ms) (timed (current-device-resources) (lambda () 42)))
answer
ms
]

@python|{
import time

def timed(handle, f):
    start = time.perf_counter()
    result = f()
    handle.sync()
    return result, (time.perf_counter() - start) * 1000

timed(handle, lambda: 42)                  # (42, 0.0061)
}|

The two waits behave differently while they wait. @tt{handle.sync()} blocks
its OS thread, holding Python's global interpreter lock, until the stream
drains, and Ctrl-C takes effect only once it returns (pylibraft offers a
cancellable wait in @tt{pylibraft.common.interruptible}).
@racket[resources-sync!] polls the stream instead, sleeping a few
microseconds to a millisecond between polls, so other Racket threads keep
running, the garbage collector is never held up by the GPU, and a break,
from Ctrl-C or @racket[break-thread], ends the wait with @racket[exn:break].

@section[#:tag "res-memory"]{Where device memory comes from}

Device memory is allocated by RMM, which keeps one current memory resource per
device for the whole process, shared by every library that links it: this
one, cuML, and anything else built on RAPIDS. RMM starts with a resource that
calls @tt{cudaMalloc} and @tt{cudaFree}, and @tt{cudaFree} waits for the
whole device to finish its work before it returns.

The first time this library makes resources on a device, it installs RMM's
CUDA async memory resource there instead: a @tt{cudaMallocAsync} pool, whose
allocations and frees are queued on a stream like any other operation and do
not stop the device. It also keeps freed memory for reuse rather than handing
it back to the driver. You do not have to do anything to get it; choosing a
different resource from Racket arrives later @status{L2}.

@python|{
import rmm

rmm.mr.get_current_device_resource()      # CudaMemoryResource, RMM's default
rmm.mr.set_current_device_resource(rmm.mr.CudaAsyncMemoryResource())
rmm.mr.get_current_device_resource()      # CudaAsyncMemoryResource
}|

Python leaves RMM's default in place until you change it. This library
changes it on first use, but only if nothing has changed it before: a pool
that another library installed first, or that you install afterwards, is left
alone. A plain @tt{CudaMemoryResource} set on purpose beforehand, for example
to find out-of-bounds accesses with @tt{compute-sanitizer}, which a pool
hides, looks the same as RMM's default and is replaced; set it after the
first resources are made instead. Because the resource belongs to the
process, a cuML binding loaded into the same program allocates from the same
pool.

@section[#:tag "res-errors"]{When something goes wrong}

Every failure inside RAFT, RMM, CUDA or the native library raises
@racket[exn:fail:raft]. Its message starts with the Racket procedure you
called, and its kind says what failed, so a handler can tell a full GPU
(@racket['out-of-memory]) from a mistake in the call (@racket['logic]):

@examples[#:eval ev #:label #f
(define (try-device d)
  (with-handlers ([exn:fail:raft?
                   (lambda (e) (list (exn:fail:raft-kind e) (exn-message e)))])
    (resources-device (device-resources #:device d))))
(try-device 0)
(try-device 12)
]

Resources that have been released cannot be used again, and saying so is the
library's job, not the GPU's:

@examples[#:eval ev #:label #f
(define finished (with-device-resources ([r (device-resources)]) r))
finished
(eval:error (resources-sync! finished))
]

@python|{
import cupy as cp
from pylibraft.common import DeviceResources

with cp.cuda.Device(12):
    DeviceResources()   # CUDARuntimeError: cudaErrorInvalidDevice:
                        #   invalid device ordinal
}|

Python reports each layer's failure in that layer's own exception type: CuPy's
@tt{CUDARuntimeError} here, a @tt{RuntimeError} from RAFT, a
@tt{MemoryError} from RMM. Racket has the one type, with the kind as a field,
and the message keeps the original cause after the name of the procedure that
was called.
