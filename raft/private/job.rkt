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
         (only-in racket/match match match*)
         ;; whole-module: it also provides syntax/parse at phase 1
         syntax/parse/define
         (only-in "array.rkt" array-buffer-handle settled-view)
         (only-in "error.rkt" call/raft exn:fail:raft)
         (only-in "exit.rkt" current-exit-wait)
         (only-in "exn.rkt" raise-raft)
         (only-in "foreign/array.rkt" _rr-view blank-view)
         (only-in "foreign/core.rkt" rr-resources-handle)
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
         (rename-out [rr-executor-threads executor-threads]
                     [rr-jobs-in-flight jobs-in-flight]
                     [rr-jobs-live jobs-live]))

(struct slot (kind type))

(define job-done 1)
(define job-refused 2)

(define error-kinds #(generic out-of-memory cuda logic))

(define (code->kind code)
  (if (< -1 code (vector-length error-kinds))
      (vector-ref error-kinds code)
      'generic))

(define (job-evt job)
  (unsafe-poller (lambda (self wakeups)
                   (cond
                     [(= (rr-job-state job) job-done) (values (list job) #f)]
                     [wakeups
                      (unsafe-poll-ctx-fd-wakeup wakeups (rr-job-fd job) 'read)
                      (values #f self)]
                     [else (values #f self)]))))

(define (set-number! who block type offset v)
  (with-handlers ([exn:fail:contract?
                   (lambda (e)
                     (raise (exn:fail:contract
                             (regexp-replace #rx"^ptr-set!"
                                             (exn-message e)
                                             (regexp-replace-quote (symbol->string who)))
                             (exn-continuation-marks e))))])
    (ptr-set! block type 'abs offset v)))

(define (pack! who block native slots offsets args)
  (for/fold ([args args]
             [pins '()]
             #:result pins)
            ([s (in-list slots)]
             [offset (in-list offsets)])
    (match* ((slot-kind s) args)
      [('handle _)
       (ptr-set! block _pointer 'abs offset (call/raft who (lambda () (rr-resources-handle native))))
       (values args pins)]
      [('out _) (values args pins)]
      [('view (cons #f rest))
       (ptr-set! block _rr-view 'abs offset (blank-view))
       (values rest pins)]
      [('view (cons a rest))
       (ptr-set! block _rr-view 'abs offset (settled-view who a))
       (values rest (cons (array-buffer-handle a) pins))]
      [('in (cons v rest))
       (set-number! who block (slot-type s) offset v)
       (values rest pins)])))

(define (job-outcome who job block outputs)
  (sync (job-evt job))
  (define-values (status kind) (rr-job-status job))
  (cond
    [(zero? status)
     (call/raft who (lambda () (rr-job-read job block)))
     (cons 'returned
           (for/list ([output (in-list outputs)])
             (ptr-ref block (car output) 'abs (cdr output))))]
    [else (list 'failed kind (bytes->string/utf-8 (rr-job-message job) #\uFFFD))]))

(define (run-job who resources entry slots offsets size outputs exn args)
  (cond
    [(in-atomic-mode?) (raise-raft who 'logic "cannot wait for a job in atomic mode")]
    [else
     (define seconds (real->double-flonum (current-exit-wait)))
     (define native (resources-handle who resources))
     (define block (make-bytes size 0))
     (define pins (pack! who block native slots offsets args))
     (define outcome
       (parameterize-break
        #f
        (define job (call/raft who (lambda () (rr-job-submit native entry block pins '() seconds))))
        (cond
          [(= (rr-job-state job) job-refused)
           (rr-job-release job)
           '(refused)]
          [else
           (with-release #:who who ([j job rr-job-release])
             (job-outcome who j block outputs))])))
     (parameterize-break (break-enabled) (void))
     (match outcome
       [(list 'refused) (sync never-evt)]
       [(list 'failed kind message)
        (raise (exn (format "~a: ~a" who message) (current-continuation-marks) (code->kind kind)))]
       [(cons 'returned results) (apply values results)])]))

(define (job-procedure name entry slots exn)
  (define types (map slot-type slots))
  (define offsets (compute-offsets types))
  (define size (ctype-sizeof (make-cstruct-type types)))
  (define arity (+ 2 (for/sum ([s (in-list slots)]) (if (memq (slot-kind s) '(handle out)) 0 1))))
  (define outputs
    (for/list ([s (in-list slots)]
               [at (in-list offsets)]
               #:when (eq? (slot-kind s) 'out))
      (cons (slot-type s) at)))
  (procedure-rename
   (procedure-reduce-arity (lambda (who resources . args)
                             (run-job who resources entry slots offsets size outputs exn args))
                           arity)
   name))

(begin-for-syntax
  (define job-param-description "a job parameter: handle, view, (out type) or a number type")

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
    #:opaque (pattern (~or* (~literal _int8)
                            (~literal _uint8)
                            (~literal _int16)
                            (~literal _uint16)
                            (~literal _int32)
                            (~literal _uint32)
                            (~literal _int64)
                            (~literal _uint64)
                            (~literal _float)
                            (~literal _double))))

  (define-syntax-class job-param
    #:description job-param-description
    #:datum-literals (handle out view)
    (pattern handle
      #:attr kind 'handle
      #:with spec #'(slot 'handle _pointer))
    (pattern view
      #:attr kind 'view
      #:with spec #'(slot 'view _rr-view))
    (pattern ((~describe #:opaque job-param-description out) type:out-type)
      #:attr kind 'out
      #:with spec #'(slot 'out type))
    (pattern type:in-type
      #:attr kind 'in
      #:with spec #'(slot 'in type)))

  (define-splicing-syntax-class job-exn
                                #:description "#:exn and an exception constructor"
                                (pattern (~seq #:exn make:expr)))

  (define (second-handle params kinds)
    (match (for/list ([p (in-list (syntax->list params))]
                      [kind (in-list kinds)]
                      #:when (eq? kind 'handle))
             p)
      [(list _ second _ ...) second]
      [_ #f])))

(define-syntax-parse-rule (define-job id:id
                                      library:expr
                                      c-id:expr
                                      (p:job-param ...)
                                      (~optional e:job-exn))
  #:fail-when (second-handle #'(p ...) (attribute p.kind)) "at most one handle parameter"
  (define id
    (job-procedure 'id
                   (get-ffi-obj c-id library _fpointer)
                   (list p.spec ...)
                   (~? e.make exn:fail:raft))))
