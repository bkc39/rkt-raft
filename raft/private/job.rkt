#lang racket/base

(require (for-syntax racket/base
                     (only-in racket/match match))
         (only-in ffi/unsafe
                  _double
                  _double*
                  _float
                  _fpointer
                  _int16
                  _int32
                  _int64
                  _int8
                  _pointer
                  _uint16
                  _uint32
                  _uint64
                  _uint8
                  compute-offsets
                  ctype-sizeof
                  get-ffi-obj
                  make-cstruct-type
                  ptr-ref
                  ptr-set!)
         (only-in ffi/unsafe/atomic in-atomic-mode?)
         (only-in ffi/unsafe/schedule unsafe-poll-ctx-fd-wakeup unsafe-poller)
         (only-in racket/list count)
         (only-in racket/match match-define)
         ;; whole-module: it also provides syntax/parse at phase 1
         syntax/parse/define
         (only-in "array.rkt" array-buffer-handle device-array? settled-view)
         (only-in "error.rkt" call/raft)
         (only-in "exit.rkt" current-exit-wait)
         (only-in "exn.rkt" exn:fail:raft raise-native raise-raft)
         (only-in "foreign/array.rkt" _rr-view blank-view keep-reachable)
         (only-in "foreign/core.rkt" rr-resources-handle)
         (only-in "foreign/memory.rkt" released?)
         (only-in "foreign/job-api.rkt"
                  rr-executor-threads
                  rr-job-fd
                  rr-job-message
                  rr-job-read
                  rr-job-release
                  rr-job-state
                  rr-job-status
                  rr-job-submit
                  rr-jobs-in-flight
                  rr-jobs-live)
         (only-in "resource.rkt" with-release)
         (only-in "resources.rkt" resources-handle))

(provide define-job
         executor-threads
         jobs-in-flight
         jobs-live)

(struct slot (type pack takes? output?)) ;; noqa

(define job-done 1)
(define job-refused 2)

(define (executor-threads)
  (rr-executor-threads))

(define (jobs-in-flight)
  (rr-jobs-in-flight))

(define (jobs-live)
  (rr-jobs-live))

