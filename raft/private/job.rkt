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
                  make-cstruct-type)
         ;; whole-module: it also provides syntax/parse at phase 1
         syntax/parse/define
         (only-in "error.rkt" exn:fail:raft)
         (only-in "foreign/array.rkt" _rr-view)
         (only-in "foreign/job-api.rkt" rr-executor-threads rr-jobs-in-flight rr-jobs-live))

(provide define-job
         (rename-out [rr-executor-threads executor-threads]
                     [rr-jobs-in-flight jobs-in-flight]
                     [rr-jobs-live jobs-live]))

(struct slot (kind type))

(define (run-job who resources entry slots offsets size outputs exn args)
  (error 'unimplemented))

(define (job-procedure name entry slots exn)
  (define types (map slot-type slots))
  (define offsets (compute-offsets types))
  (define size (ctype-sizeof (make-cstruct-type types)))
  (define arity
    (+ 2
       (for/sum ([s (in-list slots)])
         (if (memq (slot-kind s) '(handle out)) 0 1))))
  (define outputs
    (for/list ([s (in-list slots)]
               [at (in-list offsets)]
               #:when (eq? (slot-kind s) 'out))
      (cons (slot-type s) at)))
  (procedure-rename (procedure-reduce-arity (lambda (who resources . args)
                                              (run-job who
                                                       resources
                                                       entry
                                                       slots
                                                       offsets
                                                       size
                                                       outputs
                                                       exn
                                                       args))
                                            arity)
                    name))

(begin-for-syntax
  (define job-param-description "a job parameter: handle, view, (out type) or a number type")

  (define-syntax-class in-type
    #:description "a number type: _int8 … _double*"
    #:opaque
    (pattern (~or* (~literal _int8)
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
    #:opaque
    (pattern (~or* (~literal _int8)
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

(define-syntax-parse-rule (define-job id:id library:expr c-id:expr (p:job-param ...) (~optional e:job-exn))
  #:fail-when (second-handle #'(p ...) (attribute p.kind)) "at most one handle parameter"
  (define id
    (job-procedure 'id (get-ffi-obj c-id library _fpointer) (list p.spec ...) (~? e.make exn:fail:raft))))
