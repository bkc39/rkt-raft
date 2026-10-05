#lang scribble/manual
@(require "../utils.rkt")

@(define ev (make-raft-eval))

@title[#:tag "resources"]{Resources and the GPU}

Every RAFT operation runs with a @tech{resources} object: the device it runs
on, the CUDA @tech{stream} it is queued on, and the library handles it needs.
This chapter writes one small batch program around them, a piece per section.
The program spreads its workers over the GPUs it finds; each worker processes
its batches on resources of its own and times every batch; and the program
reports the workers that failed.

The operations on device arrays arrive in the next chapter @status{L1b}, so
here a batch only checks its rows. Everything around that check stays the
same once real work goes in: each operation will be given the worker's
resources.

@section[#:tag "res-devices"]{Finding the GPU}

@racket[device-count] asks the driver how many CUDA devices this process can
see. They are numbered from 0, after @tt{CUDA_VISIBLE_DEVICES} has hidden
any. The program hands its workers out over them, round robin, and so never
asks for a device that is not there:

@examples[#:eval ev #:label #f
(device-count)
(define (device-for-worker i)
  (modulo i (device-count)))
(map device-for-worker '(0 1 2 3))
(eval:error (device-resources #:device 4))
]

@python|{
import cupy as cp

cp.cuda.runtime.getDeviceCount()            # 1

def device_for_worker(i):
    return i % cp.cuda.runtime.getDeviceCount()

[device_for_worker(i) for i in range(4)]    # [0, 0, 0, 0]
cp.cuda.Device(4).use()
# CUDARuntimeError: cudaErrorInvalidDevice: invalid device ordinal
}|

Both sides count the same devices and refuse the same missing one; they
differ in what they report. CuPy passes on CUDA's own error from switching to
the device. This library compares the number with the driver's count before
it makes anything there, and raises @racket[exn:fail:raft] of kind
@racket['logic], named after the Racket procedure you called.

@section[#:tag "res-default"]{Each worker's resources}

A worker runs many batches, so it makes its resources once and keeps them
for all of them: one stream, on which its batches run in order while other
workers' streams overlap with it, and one set of library handles. Making
resources for every batch instead would pay for a new stream and new library
handles each time. @racket[device-resources] makes new resources on a
device, owned by whoever made them:

@examples[#:eval ev #:label #f
(define r (device-resources #:device (device-for-worker 0)))
r
(resources-device r)
(eq? r (current-device-resources 0))
]

They are not the thread's default resources. @racket[current-device-resources]
keeps one set per thread and device, created the first time it is asked for,
and the operations on arrays @status{L1b} will fall back to it when they are
given no @racket[#:resources]. A worker owns its resources instead of
borrowing that default, so that it can release them when it is done without
taking the default away from other code on its thread.

@python|{
from pylibraft.common import DeviceResources

def worker_resources(device):
    with cp.cuda.Device(device):
        return DeviceResources()

handle = worker_resources(device_for_worker(0))
}|

The two sides differ in three ways:

@itemlist[
 @item{@bold{A default.} pylibraft has none: a pylibraft function called
       without @tt{handle=} makes a @tt{DeviceResources} for that one call.
       Racket keeps one per thread and device.}
 @item{@bold{Waiting.} That one-call @tt{DeviceResources} is synced before
       the function returns, so every such call waits for the GPU. Racket
       does not wait after a call: only when you call
       @racket[resources-sync!], or when a result comes back to Racket data
       @status{L1b}.}
 @item{@bold{The stream.} @tt{DeviceResources()} without a stream queues on
       @tt{cudaStreamPerThread}, CUDA's per-thread default stream, which any
       other code on that OS thread may also use. Each Racket resources
       object owns a stream of its own.}]

@section[#:tag "res-sync"]{Timing a batch}

Operations return as soon as they are queued, not when the GPU has finished
them. A program waits only when it has to: when a result comes back to Racket
data @status{L1b}, which will wait by itself, or when it calls
@racket[resources-sync!]. So timing a batch means syncing before reading the
clock; otherwise the time measured is only the time it took to queue the
work:

@examples[#:eval ev #:label #f
(define (process-batch rows)
  (for ([row (in-list rows)])
    (unless (= (length row) 2)
      (error 'process-batch "row ~a has ~a columns" row (length row))))
  (length rows))
(define (timed r thunk)
  (define start (current-inexact-milliseconds))
  (define result (thunk))
  (resources-sync! r)
  (values result (- (current-inexact-milliseconds) start)))
(timed r (lambda () (process-batch '((1.0 2.0) (3.0 4.0)))))
]

@python|{
import time

def process_batch(rows):
    for row in rows:
        if len(row) != 2:
            raise ValueError(f"row {row} has {len(row)} columns")
    return len(rows)

def timed(handle, f):
    start = time.perf_counter()
    result = f()
    handle.sync()
    return result, (time.perf_counter() - start) * 1000

timed(handle, lambda: process_batch([[1.0, 2.0], [3.0, 4.0]]))
# (2, 0.0153)
}|

The two waits behave differently while they wait. @tt{handle.sync()} blocks
its OS thread, holding Python's global interpreter lock, until the stream
drains, and Ctrl-C takes effect only once it returns (pylibraft offers a
cancellable wait in @tt{pylibraft.common.interruptible}).
@racket[resources-sync!] polls the stream instead, sleeping a few
microseconds to a millisecond between polls, so the other workers keep
running, the garbage collector is never held up by the GPU, and a break,
from Ctrl-C or @racket[break-thread], ends the wait with @racket[exn:break].

@section[#:tag "res-batch"]{A worker}

A worker takes its device and its batches, makes its resources, and times
each batch on them. It scopes the resources with
@racket[with-device-resources], so they are released the moment the worker
is done, whether it returns or fails, rather than whenever the garbage
collector finds them:

@examples[#:eval ev #:label #f
(define (run-worker device batches)
  (with-device-resources ([r (device-resources #:device device)])
    (for/list ([rows (in-list batches)])
      (define-values (n ms) (timed r (lambda () (process-batch rows))))
      (list n ms))))
(run-worker 0 (list '((1.0 2.0) (3.0 4.0)) '((5.0 6.0))))
]

@python|{
def run_worker(device, batches):
    handle = worker_resources(device)
    return [timed(handle, lambda: process_batch(rows)) for rows in batches]

run_worker(0, [[[1.0, 2.0], [3.0, 4.0]], [[5.0, 6.0]]])
# [(2, 0.0153), (1, 0.0017)]
}|

Python has no form for scoping a @tt{DeviceResources}: CPython frees the
worker's handle by reference counting once @tt{run_worker} returns and
nothing else refers to it.

@section[#:tag "res-threads"]{Fanning out}

Each worker runs in a thread of its own, on the resources it made, so each
queues on a stream of its own. Something raised in a Racket thread ends only
that thread, so each worker sends back a thunk that either returns its result
or raises again whatever was raised, and the program calls it. A worker can
also end without raising, when it is killed, so the program waits for each
worker's thread to die as well as for its answer, and never blocks on a
worker that is gone:

@examples[#:eval ev #:label #f
(define (run-workers worker jobs)
  (define answers
    (for/list ([job (in-list jobs)])
      (match-define (list device batches) job)
      (define done (make-channel))
      (define (send thunk) (channel-put done thunk))
      (define t
        (thread (lambda ()
                  (with-handlers ([(lambda (_) #t)
                                   (lambda (v) (send (lambda () (raise v))))])
                    (define result (worker device batches))
                    (send (lambda () result))))))
      (choice-evt done
                  (handle-evt (thread-dead-evt t)
                              (lambda (_) (lambda () (worker-died device)))))))
  (for/list ([answer (in-list answers)])
    ((sync answer))))
(define (worker-died device)
  (error 'run-workers "the worker on cuda:~a ended without an answer" device))
(define (report results)
  (for ([batches (in-list results)]
        [i (in-naturals)])
    (for ([batch (in-list batches)])
      (match-define (list n ms) batch)
      (printf "worker ~a: ~a rows in ~a ms\n"
              i n (~r ms #:precision '(= 2))))))
(define all-batches
  (list (list '((1.0 2.0) (3.0 4.0)) '((5.0 6.0)))
        (list '((7.0 8.0)))
        (list '((9.0 10.0) (11.0 12.0)))))
(define jobs
  (for/list ([batches (in-list all-batches)]
             [i (in-naturals)])
    (list (device-for-worker i) batches)))
(report (run-workers run-worker jobs))
]

@python|{
from concurrent.futures import ThreadPoolExecutor

def run_workers(worker, jobs):
    with ThreadPoolExecutor() as pool:
        futures = [pool.submit(worker, device, batches)
                   for device, batches in jobs]
        return [f.result() for f in futures]

def report(results):
    for i, batches in enumerate(results):
        for n, ms in batches:
            print(f"worker {i}: {n} rows in {ms:.2f} ms")

all_batches = [
    [[[1.0, 2.0], [3.0, 4.0]], [[5.0, 6.0]]],
    [[[7.0, 8.0]]],
    [[[9.0, 10.0], [11.0, 12.0]]],
]
jobs = [(device_for_worker(i), batches)
        for i, batches in enumerate(all_batches)]
report(run_workers(run_worker, jobs))
# worker 0: 2 rows in 0.07 ms
# worker 0: 1 rows in 0.00 ms
# worker 1: 1 rows in 0.00 ms
# worker 2: 2 rows in 0.00 ms
}|

Python's @tt{f.result()} raises a worker's exception again in the caller;
Racket has no such handle on a thread's result, so the channel carries it.
Racket threads made the usual way take turns on one OS thread, and a thread
made with @racket[#:pool 'own] runs on an OS thread of its own; either way,
the work queued on the workers' streams can overlap on the GPU. When a worker
waits in @racket[resources-sync!], the others keep running.

@section[#:tag "res-memory"]{Where device memory comes from}

Device memory is allocated by RMM, which keeps one current memory resource per
device for the whole process, shared by every library that links it: this
one, cuML, and anything else built on RAPIDS. RMM starts with a resource that
calls @tt{cudaMalloc} and @tt{cudaFree}, and @tt{cudaFree} waits for the
whole device to finish its work before it returns.

The first time this library makes resources on a device, it installs RMM's
CUDA async memory resource there instead: a @tt{cudaMallocAsync} pool, whose
allocations and frees are queued on a stream like any other operation, so
they need not wait for the rest of the device. It also keeps freed memory for
reuse rather than handing it back to the driver. You do not have to do
anything to get it; choosing a different resource from Racket arrives later
@status{L2}.

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
first resources are made instead. A device without memory-pool support keeps
RMM's default. Because the resource belongs to the process, a cuML binding
loaded into the same program allocates from the same pool.

@section[#:tag "res-errors"]{Reporting failed workers}

Every failure inside RAFT, RMM, CUDA or the native library raises
@racket[exn:fail:raft]. Its message starts with the Racket procedure that was
called, and its kind says what failed, so a handler can tell a full GPU
(@racket['out-of-memory]) from a mistake in the call (@racket['logic]). A
worker that catches it can hand it back as its result, and the program
reports it next to the workers that succeeded. Here the second job was
configured for a GPU this machine does not have:

@examples[#:eval ev #:label #f
(define (run-worker/caught device batches)
  (with-handlers ([exn:fail:raft? values])
    (run-worker device batches)))
(define (failures results)
  (for/list ([result (in-list results)]
             [i (in-naturals)]
             #:when (exn:fail:raft? result))
    (list i (exn:fail:raft-kind result) (exn-message result))))
(match-define (list batches-0 batches-1 _) all-batches)
(define results
  (run-workers run-worker/caught
               (list (list 0 batches-0) (list 4 batches-1))))
(failures results)
]

@python|{
from cupy.cuda.runtime import CUDARuntimeError

def run_worker_caught(device, batches):
    try:
        return run_worker(device, batches)
    except CUDARuntimeError as e:
        return e

def failures(results):
    return [(i, str(r)) for i, r in enumerate(results)
            if isinstance(r, Exception)]

results = run_workers(run_worker_caught,
                      [(0, all_batches[0]), (4, all_batches[1])])
failures(results)
# [(1, 'cudaErrorInvalidDevice: invalid device ordinal')]
}|

Python reports each layer's failure in that layer's own exception type: CuPy's
@tt{CUDARuntimeError} here, a @tt{RuntimeError} from RAFT, a
@tt{MemoryError} from RMM, so a worker has to know which to catch. Racket has
the one type, with the kind as a field, and the message keeps the original
cause after the name of the procedure that was called.
