#lang scribble/manual
@(require "../utils.rkt")

@(define ev (make-raft-eval))

@title[#:tag "ref-core"]{Resources, devices and errors: @racketmodname[raft/core]}

@defmodule[raft/core]

@tech{Resources}, devices, the exception type, and the native library's
version and ABI tag. @racketmodname[raft] re-exports all of it; see
@secref["resources"] for a tutorial.

@section[#:tag "ref-core-resources"]{Device resources}

@defproc[(device-resources [#:device device exact-nonnegative-integer? 0])
         device-resources?]{

Creates new @tech{resources} on @racket[device], with a CUDA @tech{stream} of
their own, not CUDA's per-thread default stream; library handles are created
when first needed. The first resources on a device install the default
memory resource (@secref["ref-core-memory"]). A @racket[device] the driver
does not report raises @racket[exn:fail:raft] of kind @racket['logic].

@examples[#:eval ev
(define r (device-resources))
r
(resources-device r)
]

Each call makes independent resources with their own stream:

@examples[#:eval ev #:label #f
(define loader (device-resources))
(define trainer (device-resources))
(eq? loader trainer)
(map resources-device (list loader trainer))
]

@racket[(device-count)] is the first number that is not a device:

@examples[#:eval ev #:label #f
(device-count)
(eval:error (device-resources #:device (device-count)))
]}

@defproc[(device-resources? [v any/c]) boolean?]{

Returns @racket[#t] if @racket[v] is a resources object, released or not.

@examples[#:eval ev
(device-resources? (current-device-resources))
(device-resources? 0)
]

Accepting either a device number or resources:

@examples[#:eval ev #:label #f
(define (as-resources where)
  (if (device-resources? where)
      where
      (current-device-resources where)))
(eq? (as-resources 0) (current-device-resources))
(eq? (as-resources loader) loader)
]

Released resources still satisfy it:

@examples[#:eval ev #:label #f
(define finished (with-device-resources ([r (device-resources)]) r))
(device-resources? finished)
]}

@defproc[(resources-device [resources device-resources?])
         exact-nonnegative-integer?]{

Returns the device @racket[resources] run on, even after release.

@examples[#:eval ev
(resources-device (current-device-resources))
]

Naming the device in a log line:

@examples[#:eval ev #:label #f
(printf "training on cuda:~a\n" (resources-device trainer))
]

Checking that two resources share a device:

@examples[#:eval ev #:label #f
(define (same-device? a b)
  (= (resources-device a) (resources-device b)))
(same-device? loader trainer)
(resources-device finished)
]}

@defproc[(resources-sync! [resources device-resources?]) void?]{

Waits until every operation queued on @racket[resources]' stream has
finished; @tt{DeviceResources.sync()}. The wait polls, so other Racket threads
keep running, and a break ends it with @racket[exn:break]. Released resources
raise @racket[exn:fail:raft] of kind @racket['logic].

@examples[#:eval ev
(resources-sync! (current-device-resources))
]

Timing GPU work, which returns once queued:

@examples[#:eval ev #:label #f
(define (milliseconds-on r thunk)
  (define start (current-inexact-milliseconds))
  (thunk)
  (resources-sync! r)
  (- (current-inexact-milliseconds) start))
(milliseconds-on trainer void)
]

Waiting in a thread of its own:

@examples[#:eval ev #:label #f
(thread-wait
 (thread (lambda ()
           (resources-sync! trainer)
           (displayln "the trainer's stream has drained"))))
]

@examples[#:eval ev #:label #f
(eval:error (resources-sync! finished))
]}

@defproc[(current-device-resources [device exact-nonnegative-integer? 0])
         device-resources?]{

Returns the calling thread's default resources for @racket[device], creating
them on first use, or again after they are released. Operations given no
@racket[#:resources] @status{L1b} use it. Each Racket thread has its own, so
threads never share a stream by accident.

@examples[#:eval ev
(eq? (current-device-resources) (current-device-resources))
(eq? (current-device-resources) (current-device-resources 0))
]

Each thread gets its own:

@examples[#:eval ev #:label #f
(define (worker-resources)
  (define answer (make-channel))
  (thread (lambda () (channel-put answer (current-device-resources))))
  (channel-get answer))
(define a (worker-resources))
(define b (worker-resources))
(list (eq? a b) (eq? a (current-device-resources)))
]

Releasing the default makes the next call create a new one:

@examples[#:eval ev #:label #f
(define before (current-device-resources))
(with-device-resources ([r before])
  (resources-sync! r))
before
(eq? before (current-device-resources))
]}

@defform[(with-device-resources ([id resources-expr] ...) body ...+)
         #:contracts ([resources-expr device-resources?])]{

Binds each @racket[id] as by @racket[let*], evaluates the @racket[body]s, and
releases every bound resources object when control leaves the form by return,
raise or escape. Release is idempotent; re-entering the body by a
continuation raises @racket[exn:fail:raft] of kind @racket['logic]. Arrays
allocated with the resources @status{L1b} keep the stream and handles alive
until the last of them is freed.

The finalizer alone is correct: it releases unreachable resources at some
collection. The form gives their lifetime a clear timeline, a release at a
known point, because resources hold GPU and driver state the collector cannot
see: a CUDA stream and lazily created cuBLAS, cuSOLVER and cuSPARSE handles.
Scoped, they are released when the body exits:

@examples[#:eval ev #:label #f
(define unscoped (device-resources))
(define scoped (with-device-resources ([r (device-resources)]) r))
(list unscoped scoped)
]

@examples[#:eval ev
(with-device-resources ([r (device-resources)])
  (resources-sync! r)
  (resources-device r))
]

Released even when the body fails:

@examples[#:eval ev #:label #f
(define (run-batch items)
  (with-device-resources ([r (device-resources)])
    (for ([item (in-list items)])
      (when (negative? item)
        (error 'run-batch "bad item ~a" item)))
    (resources-sync! r)
    (length items)))
(run-batch '(1 2 3))
(eval:error (run-batch '(1 -2 3)))
]

Several bindings, released together:

@examples[#:eval ev #:label #f
(define-values (left right)
  (with-device-resources ([left (device-resources)]
                          [right (device-resources)])
    (values left right)))
(list left right)
(eval:error (resources-sync! left))
]}

@section[#:tag "ref-core-devices"]{Devices}

@defproc[(device-count) exact-positive-integer?]{

Returns the number of visible CUDA devices, numbered from 0. With no device or no working driver it
raises @racket[exn:fail:raft] of kind @racket['cuda].

@examples[#:eval ev
(device-count)
]

Spreading workers round robin:

@examples[#:eval ev #:label #f
(define (device-for-worker i)
  (modulo i (device-count)))
(map device-for-worker '(0 1 2 3))
]

Resources for every device:

@examples[#:eval ev #:label #f
(define per-device
  (for/list ([d (in-range (device-count))])
    (device-resources #:device d)))
(map resources-device per-device)
]}

@section[#:tag "ref-core-memory"]{The default memory resource}

RMM's current memory resource is per device and shared by every library in
the process. The first resources made on a device replace RMM's default
(@tt{cudaMalloc}, which synchronizes the device) with its CUDA async memory
resource, a stream-ordered @tt{cudaMallocAsync} pool. Any other resource,
installed before or after, is left alone; a plain
@tt{rmm::mr::cuda_memory_resource} set beforehand looks like the default and is
replaced. A device without memory-pool support keeps the default. Choosing a
resource from Racket arrives later @status{L2}.

@section[#:tag "ref-core-errors"]{Errors}

@defstruct*[(exn:fail:raft exn:fail)
            ([kind (or/c 'out-of-memory 'cuda 'logic 'generic)])]{

Raised for every failure in RAFT, RMM, CUDA or the native library. The
message starts with the Racket procedure that was called, then the cause. The
@racket[kind] says what failed:

@itemlist[
 @item{@racket['out-of-memory]: an allocation failed;}
 @item{@racket['cuda]: a CUDA call failed, for example because no driver is
       installed;}
 @item{@racket['logic]: the call was refused before reaching the GPU, for
       example a device that does not exist or resources already released;}
 @item{@racket['generic]: anything else.}]

@examples[#:eval ev
(define missing
  (with-handlers ([exn:fail:raft? values])
    (device-resources #:device (device-count))))
(exn-message missing)
(exn:fail:raft-kind missing)
]

Dispatching on the kind:

@examples[#:eval ev #:label #f
(define (describe-failure thunk)
  (with-handlers ([exn:fail:raft?
                   (lambda (e)
                     (case (exn:fail:raft-kind e)
                       [(out-of-memory) 'free-memory-and-retry]
                       [(logic) 'fix-the-call]
                       [else 'report]))])
    (thunk)
    'ok))
(describe-failure (lambda () (current-device-resources)))
(describe-failure (lambda () (device-resources #:device 99)))
]

Recovering the procedure name from the message:

@examples[#:eval ev #:label #f
(with-handlers ([exn:fail:raft?
                 (lambda (e)
                   (match-define (list who _ ...)
                     (string-split (exn-message e) ": "))
                   who)])
  (resources-sync! finished))
]}

@section[#:tag "ref-core-version"]{Version and ABI}

@defproc[(raft-version) string?]{

Returns the RAFT release the native library was built against, as year, month
and patch: @racket["26.08.00"] is August 2026.

@examples[#:eval ev
(raft-version)
]

Comparing releases numerically:

@examples[#:eval ev #:label #f
(match-define (list year month _)
  (map string->number (string-split (raft-version) ".")))
(list year month)
(>= (+ (* 100 year) month) 2608)
]

Refusing to start on another release:

@examples[#:eval ev #:label #f
(define (require-raft-release! wanted)
  (unless (string=? (raft-version) wanted)
    (error 'my-pipeline "built for RAFT ~a, but this is RAFT ~a"
           wanted (raft-version))))
(require-raft-release! "26.08.00")
(eval:error (require-raft-release! "26.10.00"))
]}

@defproc[(raft-abi) raft-abi?]{

Returns the ABI tag of the native library: what a second native library, such
as a cuML binding, must match to share RAFT handles and arrays with it. Such a
library records the tag it was built against and compares it at load time.

@examples[#:eval ev
(raft-abi)
]

In a @racket[match] pattern, @racket[raft-abi] takes the tag's fields by
keyword. Every keyword is optional and fields not named are ignored; an
unknown keyword is a syntax error.

@racketgrammar*[#:literals (raft-abi)
                [abi-pattern (raft-abi field-pattern ...)]
                [field-pattern (code:line #:version pat)
                               (code:line #:raft pat)
                               (code:line #:rmm pat)
                               (code:line #:cccl pat)
                               (code:line #:cuda-runtime pat)
                               (code:line #:resource-types pat)
                               (code:line #:handle-size pat)]]

@examples[#:eval ev #:label #f
(match-define (raft-abi #:raft raft #:cuda-runtime cuda-runtime) (raft-abi))
(list raft cuda-runtime)
]

A program tested on one release can say so on another:

@examples[#:eval ev #:label #f
(define (support-status abi)
  (match abi
    [(raft-abi #:raft "26.08.00") 'supported]
    [(raft-abi #:raft other) (list 'untested other)]))
(support-status (raft-abi))
(support-status (struct-copy raft-abi (raft-abi) [raft "26.10.00"]))
]

Checking a recorded tag: a match, a different RAFT release, and a handle
layout change a version check would miss:

@examples[#:eval ev #:label #f
(define (abi-mismatches built-against)
  (for/list ([field (in-list (list raft-abi-version raft-abi-raft raft-abi-rmm
                                   raft-abi-cccl raft-abi-handle-size))]
             [name (in-list '(version raft rmm cccl handle-size))]
             #:unless (equal? (field built-against) (field (raft-abi))))
    name))
(abi-mismatches (raft-abi))
(abi-mismatches (struct-copy raft-abi (raft-abi) [raft "26.10.00"]))
(abi-mismatches (struct-copy raft-abi (raft-abi) [handle-size 40]))
]

A one-line support report:

@examples[#:eval ev #:label #f
(match-let ([(raft-abi #:raft raft #:rmm rmm #:cccl cccl) (raft-abi)])
  (format "raft=~a rmm=~a cccl=~a" raft rmm cccl))
]}

@deftogether[(@defproc[(raft-abi? [v any/c]) boolean?]
              @defproc[(raft-abi-version [abi raft-abi?]) exact-nonnegative-integer?]
              @defproc[(raft-abi-raft [abi raft-abi?]) string?]
              @defproc[(raft-abi-rmm [abi raft-abi?]) string?]
              @defproc[(raft-abi-cccl [abi raft-abi?]) string?]
              @defproc[(raft-abi-cuda-runtime [abi raft-abi?]) string?]
              @defproc[(raft-abi-resource-types [abi raft-abi?]) exact-nonnegative-integer?]
              @defproc[(raft-abi-handle-size [abi raft-abi?]) exact-positive-integer?])]{

The predicate and the fields of an ABI tag, a transparent structure:
@racket[equal?] compares tags field by field, and
@racket[(struct-copy raft-abi abi [field value] ...)] makes a changed copy.

@tabular[#:sep @hspace[2]
         #:style 'boxed
         #:row-properties '(bottom-border ())
 (list (list @bold{Field} @bold{Value})
       (list @racket[version]
             @elem{the version of the tag itself; it changes whenever a change
                   to the native interface would break a library built against
                   the previous one})
       (list @racket[raft] @elem{the RAFT release, as @racket[raft-version] returns it})
       (list @racket[rmm] "the RMM release, in the same form")
       (list @racket[cccl] @elem{the CCCL release, for example @racket["3.4.3"]})
       (list @racket[cuda-runtime]
             "the CUDA runtime the native library was compiled with, major.minor")
       (list @racket[resource-types]
             "the number of resource kinds a RAFT handle can hold")
       (list @racket[handle-size] @elem{@tt{sizeof(raft::handle_t)}, in bytes}))]

@examples[#:eval ev
(define abi (raft-abi))
(raft-abi? abi)
(raft-abi-version abi)
(raft-abi-cuda-runtime abi)
(equal? abi (raft-abi))
(equal? abi (struct-copy raft-abi abi [rmm "26.10.00"]))
]}
