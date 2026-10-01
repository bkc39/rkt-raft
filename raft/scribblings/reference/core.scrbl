#lang scribble/manual
@(require "../utils.rkt")

@(define ev (make-raft-eval))

@title[#:tag "ref-core"]{Resources, devices and errors: @racketmodname[raft/core]}

@defmodule[raft/core]

The core module holds what every other module builds on: the
@tech{resources} object an operation runs with, the devices it can run on, the
one exception type, and the version and ABI tag of the native library.
@racketmodname[raft] re-exports all of it. The guide chapter
@secref["resources"] shows these names working together.

@section[#:tag "ref-core-resources"]{Device resources}

@defproc[(device-resources [#:device device exact-nonnegative-integer? 0])
         device-resources?]{

Creates new @tech{resources} on @racket[device]: a C++ @tt{raft::handle_t}
with a CUDA @tech{stream} of its own, which every operation given these
resources is queued on. The library handles it holds (cuBLAS, cuSOLVER,
cuSPARSE) are created the first time an operation needs them. This is
@tt{pylibraft.common.DeviceResources()}, except that the stream belongs to the
resources object instead of being CUDA's per-thread default stream.

Most code never calls this: @racket[current-device-resources] keeps one per
thread and device. Make your own when a piece of work needs a stream that
nothing else queues on, and scope it with @racket[with-device-resources] when
it should be released at a known point. Otherwise the garbage collector
releases it once it is unreachable.

The first resources made on a device, in the whole process, also install RMM's
CUDA async memory resource (a @tt{cudaMallocAsync} pool) as that device's
current memory resource, unless RMM's default has already been replaced; see
@secref["ref-core-memory"].

A @racket[device] the driver does not report raises @racket[exn:fail:raft]
with kind @racket['logic].

@examples[#:eval ev
(define r (device-resources))
r
(resources-device r)
]

Two calls make two independent resources, each with its own stream, so work
queued on one need not wait for the other:

@examples[#:eval ev #:label #f
(define loader (device-resources))
(define trainer (device-resources))
(eq? loader trainer)
(map resources-device (list loader trainer))
]

Devices are numbered from 0, so @racket[(device-count)] is the first
number that is not a device:

@examples[#:eval ev #:label #f
(device-count)
(eval:error (device-resources #:device (device-count)))
]}

@defproc[(device-resources? [v any/c]) boolean?]{

Returns @racket[#t] if @racket[v] is a resources object, whether made by
@racket[device-resources] or handed out by @racket[current-device-resources],
and @racket[#f] otherwise. Released resources are still resources objects.

@examples[#:eval ev
(device-resources? (current-device-resources))
(device-resources? 0)
]

A procedure can take either a device number or resources, the way CuPy takes
a device or its number, and turn either into resources:

@examples[#:eval ev #:label #f
(define (as-resources where)
  (if (device-resources? where)
      where
      (current-device-resources where)))
(eq? (as-resources 0) (current-device-resources))
(eq? (as-resources loader) loader)
]

Released resources are still resources objects; using them is what fails:

@examples[#:eval ev #:label #f
(define finished (with-device-resources ([r (device-resources)]) r))
(device-resources? finished)
]}

@defproc[(resources-device [resources device-resources?])
         exact-nonnegative-integer?]{

Returns the device @racket[resources] belong to. Every operation on them runs
on that device, whichever OS thread happens to make the call. The answer stays
available after the resources have been released.

@examples[#:eval ev
(resources-device (current-device-resources))
]

Naming the device in a log line, as CUDA tools do:

@examples[#:eval ev #:label #f
(printf "training on cuda:~a\n" (resources-device trainer))
]

An operation that combines arrays needs them on one device, so code that
mixes resources checks before it queues anything:

@examples[#:eval ev #:label #f
(define (same-device? a b)
  (= (resources-device a) (resources-device b)))
(same-device? loader trainer)
(resources-device finished)
]}

@defproc[(resources-sync! [resources device-resources?]) void?]{

Waits until every operation queued on @racket[resources]' stream has finished,
then returns. It is @tt{DeviceResources.sync()}.

Operations return as soon as they are queued, so call this before stopping a
clock, before handing results to code outside the library, or before releasing
memory another stream is still reading. Converting an array back to Racket
data @status{L1b} will synchronize by itself.

The wait is a poll, not a blocking call: the stream is queried, and between
queries the thread sleeps for a few microseconds to a millisecond, so other
Racket threads keep running, the garbage collector never waits on the GPU,
and a break (@exec{Ctrl-C}, or @racket[break-thread]) ends the wait with
@racket[exn:break]. Using released resources raises @racket[exn:fail:raft]
naming @racket[resources-sync!].

@examples[#:eval ev
(resources-sync! (current-device-resources))
]

Timing GPU work means syncing before reading the clock; otherwise the time
measured is only the time it took to queue the work:

@examples[#:eval ev #:label #f
(define (milliseconds-on r thunk)
  (define start (current-inexact-milliseconds))
  (thunk)
  (resources-sync! r)
  (- (current-inexact-milliseconds) start))
(milliseconds-on trainer void)
]

The wait can happen in a thread of its own, joined when the result is needed:

@examples[#:eval ev #:label #f
(thread-wait
 (thread (lambda ()
           (resources-sync! trainer)
           (displayln "the trainer's stream has drained"))))
]

Released resources cannot be synced:

@examples[#:eval ev #:label #f
(eval:error (resources-sync! finished))
]}

@defproc[(current-device-resources [device exact-nonnegative-integer? 0])
         device-resources?]{

Returns the calling thread's default resources for @racket[device], creating
them on first use. The operations on arrays @status{L1b} will use this when
they are given no @racket[#:resources], the way pylibraft's functions take
@tt{handle=}.

The default is kept per Racket thread, in a thread cell rather than a
parameter, so a new thread starts without one and makes its own on first use:
two threads never share a stream by accident. pylibraft instead creates a
fresh @tt{DeviceResources} for each call made without a handle. If the
default has been released, for example by @racket[with-device-resources], the
next call makes a new one.

@examples[#:eval ev
(eq? (current-device-resources) (current-device-resources))
(eq? (current-device-resources) (current-device-resources 0))
]

Each worker thread gets its own resources, and so its own stream:

@examples[#:eval ev #:label #f
(define (worker-resources)
  (define answer (make-channel))
  (thread (lambda () (channel-put answer (current-device-resources))))
  (channel-get answer))
(define a (worker-resources))
(define b (worker-resources))
(list (eq? a b) (eq? a (current-device-resources)))
]

Releasing the default is allowed; the thread simply gets a new one:

@examples[#:eval ev #:label #f
(define before (current-device-resources))
(with-device-resources ([r before])
  (resources-sync! r))
before
(eq? before (current-device-resources))
]}

@defform[(with-device-resources ([id resources-expr] ...) body ...+)
         #:contracts ([resources-expr device-resources?])]{

Binds each @racket[id] to the value of its @racket[resources-expr], evaluates
the @racket[body]s, and releases every bound resources object when control
leaves the form, whether the body returns, raises or escapes. Releasing is
idempotent, and the finalizer stays as a backstop for anything not released
here. The @racket[resources-expr]s are evaluated in order, as by
@racket[let*]: each one sees the @racket[id]s bound before it, but not its
own, so @racket[(with-device-resources ([r r]) ....)] scopes an existing
@racket[r].

Release drops this object's hold on its @tt{raft::handle_t}. An array
allocated with these resources @status{L1b} holds the handle too, stream and
library handles included, so they are freed when the last such array is.

@examples[#:eval ev
(with-device-resources ([r (device-resources)])
  (resources-sync! r)
  (resources-device r))
]

A batch job gets resources of its own, released as soon as the batch is done,
even if it fails part way:

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

Several bindings are released together, and the bound objects are unusable
afterwards:

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

Returns the number of CUDA devices the driver makes visible to this process,
after @tt{CUDA_VISIBLE_DEVICES}. Devices are numbered from 0. It is CuPy's
@tt{cp.cuda.runtime.getDeviceCount()}, and like it, it never answers 0: with
no device, or no working driver, it raises @racket[exn:fail:raft] with kind
@racket['cuda].

@examples[#:eval ev
(device-count)
]

Spreading workers over every GPU, round robin:

@examples[#:eval ev #:label #f
(define (device-for-worker i)
  (modulo i (device-count)))
(map device-for-worker '(0 1 2 3))
]

Resources for every device, made once at start-up, for those workers to
use:

@examples[#:eval ev #:label #f
(define per-device
  (for/list ([d (in-range (device-count))])
    (device-resources #:device d)))
(map resources-device per-device)
]}

@section[#:tag "ref-core-memory"]{The default memory resource}

Device memory comes from RMM, which keeps one current memory resource per
device for the whole process, shared by every library that links it: this
one, cuML, and anything else built on RAPIDS. RMM's own default allocates with
@tt{cudaMalloc} and frees with @tt{cudaFree}, both of which synchronize the
device.

The first time this library makes resources on a device, it replaces that
default with RMM's CUDA async memory resource,
@tt{rmm::mr::cuda_async_memory_resource}: a @tt{cudaMallocAsync} pool, whose
allocations and frees are ordered on a stream and need not wait for the rest
of the device, and
which can be trimmed after an out-of-memory error. It is what
@tt{rmm.mr.set_current_device_resource(rmm.mr.CudaAsyncMemoryResource())}
does in Python. A resource that something else installed before that point is
left alone, as is any change made after it. The exception is a plain
@tt{cuda_memory_resource} set on purpose beforehand: it cannot be told from
RMM's default, so it is replaced. A device whose driver reports no support
for memory pools (@tt{cudaDevAttrMemoryPoolsSupported}) keeps RMM's default
too, and its resources are made as usual. Choosing a resource from Racket
arrives with the rest of the core module @status{L2}.

@section[#:tag "ref-core-errors"]{Errors}

@defstruct*[(exn:fail:raft exn:fail)
            ([kind (or/c 'out-of-memory 'cuda 'logic 'generic)])]{

The one exception type the library raises for a failure inside RAFT, RMM,
CUDA or the native library. The message starts with the name of the Racket
procedure that was called, followed by the cause in RAFT's, RMM's or the
native library's words. The @racket[kind] says what failed:

@itemlist[
 @item{@racket['out-of-memory]: an allocation failed;}
 @item{@racket['cuda]: a CUDA call failed, for example because no driver is
       installed;}
 @item{@racket['logic]: the call was refused before reaching the GPU, for
       example a device that does not exist or resources already released;}
 @item{@racket['generic]: anything else.}]

An argument of the wrong kind, such as a string where a device number goes or
a number where resources go, raises this type too, with kind @racket['logic]
and the name of the procedure that was called.

@examples[#:eval ev
(define missing
  (with-handlers ([exn:fail:raft? values])
    (device-resources #:device (device-count))))
(exn-message missing)
(exn:fail:raft-kind missing)
(eval:error (resources-device 5))
]

Dispatching on the kind, to retry only what a retry can fix:

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

The message names the procedure the caller used, so a log line says where it
came from:

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

Returns the RAFT release that @tt{libraftrkt} was compiled against, spelled as
RAFT spells it: two digits each for the year, the month and the patch, so
@racket["26.08.00"] is the August 2026 release. It is the same string
@tt{pylibraft.__version__} gives for the same release.

@examples[#:eval ev
(raft-version)
]

Split it to compare releases numerically:

@examples[#:eval ev #:label #f
(match-define (list year month _)
  (map string->number (string-split (raft-version) ".")))
(list year month)
(>= (+ (* 100 year) month) 2608)
]

A program that depends on one release can refuse to start on another:

@examples[#:eval ev #:label #f
(define (require-raft-release! wanted)
  (unless (string=? (raft-version) wanted)
    (error 'my-pipeline "built for RAFT ~a, but this is RAFT ~a"
           wanted (raft-version))))
(require-raft-release! "26.08.00")
(eval:error (require-raft-release! "26.10.00"))
]}

@defproc[(raft-abi) hash?]{

Returns the ABI tag of @tt{libraftrkt}: an immutable hash, keyed by symbols, of
the facts a second native library has to share with it to exchange RAFT
handles and arrays safely. RAFT has no versioned C++ namespace and the layout
of its handle changes between releases, so a native library that receives a
@tt{raft::handle_t} from this one (a cuML binding, for example) must have been
compiled against identical RAFT, RMM and CCCL headers. Such a library records
the tag it was built against and compares it with this one when it loads.

@tabular[#:sep @hspace[2]
         #:style 'boxed
         #:row-properties '(bottom-border ())
 (list (list @bold{Key} @bold{Value})
       (list @racket['abi-version]
             @elem{the version of the tag itself, an exact integer; it changes
                   whenever a change to the native interface would break a
                   library built against the previous one})
       (list @racket['raft] @elem{the RAFT release, as @racket[raft-version] returns it})
       (list @racket['rmm] "the RMM release, in the same form")
       (list @racket['cccl] @elem{the CCCL release, for example @racket["3.4.3"]})
       (list @racket['cuda-runtime]
             "the CUDA runtime the native library was compiled with, major.minor")
       (list @racket['handle-size] @elem{@tt{sizeof(raft::handle_t)}, in bytes})
       (list @racket['resource-types]
             "the number of resource kinds a RAFT handle can hold"))]

@examples[#:eval ev
(raft-abi)
]

A downstream library checks the tag before it loads its own native code. Here
the expected tag is the current one, then the tag of a library built against
RAFT 26.10, then one built against headers whose @tt{raft::handle_t} has a
different layout, which a version check alone would miss:

@examples[#:eval ev #:label #f
(define (abi-mismatches built-against)
  (for/list ([(key value) (in-hash built-against)]
             #:unless (equal? value (hash-ref (raft-abi) key #f)))
    key))
(abi-mismatches (raft-abi))
(abi-mismatches (hash-set (raft-abi) 'raft "26.10.00"))
(abi-mismatches (hash-update (raft-abi) 'handle-size add1))
]

The tag also makes a one-line support report:

@examples[#:eval ev #:label #f
(string-join (for/list ([key (in-list '(raft rmm cccl cuda-runtime))])
               (~a key "=" (hash-ref (raft-abi) key)))
             " ")
]}
