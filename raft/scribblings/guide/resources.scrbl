#lang scribble/manual
@(require "../utils.rkt")

@(define ev (make-raft-eval))

@title[#:tag "resources"]{Resources and the GPU}

Every RAFT operation runs with a @tech{resources} object: the device it runs
on, the CUDA @tech{stream} it is queued on, and the library handles it needs.
This chapter builds the skeleton of a batch program around them, one piece at
a time. The program picks its GPU from configuration, gives each batch
resources of its own, fans batches out to worker threads, times them, and
reports what failed.

The operations themselves, on device arrays, arrive in the next chapter
@status{L1b}, so here the batches only check their rows. Everything around
them stays the same once real work goes in, each operation given the batch's
resources with @racket[#:resources].

@section[#:tag "res-devices"]{Finding the GPU}

@racket[device-count] asks the driver how many CUDA devices this process can
see. They are numbered from 0, after @tt{CUDA_VISIBLE_DEVICES} has hidden
any:

@examples[#:eval ev #:label #f
(device-count)
]

A program that takes its GPU from a setting should check it before it builds
anything on it:

@examples[#:eval ev #:label #f
(define (check-device wanted)
  (unless (< wanted (device-count))
    (error 'check-device "GPU ~a requested, but only ~a visible"
           wanted (device-count)))
  wanted)
(check-device 0)
(eval:error (check-device 4))
]

@python|{
import cupy as cp

cp.cuda.runtime.getDeviceCount()          # 1

def check_device(wanted):
    count = cp.cuda.runtime.getDeviceCount()
    if wanted >= count:
        raise ValueError(f"GPU {wanted} requested, but only {count} visible")
    return wanted

check_device(0)                           # 0
cp.cuda.Device(4).use()                   # CUDARuntimeError: cudaErrorInvalidDevice:
                                          #   invalid device ordinal
}|

The count is the same number on both sides. The difference is where a missing
device is caught: CuPy finds out when it asks CUDA to switch to the device,
while this library checks the number against @racket[device-count] before it
asks CUDA for anything, and raises @racket[exn:fail:raft] naming the Racket
procedure you called (see @secref["res-errors"]).

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

The two sides differ in three ways. pylibraft has no default: a function
called without @tt{handle=} makes a new @tt{DeviceResources} for that one
call and waits for it before returning, so every such call stops the program
until the GPU has finished. Racket keeps one resources object per thread and
never waits on your behalf. A @tt{DeviceResources()} made without a stream
queues its work on @tt{cudaStreamPerThread}, CUDA's per-thread default
stream, shared with any other code on that OS thread that uses it, while each
Racket resources object owns a stream of its own. And a Racket default is created once per thread and device, so its
cost, a stream and the handles it creates on first use, is paid once.

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
    try:
        for row in rows:
            if len(row) != 2:
                raise ValueError(f"row {row} has {len(row)} columns")
        handle.sync()
        return len(rows)
    finally:
        del handle

process_batch([[1.0, 2.0], [3.0, 4.0]])   # 2
process_batch([[1.0, 2.0], [3.0]])        # ValueError: row [3.0] has 1 columns
}|

@tt{DeviceResources} has no @tt{with} form. CPython frees it when the last
reference goes, so the @tt{del} in @tt{finally} releases it at once unless
something else still holds it. In Racket, resources that are not scoped are
released by the garbage collector once they are unreachable, at a time of its
choosing; @racket[with-device-resources] is how you choose the time yourself.

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
(length (remove-duplicates (cons (current-device-resources) used) eq?))
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
write. Racket threads all run on one OS thread, taking turns; the parallelism
is on the GPU, where work queued on the four streams can overlap. When a
thread waits in @racket[resources-sync!], the others keep running.

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
(list answer (< ms 1000.0))
]

@python|{
import time

def timed(handle, f):
    start = time.perf_counter()
    result = f()
    handle.sync()
    return result, (time.perf_counter() - start) * 1000

result, ms = timed(handle, lambda: 42)
result, ms < 1000                          # (42, True)
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
alone. Because the resource belongs to the process, a cuML binding loaded
into the same program allocates from the same pool.

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
    DeviceResources()   # CUDARuntimeError: cudaErrorInvalidDevice: invalid device ordinal
}|

Python reports each layer's failure in that layer's own exception type: CuPy's
@tt{CUDARuntimeError} here, a @tt{RuntimeError} from RAFT, a
@tt{MemoryError} from RMM. Racket has the one type, with the kind as a field,
and the message keeps the original cause after the name of the procedure that
was called.
