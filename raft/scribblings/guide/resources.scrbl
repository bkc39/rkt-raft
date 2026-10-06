#lang scribble/manual
@(require "../utils.rkt")

@(define ev (make-raft-eval))

@title[#:tag "resources"]{Resources and the GPU}

Every RAFT operation runs with a @tech{resources} object: a device, a CUDA
@tech{stream} and the library handles it needs. This chapter builds one batch
program around them: workers spread over the GPUs, each timing its batches on
resources of its own, and a report of the workers that failed. Device arrays
are the next chapter, @secref["arrays"], and the operations that compute with
them arrive later, so here a batch only checks its rows.

@section[#:tag "res-devices"]{Finding the GPU}

@racket[device-count] is the number of visible devices, numbered from 0. The
program hands workers out over them round robin:

@examples[#:eval ev #:label #f
(device-count)
(define (device-for-worker i)
  (modulo i (device-count)))
(map device-for-worker '(0 1 2 3))
(eval:error (device-resources #:device 4))
]

A device the driver does not report raises @racket[exn:fail:raft] of kind
@racket['logic], named after the procedure you called.

@section[#:tag "res-default"]{Each worker's resources}

A worker makes its resources once and keeps them for all its batches: one
stream, on which its batches run in order while other workers' streams
overlap, and one set of library handles. @racket[device-resources] makes new
resources on a device:

@examples[#:eval ev #:label #f
(define r (device-resources #:device (device-for-worker 0)))
r
(resources-device r)
(eq? r (current-device-resources 0))
]

They are not the thread's default, @racket[current-device-resources], which
the array constructors and conversions fall back to without
@racket[#:resources].
Owning its resources lets a worker release them without taking the default
from other code on its thread.

The default is per thread and device, and each resources object owns its
stream.

@section[#:tag "res-sync"]{Timing a batch}

Operations return once queued. Timing a batch means calling
@racket[resources-sync!] before reading the clock; otherwise it times only the
queueing:

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

@racket[resources-sync!] polls rather than blocking its OS thread, so other
threads keep running and a break ends the wait.

@section[#:tag "res-batch"]{A worker}

A worker makes its resources with @racket[with-device-resources] and times
each batch on them:

@examples[#:eval ev #:label #f
(define (run-worker device batches)
  (with-device-resources ([r (device-resources #:device device)])
    (for/list ([rows (in-list batches)])
      (define-values (n ms) (timed r (lambda () (process-batch rows))))
      (list n ms))))
(run-worker 0 (list '((1.0 2.0) (3.0 4.0)) '((5.0 6.0))))
]

The finalizer alone would be correct: it releases resources once they are
unreachable. @racket[with-device-resources] gives their lifetime a clear
timeline, a release when the worker returns or fails, because resources hold
GPU and driver state the collector cannot see: a CUDA stream and lazily
created cuBLAS, cuSOLVER and cuSPARSE handles.

@section[#:tag "res-threads"]{Fanning out}

Each worker runs in its own thread and queues on its own stream. It sends
back a thunk that returns its result or re-raises, and the program also
watches for a thread that dies without answering:

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

The channel carries an exception back as a thunk, and calling the thunk
re-raises it.

@section[#:tag "res-memory"]{Where device memory comes from}

Device memory comes from RMM, whose current memory resource is per device and
shared by every library in the process, cuML included. The first resources
made on a device replace RMM's default (@tt{cudaMalloc}, which synchronizes
the device) with a stream-ordered @tt{cudaMallocAsync} pool. Choosing another
resource from Racket arrives later @status{L2}.

A resource installed by anything else is left alone, except a plain
@tt{rmm::mr::cuda_memory_resource}, which looks like the default; see
@secref["ref-core-memory"].

@section[#:tag "res-errors"]{Reporting failed workers}

Every failure raises @racket[exn:fail:raft], whose kind tells a full GPU
(@racket['out-of-memory]) from a bad call (@racket['logic]). A worker can
return it as its result; here the second job names a missing GPU:

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

One exception type covers every layer, with the kind as a field.