(struct job-evt (job)
  #:property prop:evt
  (unsafe-poller (lambda (self wakeups)
                   (define job (job-evt-job self))
                   (cond
                     [(= (rr-job-state job) job-done) (values (list job) #f)]
                     [else
                      (when wakeups
                        (unsafe-poll-ctx-fd-wakeup wakeups (rr-job-fd job) 'read))
                      (values #f self)]))))

(define (set-number! who block type offset v)
  (with-handlers ([exn:fail:contract?
                   (lambda (e)
                     (raise (exn:fail:contract
                             (regexp-replace #rx"^ptr-set!"
                                             (exn-message e)
                                             (regexp-replace-quote (symbol->string who)))
                             (exn-continuation-marks e))))])
    (ptr-set! block type 'abs offset v)))

(define (pack-handle who block offset native args pins) ;; noqa
  (ptr-set! block _pointer 'abs offset (call/raft who (lambda () (rr-resources-handle native))))
  (values args pins))

(define (pack-nothing _who _block _offset _native args pins) ;; noqa
  (values args pins))

(define (pack-view who block offset _native args pins) ;; noqa
  (match-define (cons a rest) args)
  (cond
    [(device-array? a)
     (ptr-set! block _rr-view 'abs offset (settled-view who a))
     (values rest (cons (array-buffer-handle a) pins))]
    [(not a)
     (ptr-set! block _rr-view 'abs offset (blank-view))
     (values rest pins)]
    [else (raise-raft who 'logic "expected a device array or #f for a view, given ~e" a)]))

(define ((pack-number type) who block offset _native args pins) ;; noqa
  (match-define (cons v rest) args)
  (set-number! who block type offset v)
  (values rest pins))

(define (pack! who block native slots offsets args)
  (for/fold ([args args]
             [pins '()]
             #:result pins)
            ([s (in-list slots)]
             [offset (in-list offsets)])
    ((slot-pack s) who block offset native args pins)))

(define (waited-status job)
  (sync (job-evt job))
  (define-values (status _kind) (rr-job-status job))
  status)

(define (job-finish who job block outputs exn)
  (cond
    [(= (rr-job-state job) job-refused) (lambda () (sync never-evt))]
    [(zero? (waited-status job))
     (call/raft who (lambda () (rr-job-read job block)))
     (define results
       (for/list ([output (in-list outputs)])
         (match-define (cons type at) output)
         (ptr-ref block type 'abs at)))
     (lambda () (apply values results))]
    [else
     (define-values (_status kind) (rr-job-status job))
     (define message (bytes->string/utf-8 (rr-job-message job) #\uFFFD))
     (lambda () (raise-native exn who kind message))]))

(define (live-handle who resources pins)
  (define handle (resources-handle who resources))
  (cond
    [(ormap released? pins) (raise-raft who 'logic "a device array passed to the job was released")]
    [else handle]))

(define (submit who resources entry block pins seconds)
  (call/raft who
             (lambda ()
               (rr-job-submit (live-handle who resources pins) entry block pins '() seconds))))

(define (run-job who resources entry slots offsets size outputs exn args)
  (when (in-atomic-mode?)
    (raise-raft who 'logic "cannot wait for a job in atomic mode"))
  (define seconds (real->double-flonum (current-exit-wait)))
  (define native (resources-handle who resources))
  (define block (make-bytes size 0))
  (define pins (pack! who block native slots offsets args))
  (define finish
    (parameterize-break
     #f
     (with-release #:who who ([job (submit who resources entry block pins seconds) rr-job-release])
       (job-finish who job block outputs exn))))
  (keep-reachable (list resources args))
  (parameterize-break (break-enabled) (void))
  (finish))

(define (job-procedure name entry slots exn) ;; noqa
  (define offsets (compute-offsets (map slot-type slots)))
  (define size (ctype-sizeof (make-cstruct-type (map slot-type slots))))
  (define arity (+ 2 (count slot-takes? slots)))
  (define outputs
    (for/list ([s (in-list slots)]
               [at (in-list offsets)]
               #:when (slot-output? s))
      (cons (slot-type s) at)))
  (procedure-rename
   (procedure-reduce-arity (lambda (who resources . args)
                             (run-job who resources entry slots offsets size outputs exn args))
                           arity)
   name))

(begin-for-syntax
  (define job-param-description ;; noqa
    "a job parameter: handle, view, (out type) or a number type")

  (define-syntax-class in-type
    #:description "a number type: _int8 … _double*"
    #:opaque (pattern (~or* (~literal _int8)
                            (~literal _uint8)
                            (~literal _int16)
                            (~literal _uint16)
                            (~literal _int32)
                            (~literal _uint32)
                            (~literal _int64)
                            (~literal _uint64)
                            (~literal _float)
                            (~literal _double)
                            (~literal _double*))))

  (define-syntax-class out-type
    #:description "an output type: _int8 … _double"
    #:opaque (pattern (~and (~not (~literal _double*)) :in-type)))

  (define-syntax-class job-param
    #:description job-param-description
    #:datum-literals (handle out view)
    (pattern handle
      #:attr kind 'handle
      #:with spec #'(slot _pointer pack-handle #f #f))
    (pattern view
      #:attr kind 'view
      #:with spec #'(slot _rr-view pack-view #t #f))
    (pattern ((~describe #:opaque job-param-description out) type:out-type)
      #:attr kind 'out
      #:with spec #'(slot type pack-nothing #f #t))
    (pattern type:in-type
      #:attr kind 'in
      #:with spec #'(slot type (pack-number type) #t #f)))

  (define (second-handle params kinds) ;; noqa
    (match (for/list ([p (in-list (syntax->list params))]
                      [kind (in-list kinds)]
                      #:when (eq? kind 'handle))
             p)
      [(list* _ second _) second]
      [_ #f])))

(define-syntax-parse-rule (define-job id:id
                                      library:expr
                                      c-id:expr
                                      (p:job-param ...)
                                      (~optional (~seq #:exn make:expr)))
  #:fail-when (second-handle #'(p ...) (attribute p.kind)) "at most one handle parameter"
  (define id
    (job-procedure 'id
                   (get-ffi-obj c-id library _fpointer)
                   (list p.spec ...)
                   (~? make exn:fail:raft))))
