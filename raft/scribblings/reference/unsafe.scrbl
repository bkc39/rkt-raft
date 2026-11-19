#lang scribble/manual
@(require "../utils.rkt")

@(define ev (make-downstream-eval "reference-unsafe"))

@title[#:tag "ref-unsafe"]{Downstream interface: @racketmodname[raft/unsafe]}

@defmodule[raft/unsafe]

This module is for native bindings that run their own C++ on raft's resources
and arrays, such as a cuML binding. It provides the @tt{raft::handle_t} to
run on, a descriptor for each array, a checker that turns a native status
into @racket[exn:fail:raft], a form that runs a long native call on a worker
thread, the ABI tag, and the releases of scoped native objects. @racketmodname[raft] does not
re-export it.

It is unsafe as @racketmodname[ffi/unsafe] is: nothing checks that a
binding's foreign declarations match its C code, so passing a view where the
C function expects a handle crashes the process. The C headers check views,
not pointer types.

The k-means canary in @tt{downstream/kmeans-canary} is built on this module.
The interface is frozen at ABI version 1 (@secref["ref-unsafe-c"]).

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
(define-kc kc-cluster-members
  (_fun _pointer _pointer _pointer _int32 _pointer -> _int))
(define-kc kc-cluster-graph
  (_fun _pointer _pointer _int32 _int32 _pointer -> _int))
(define-job kc-make-blobs-job canary "kc_make_blobs_job"
  (handle view view _int32 _double _int32 _double _double _uint64))
(define-job kc-fit-job canary "kc_fit_job"
  (handle view view view _int32 _int32 _double _int32 _double _uint64 (out _double) (out _int32)))
(define-job kc-predict-job canary "kc_predict_job" (handle view view view _int32 view (out _double)))
(define-cstruct _rr-view
  ([data _pointer] [dtype _int32] [memory _int32] [device _int32] [rank _int32]
   [shape (_array _int64 8)] [strides (_array _int64 8)]))
(define-cstruct _rr-deposit
  ([handle _pointer] [device _int32] [state _int32] [owner _pointer] [release _pointer]
   [count _int32] [reserved _int32] [regions (_array _rr-view 8)]))
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
@racket[#\uFFFD] for what does not decode and cut to its first non-blank line
as for @racket[exn:fail:raft], which also says when the whole text is logged;
the kind is @racket['generic],
@racket['out-of-memory], @racket['cuda] or @racket['logic] for
@racket[(last-error-kind)] 0 to 3, and @racket['generic] for any other code.
@racket[last-error] and @racket[last-error-kind] are called only after a
failure.

The call and both reads run in one @racket[call-as-atomic], because the C
side keeps its last error per OS thread, which the place's Racket threads
share. The native call therefore holds up the place's other threads until it
returns: a call that can run long is a @tech{job} instead (@racket[define-job]).

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

@section[#:tag "ref-unsafe-jobs"]{Long calls}

A native call that can run long, such as a fit, runs as a @deftech{job}: on a
worker thread its resources object owns, while the calling thread waits and
the place's other threads run. Jobs on one resources object run one at a
time, in the order they were made, as work on one stream does; jobs on
different resources objects run at the same time. Each thread's
@racket[current-device-resources] are its own, and so are their workers.

A job has two parts. On the C++ side, the entry point is written as usual
(@secref["ref-unsafe-c"]), plus a one-line job entry that
@tt{raftrkt::run_job} fills in:

@listing["C++"]|{
extern "C" KC_API void kc_fit_job(void* args, size_t args_len, rr_job_outcome* outcome) {
  raftrkt::run_job<&kc_fit>(args, args_len, outcome, kc::last_error_slot());
}
}|

On the Racket side, @racket[define-job] declares the entry point's parameters in order.

@defform[(define-job id library-expr c-id-expr (param ...) maybe-exn)
         #:grammar ([param handle view deposit (code:line (out out-type)) in-type]
                    [in-type _int8 _uint8 _int16 _uint16 _int32 _uint32 _int64 _uint64
                             _float _double _double*]
                    [out-type _int8 _uint8 _int16 _uint16 _int32 _uint32 _int64 _uint64
                              _float _double]
                    [maybe-exn code:blank (code:line #:exn exn-expr)])
         #:contracts ([library-expr ffi-lib?]
                      [c-id-expr (or/c string? bytes? symbol?)]
                      [exn-expr (-> string? continuation-mark-set? symbol? exn?)])]{

Defines @racket[id] as a procedure @racket[(id who resources arg ...)] that
runs the job entry @racket[c-id-expr] of @racket[library-expr] on the worker
of @racket[resources] and returns the entry point's outputs, in order, as
values. Each @racket[param] is one parameter of the C entry point:
@racket[handle] its @tt{void*} handle, taken from @racket[resources];
@racket[view] a @tt{const rr_view*}; @racket[deposit] an @tt{rr_deposit*},
for which the @racket[arg] is a deposit, bound once as by
@racket[with-deposits] and closed when the job returns; @racket[(out type)]
a pointer to an output; an @racket[in-type] a number. An @racket[arg] is
given for each @racket[view] (a device array, or @racket[#f] for @tt{NULL}),
each @racket[deposit] and each @racket[in-type] (converted as by the type),
in order. The three expressions
are evaluated once, when @racket[id] is defined; a missing entry raises then.
Two @racket[handle]s are a syntax error.

A failure of the entry point raises @racket[(exn message marks kind)] as
@racket[status-checker] does, with @racket[who] and the job's own message and
kind; @racket[exn] is @racket[exn:fail:raft] unless @racket[#:exn] says
otherwise. Released resources or arrays raise @racket[exn:fail:raft] of kind
@racket['logic] before the job is made, as does a call in atomic mode,
where the calling thread cannot wait. A @racket[view] argument that is
neither a device array nor @racket[#f], or a @racket[deposit] argument that is
not a deposit, raises @racket[exn:fail:raft] of kind @racket['logic] naming
@racket[who], also before the job is made. A number
its type refuses raises @racket[exn:fail:contract] naming @racket[who].

The job holds what it uses, the handle, each array's memory and each
deposit, until it returns, even if the calling thread is killed or the
arrays, deposits and resources become unreachable. A deposit that cannot be
bound raises @racket[exn:fail:raft] of kind @racket['logic] before the job
runs. A job that cannot be submitted raises @racket[exn:fail:raft], of kind
@racket['generic] when the system refuses a file descriptor or a thread, and
@racket['out-of-memory] when memory runs out. Either closes the deposits bound before it. Each view is bound once the work queued on its array's
stream is done. The calling thread waits with breaks disabled: a break that
arrives meanwhile is raised when the job returns, and its outputs are
dropped. When the process exits, a running job is waited for as
@racket[current-exit-wait] says.

The declaration must match the C entry point. @tt{run_job} refuses an
argument block whose size differs from what the entry point's parameters
take (@racket['logic]), but it cannot tell apart types of the same size.

@examples[#:eval ev
(define-values (inertia n-iter)
  (kc-fit-job 'kmeans-fit (current-device-resources) X #f fitted 0 300 1e-4 1 0.0 42))
(list (> inertia 0) (>= n-iter 1))
]

A failure raises with the job's own message:

@examples[#:eval ev #:label #f
(eval:error
 (kc-fit-job 'kmeans-fit (current-device-resources) ints #f centers 0 300 1e-4 1 0.0 42))
]

A view that is not an array raises before the job is made:

@examples[#:eval ev #:label #f
(eval:error
 (kc-fit-job 'kmeans-fit (current-device-resources) 'not-an-array #f centers 0 300 1e-4 1 0.0 42))
]

Other threads run while a job does:

@examples[#:eval ev #:label #f
(define big (device-matrix 1000000 32))
(kc-make-blobs-job 'blobs (current-device-resources) big (device-vector 1000000 #:dtype 'int32)
                   64 1.0 1 -10.0 10.0 1)
(define (ticks-during thunk)
  (define ticks (box 0))
  (define ticker
    (thread (lambda ()
              (let loop ()
                (sleep 0.005)
                (set-box! ticks (add1 (unbox ticks)))
                (loop)))))
  (thunk)
  (kill-thread ticker)
  (unbox ticks))
(<= 10 (ticks-during
        (lambda ()
          (kc-fit-job 'kmeans-fit (current-device-resources) big #f (device-matrix 64 32)
                      1 100 1e-12 1 0.0 1))))
]

A declaration of the wrong size is refused:

@examples[#:eval ev #:label #f
(define-job kc-fit-job/short canary "kc_fit_job" (handle view view view _int32))
(eval:error (kc-fit-job/short 'kmeans-fit (current-device-resources) X #f fitted 0))
]

A deposit parameter takes outputs sized by the call (@racket[deposit]):

@examples[#:eval ev #:label #f
(define labels (device-vector 300 #:dtype 'int32))
(kc-predict-job 'kmeans-predict (current-device-resources) fitted X #f 1 labels)
(define-job kc-cluster-members-job canary "kc_cluster_members_job" (handle view view _int32 deposit))
(define found (deposit))
(kc-cluster-members-job 'cluster-members (current-device-resources) X labels 0 found)
(deposit->list found)
(eval:error (kc-cluster-members-job 'cluster-members (current-device-resources) X labels 0 found))
(eval:error (kc-cluster-members-job 'cluster-members (current-device-resources) X labels 0 'not-a-deposit))
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
them with @racket[with-device-resources] around the form. A @tech{job} binds
its own views; this form serves short calls through @racket[status-checker].

Every exit (a return, a raise, an escape, a generator's @racket[yield])
clears each view: its @tt{data} becomes @tt{NULL} and its device and memory
@racket[-1], so the C side refuses a view kept past the form. The handle
pointer is not cleared, so it must not escape the body. Control that jumps
back into the body raises @racket[exn:fail:raft] of kind @racket['logic].

A @racket[device-array-release!] of a bound array takes effect at once for
Racket, where every later use raises, but frees the memory only when the last
binding that holds the array exits, so the views stay valid until then.

Before binding a view, the form waits, by polling, for the work queued on
the array's stream. It does not wait after the body: a native call that
returns with work still queued must run on the arrays' own resources or
synchronise before it returns.

@examples[#:eval ev
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
]

An array released inside the form is still read through its view:

@examples[#:eval ev #:label #f
(define copied (contiguous F #:layout 'row-major))
(with-array-views ([c fitted] [x copied] [y labels])
  (device-array-release! copied)
  (check 'kmeans-predict (lambda () (kc-predict handle c x #f 1 y))))
copied
]}

@section[#:tag "ref-unsafe-dtypes"]{Element type codes}

@defproc[(dtype->code [dtype (or/c 'float32 'float64 'int32 'int64)]) exact-nonnegative-integer?]{

Returns @racket[dtype]'s @tt{RR_DTYPE_*} code (@secref["ref-unsafe-c"]), as
a view records it and a native call takes it. Another symbol raises
@racket[hash-ref]'s @racket[exn:fail:contract].}

@examples[#:eval ev
(define wide (deposit))
(with-deposits ([out wide])
  (with-array-views #:resources [handle (current-device-resources)] ([y labels])
    (check 'cluster-graph
           (lambda () (kc-cluster-graph handle y 3 (dtype->code 'int64) out)))))
(dtype (first (deposit->list wide)))
]

Each element type, and one raft does not have:

@examples[#:eval ev #:label #f
(map dtype->code '(float32 float64 int32 int64))
(eval:error (dtype->code 'float16))
]

@defproc[(code->dtype [code exact-nonnegative-integer?]) (or/c 'float32 'float64 'int32 'int64)]{

The inverse of @racket[dtype->code]. Another code raises
@racket[hash-ref]'s @racket[exn:fail:contract].}

@examples[#:eval ev
(define narrow (deposit))
(with-deposits ([out narrow])
  (with-array-views #:resources [handle (current-device-resources)] ([y labels])
    (check 'cluster-graph
           (lambda () (kc-cluster-graph handle y 3 (dtype->code 'int32) out))))
  (code->dtype (rr-view-dtype (array-ref (rr-deposit-regions (ptr-ref out _rr-deposit)) 0))))
]

Each code, and one raft does not have:

@examples[#:eval ev #:label #f
(map code->dtype '(0 1 2 3))
(eval:error (code->dtype 4))
]

@section[#:tag "ref-unsafe-deposits"]{Outputs sized by the call}

Some native calls allocate outputs whose size only the call knows, such as
HDBSCAN's condensed tree. A deposit is a record the call fills with that
memory and with the owner that frees it; raft then turns each region into an
array.

@defproc[(deposit [#:resources resources device-resources? (current-device-resources)]
                  [#:who who symbol? 'deposit])
         deposit?]{

Returns an empty deposit on @racket[resources]: a record into which a native
call puts device memory it allocated, with the owner that frees it. Its
arrays come from @racket[deposit->list]. @racket[who] begins the message of
any @racket[exn:fail:raft] it raises.}

@defproc[(deposit? [v any/c]) boolean?]{

Recognises deposits.}

@defform[(with-deposits ([id deposit-expr] ...) body ...+)
         #:contracts ([deposit-expr deposit?])]{

Binds each @racket[id] to a pointer to the deposit's @tt{rr_deposit}
(@secref["ref-unsafe-c"]) for the extent of the @racket[body]s. Every exit
closes the deposit: a native call can no longer fill it, and a deposit left
empty holds no arrays. A deposit is bound once: binding it again, even while
a @tech{job} is still filling it, raises @racket[exn:fail:raft] of
kind @racket['logic]: ``the deposit is already bound'', ``already filled''
or ``closed'', whichever it is. Make the deposit on the
resources the call runs on. Two identical @racket[id]s are a syntax error.}

@defproc[(deposit->list [d deposit?]) (listof (or/c device-vector? device-matrix?))]{

Returns the arrays of @racket[d]'s regions, in order, with the shapes,
layouts and dtypes the native call recorded: the same arrays on every call.
Each holds the native owner: it is freed, exactly once, when the deposit and
all its arrays are gone, on the deposit's stream, and it outlives the
resources object it was made from. While @racket[d] is open, while it is
being filled, and while a @tech{job} that filled it still runs, raises
@racket[exn:fail:raft] of kind @racket['logic]: ``the deposit is still
open''.}

@examples[#:eval ev
(define members (deposit))
(with-deposits ([out members])
  (with-array-views #:resources [handle (current-device-resources)] ([x X] [y labels])
    (check 'cluster-members (lambda () (kc-cluster-members handle x y 0 out)))))
(match-define (list indices rows) (deposit->list members))
(list (dtype indices) (dtype rows) (= (car (shape rows)) (car (shape indices))))
(eq? indices (first (deposit->list members)))
]

A deposit can be converted once it is filled, it is filled only once, and it
belongs to the resources it was made on:

@examples[#:eval ev #:label #f
(define pending (deposit))
(eval:error (with-deposits ([out pending]) (deposit->list pending)))
(deposit->list pending)
(eval:error (with-deposits ([out members]) out))
(define elsewhere (deposit #:resources other))
(eval:error
 (with-deposits ([out elsewhere])
   (with-array-views #:resources [handle (current-device-resources)] ([x X] [y labels])
     (check 'cluster-members (lambda () (kc-cluster-members handle x y 0 out))))))
]

@defproc[(deposit->device-csr-matrix [d deposit?]
                                     [#:shape shape (list/c exact-nonnegative-integer?
                                                            exact-nonnegative-integer?)])
         device-csr-matrix?]{

Returns a @tech{CSR matrix} over @racket[d]'s three regions, indptr, indices
and data, which @tt{raftrkt::deposit_csr} writes in that order, after the
checks of @racket[device-csr-matrix]. Its vectors are those of
@racket[(deposit->list d)]. A deposit of another number of regions raises
@racket[exn:fail:raft] of kind @racket['logic].

@examples[#:eval ev
(define graph (deposit))
(with-deposits ([out graph])
  (with-array-views #:resources [handle (current-device-resources)] ([y labels])
    (check 'cluster-graph (lambda () (kc-cluster-graph handle y 3 2 out)))))
(define clusters (deposit->device-csr-matrix graph #:shape (cons 3 (shape labels))))
(list (shape clusters) (nnz clusters) (dtype (csr-indptr clusters)))
(eq? (csr-indptr clusters) (first (deposit->list graph)))
]

Each cluster's size, from its row:

@examples[#:eval ev #:label #f
(define p (device-vector->list (csr-indptr clusters)))
(map - (cdr p) (drop-right p 1))
]

Another shape, or a deposit of other regions, is refused:

@examples[#:eval ev #:label #f
(eval:error (deposit->device-csr-matrix graph #:shape (cons 4 (shape labels))))
(eval:error (deposit->device-csr-matrix members #:shape '(3 3)))
]}

@section[#:tag "ref-unsafe-release"]{Releasing}

A binding that holds native objects of its own, or that is done with a
deposit or an array before the collector would notice, releases them at a
known point.

@defform[(with-release option ... ([id acquire-expr release-expr] ...) body ...+)
         #:grammar ([option (code:line #:who who-expr)
                            (code:line #:exn exn-expr)])
         #:contracts ([release-expr (-> any/c any)]
                      [who-expr (or/c symbol? #f)]
                      [exn-expr (-> string? continuation-mark-set? symbol? exn?)])]{

Binds each @racket[id] in order and runs the @racket[body]s. Every exit
releases each @racket[id] once, innermost first, by calling its
@racket[release-expr]'s value on it as a @racket[dynamic-wind] post thunk,
so with breaks disabled. An @racket[id] bound to @racket[#f] is not
released. Jumping back in raises @racket[exn-expr]'s exception (default
@racket[exn:fail:raft]) of kind @racket['logic], its message prefixed by
@racket[who-expr]; each option is given at most once and evaluated once per
binding, after its @racket[acquire-expr]. A thread killed in the
@racket[body]s releases nothing; the finalizer is the backstop.}

@examples[#:eval ev
(define scoped (with-release ([d (deposit) deposit-release!]) d))
scoped
(define cluster-1
  (with-release ([d (deposit) deposit-release!])
    (kc-cluster-members-job 'cluster-members (current-device-resources) X labels 1 d)
    (deposit->list d)))
(map dtype cluster-1)
]

A generator that resumes the body is refused, under the binding's own name
and exception:

@examples[#:eval ev #:label #f
(require racket/generator)
(define members-of
  (generator ()
    (with-release #:who 'with-members #:exn exn:fail:canary ([d (deposit) deposit-release!])
      (yield d)
      (yield d))))
(members-of)
(with-handlers ([exn:fail:canary? (lambda (e) (list 'canary (exn-message e)))])
  (members-of))
]

@defproc[(call-with-release [acquired any/c]
                            [release (-> any/c any)]
                            [proc (-> any/c any)]
                            [#:who who (or/c symbol? #f) #f]
                            [#:exn exn (-> string? continuation-mark-set? symbol? exn?)
                                   exn:fail:raft])
         any]{

Calls @racket[(proc acquired)] and returns its results, releasing
@racket[acquired] on every exit as @racket[with-release] does for one
binding; @racket[with-release] expands into it.}

@examples[#:eval ev
(call-with-release (device-vector 300 #:dtype 'int32)
                   device-array-release!
                   (lambda (scratch)
                     (with-array-views #:resources [handle (current-device-resources)]
                                       ([c fitted] [x X] [y scratch])
                       (check 'kmeans-predict (lambda () (kc-predict handle c x #f 1 y))))))
(define cluster-2
  (call-with-release (deposit)
                     deposit-release!
                     (lambda (d)
                       (kc-cluster-members-job 'cluster-members (current-device-resources)
                                               X labels 2 d)
                       (deposit->list d))))
(map dtype cluster-2)
(define resumed
  (generator ()
    (call-with-release (deposit) deposit-release! (lambda (d) (yield d) (yield d))
                       #:who 'with-members)))
(resumed)
(eval:error (resumed))
]

@defproc[(deposit-release! [d deposit?]) void?]{

Releases @racket[d] now. The arrays already adopted from it stay valid; its
owner is released once they are all released or collected too. A second
release does nothing. While @racket[with-deposits] binds @racket[d], the
release waits for the form's exit, and a @tech{job} that holds @racket[d]
keeps it until it returns. A later use of @racket[d] raises
@racket[exn:fail:raft] of kind @racket['logic]: ``deposit: used after its
release''.}

@examples[#:eval ev
(define kept (deposit))
(kc-cluster-members-job 'cluster-members (current-device-resources) X labels 0 kept)
(match-define (list kept-indices kept-rows) (deposit->list kept))
(deposit-release! kept)
kept
(= (length (device-vector->list kept-indices)) (car (shape kept-rows)))
]

A released deposit cannot be converted or filled again:

@examples[#:eval ev #:label #f
(eval:error (deposit->list kept))
(eval:error (kc-cluster-members-job 'cluster-members (current-device-resources) X labels 0 kept))
]

Released inside its own @racket[with-deposits], the deposit is still filled,
and released when the form exits:

@examples[#:eval ev #:label #f
(define inside (deposit))
(with-deposits ([out inside])
  (deposit-release! inside)
  (with-array-views #:resources [handle (current-device-resources)] ([x X] [y labels])
    (check 'cluster-members (lambda () (kc-cluster-members handle x y 1 out)))))
inside
]

@defproc[(device-array-release! [a device-array?]) void?]{

Releases @racket[a]'s memory now instead of at collection. An array adopted
from a deposit releases its share of the deposit's owner, which goes once
the deposit and its other arrays are gone too; its phantom bytes drop to 0
at once, though the owner's memory lives until then. Releasing a part of a
@racket[deposit->device-csr-matrix] result, which is one of the deposit's
cached arrays, releases that part of the matrix. A @tech{job} that holds
@racket[a] keeps its memory until it returns, and a @racket[with-array-views]
binding of @racket[a] until it exits; nothing else does, so a native object
that keeps a pointer into @racket[a] past its call does not. A second
release does nothing; a later use raises @racket[exn:fail:raft] of kind
@racket['logic]: ``device-array: used after its release''.}

@examples[#:eval ev
(define early (list->device-vector '(1 2 3)))
(device-array-release! early)
early
(eval:error (device-vector->list early))
]

The arrays of a released deposit, released one by one:

@examples[#:eval ev #:label #f
(define done (deposit))
(kc-cluster-members-job 'cluster-members (current-device-resources) X labels 2 done)
(match-define (list done-indices done-rows) (deposit->list done))
(deposit-release! done)
(device-array-release! done-indices)
(device-array-release! done-rows)
done-rows
]

Released inside a binding, an array is refused at once but read through the
binding's view until the binding exits:

@examples[#:eval ev #:label #f
(define held-labels (device-vector 300 #:dtype 'int32))
(with-array-views #:resources [handle (current-device-resources)]
                  ([c fitted] [x X] [y held-labels])
  (device-array-release! held-labels)
  (list (exn-message (with-handlers ([exn:fail:raft? values]) (device-vector->list held-labels)))
        (check 'kmeans-predict (lambda () (kc-predict handle c x #f 1 y)))))
held-labels
]

A released array is refused wherever it is passed:

@examples[#:eval ev #:label #f
(eval:error (with-array-views ([v early]) v))
(eval:error (kc-predict-job 'kmeans-predict (current-device-resources) fitted early #f 1 labels))
]

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
       (list @tt{int32_t memory} "12" @elem{@tt{RR_MEMORY_DEVICE} (2) for every array})
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

@bold{@tt{raftrkt/deposit.h}.} An @tt{rr_deposit} is 1256 bytes. raft
fills the first three fields when it makes the deposit; the native call fills
the rest:

@tabular[#:sep @hspace[2]
         #:style 'boxed
         #:row-properties '(bottom-border ())
 (list (list @bold{Field} @bold{Offset} @bold{Meaning})
       (list @tt{const void* handle} "0" @elem{the @tt{raft::handle_t*} of the deposit's resources})
       (list @tt{int32_t device} "8" "the CUDA device")
       (list @tt{int32_t state} "12" @elem{@tt{RR_DEPOSIT_OPEN} 0, @tt{FILLED} 1, @tt{CLOSED} 2, @tt{FILLING} 3})
       (list @tt{void* owner} "16" "what frees the regions' memory")
       (list @tt{rr_release_fn release} "24" @elem{@tt{void (*)(void* owner)}})
       (list @tt{int32_t count} "32" @elem{0 to @tt{RR_MAX_REGIONS} (8)})
       (list @tt{rr_view regions[8]} "40" "each a device view of rank 1 or 2"))]

Once the record is filled, it owns the owner, and @tt{libraftrkt} calls
@tt{release(owner)} exactly once. @tt{release} runs on any OS thread, with
the deposit's device current and its @tt{raft::handle_t} still alive, and may
run concurrently with the library's other calls; it must not throw or call
Racket. Every region lies in memory the owner frees, on the handle's stream,
and its contents are complete when the call returns.

@bold{@tt{raftrkt/deposit.hpp}.} Header-only, like @tt{view.hpp}:

@itemlist[
 @item{@tt{rr_view raftrkt::region(rmm::device_uvector<T>& v)},
       @tt{region(T* data, int64_t n)} and @tt{region(T* data, int64_t rows,
       int64_t cols, raftrkt::layout l)}: a vector or a matrix with
       canonical strides, for @tt{T} one of the four element types.}
 @item{@tt{void raftrkt::deposit(rr_deposit* into, const char* name, const
       raft::handle_t& handle, std::unique_ptr<Owner>&& owner,
       std::initializer_list<rr_view> regions)}: refuses, in order, a
       @tt{NULL} record, a record that is not open (@tt{"out: being filled"}
       while another filler holds it, @tt{"out: already filled"},
       @tt{"out: closed"}), a record on other resources than
       @tt{handle}'s, no owner, more than 8 regions, a region of another
       rank or element type, with a negative extent, a byte size that
       overflows, another layout, no data or misaligned data, overlapping
       regions, and memory that is not on the record's device. A refusal
       throws @tt{raftrkt::logic_error} and leaves the owner to the caller's
       @tt{unique_ptr}. After the @tt{NULL} check it claims an open record by
       moving it to @tt{FILLING}; a record that cannot be claimed is refused with
       nothing touched, so a second filler cannot disturb the first. A
       later refusal touches nothing but @tt{state}: the record is open
       again, or closed if it was closed meanwhile, and its other fields are
       as they were. Otherwise it fills the record, moves it to
       @tt{FILLED} and takes the owner; a record closed during the fill is
       refused with @tt{"out: closed"}, as above.}]

@listing["C++"]|{
auto owner = std::make_unique<members<T>>(handle, m, d);
// The regions read owner before deposit takes it: std::move is only a cast.
raftrkt::deposit(out, "out", handle, std::move(owner),
                 {raftrkt::region(owner->indices),
                  raftrkt::region(owner->rows.data(), m, d, raftrkt::layout::row_major)});
}|

@bold{@tt{raftrkt/csr.hpp}.} Header-only host C++, for a @tech{CSR matrix}
passed as three views (its @racket[csr-indptr], @racket[csr-indices] and
@racket[csr-data]) and its column count, or deposited as three regions.
@tt{Index} is @tt{int32_t} or @tt{int64_t} and @tt{T} is @tt{float} or
@tt{double}; @tt{csr_parts} and @tt{csr_view} also take them @tt{const}:

@itemlist[
 @item{@tt{raftrkt::csr_data<T, Index> raftrkt::csr_parts<T, Index>(const
       rr_view* indptr, const rr_view* indices, const rr_view* data, int64_t
       rows, int64_t cols, const char* name)}: the three pointers with
       @tt{rows}, @tt{cols} and @tt{nnz}, after the checks of
       @racket[device-csr-matrix] that need no GPU, its messages prefixed
       @tt{"<name>: "} unless @tt{name} is @tt{NULL}. @tt{rows} may be
       @tt{any_extent}, then indptr's length less one. The contents are not
       read: raft checked them when it made the matrix.}
 @item{@tt{raftrkt::csr_view<T, Index, NZ = uint64_t>(...)}, with the same
       arguments: a @tt{raft::device_csr_matrix_view<T, Index, Index, NZ>}.}
 @item{@tt{raftrkt::csr_buffers<T, Index>(handle, rows, nnz)}: an owner of
       three @tt{rmm::device_uvector}s, @tt{indptr} (rows + 1), @tt{indices}
       and @tt{data} (nnz), on the handle's stream; @tt{resize_entries(nnz)}
       resizes the last two, for a call that learns nnz from indptr.}
 @item{@tt{int64_t raftrkt::read_nnz(handle, const Index* indptr, int64_t
       rows)}: @tt{indptr[rows]}, read after the handle's stream finishes.
       It, @tt{csr_buffers} and @tt{resize_entries} take no name: a negative
       extent is refused as
       @tt{"rows: negative extent -1"} or @tt{"nnz: negative extent -1"}.}
 @item{@tt{raftrkt::deposit_csr(into, name, handle, std::move(owner),
       indptr, rows, indices, data, nnz)}, and
       @tt{deposit_csr(into, name, handle, std::move(buffers))} for a
       @tt{std::unique_ptr<csr_buffers<T, Index>>}: @tt{raftrkt::deposit} of
       the three regions in the order @racket[deposit->device-csr-matrix]
       reads, refusing an indptr of no elements or of more than an extent
       holds and, for buffers, data of another length than indices, before
       the record is claimed.}]

@listing["C++"]|{
auto o = std::make_unique<raftrkt::csr_buffers<float, int64_t>>(handle, n, 0);
fill_indptr(handle, o->indptr.data());
o->resize_entries(raftrkt::read_nnz(handle, o->indptr.data(), n));
fill_entries(handle, o->indices.data(), o->data.data());
raftrkt::deposit_csr(out, "out", handle, std::move(o));
}|

@bold{@tt{raftrkt/job.h}.} An @tt{rr_job_outcome} is 4104 bytes:
@tt{int32_t status} at 0, @tt{int32_t kind} at 4 and
@tt{char message[RR_JOB_MESSAGE_BYTES]} (4096) at 8. A job entry is an
@tt{rr_job_fn}, @tt{void (*)(void* args, size_t args_len, rr_job_outcome*
outcome)}: it runs on a raft worker thread, after the previous job on the
same resources returned, and must not throw or call Racket.

@bold{@tt{raftrkt/job.hpp}.} Header-only.
@tt{raftrkt::run_job<&f>(args, args_len, outcome, slot)} unpacks the block
@racket[define-job] builds, calls @tt{f}, writes its outputs back, and
records its status and, on failure, the kind and message from @tt{slot}, the
library's error slot, read on the worker right after @tt{f} returns. @tt{f}
returns @tt{int} and takes only @tt{void*} (the handle), @tt{const rr_view*},
@tt{rr_deposit*}, numbers, and pointers to non-const numbers (its outputs);
anything else does not compile (@tt{raftrkt::job_parameter}).
@tt{raftrkt::job_args_size<&f>} is the block's size.

@bold{What is frozen.} @tt{rr_view}, @tt{RR_MAX_RANK} and the dtype and memory
codes; @tt{rr_buffer_view}; @tt{rr_resources_handle}; @tt{rr_abi_tag},
@tt{rr_abi} and @tt{RR_ABI_VERSION}; the status codes, error kinds and
@tt{rr_last_error} convention; the three headers above; the four exports of
this module; and the rules a downstream entry point keeps: run inside
@tt{translate_exceptions}, select the handle's device, refuse arrays on
another device, read arrays only through @tt{view.hpp}, and synchronise the
handle's stream on every exit. A change to any of them is a new ABI version,
with the canary changed in the same pull request. Additions at version 1
(#22, #32): @tt{rr_deposit}, @tt{RR_MAX_REGIONS}, the @tt{RR_DEPOSIT_*}
states, @tt{rr_release_fn}, @tt{deposit.hpp}, @racket[deposit],
@racket[deposit?], @racket[with-deposits], @racket[deposit->list],
@tt{rr_job_outcome}, @tt{RR_JOB_MESSAGE_BYTES}, @tt{rr_job_fn},
@tt{job.hpp}, @racket[define-job], and the rule that a call that can run long
is a job; a downstream detects them by requiring @racketmodname[raft] version
0.2, or with @tt{__has_include}. Then @tt{csr.hpp} and
@racket[deposit->device-csr-matrix], detected by @racketmodname[raft] version
0.3 or @tt{__has_include(<raftrkt/csr.hpp>)}.

@(close-eval ev)
