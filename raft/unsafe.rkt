#lang racket/base

(require (for-syntax racket/base)
         (only-in ffi/unsafe/atomic call-as-atomic)
         ;; whole-module: it also provides syntax/parse at phase 1
         syntax/parse/define
         (only-in "private/array.rkt" settled-view)
         (only-in "private/error.rkt" call/raft exn:fail:raft)
         (only-in "private/foreign/array.rkt" clear-view!)
         (only-in "private/foreign/core.rkt" rr-abi rr-resources-handle)
         (only-in "private/resource.rkt" with-release)
         (only-in "private/resources.rkt" resources-handle))

(provide raft-abi-pointer
         resources->handle-pointer
         status-checker
         with-array-views)

(define (raft-abi-pointer)
  (rr-abi))

(define (resources->handle-pointer r)
  (define who 'resources->handle-pointer)
  (call/raft who (lambda () (rr-resources-handle (resources-handle who r)))))

(define error-kinds #(generic out-of-memory cuda logic))

(define (kind->symbol kind)
  (cond
    [(symbol? kind) kind]
    [(and (exact-nonnegative-integer? kind) (< kind (vector-length error-kinds)))
     (vector-ref error-kinds kind)]
    [else 'generic]))

(define (message->string message)
  (if (bytes? message)
      (bytes->string/utf-8 message #\uFFFD)
      (format "~a" message)))

(define ((status-checker last-error last-error-kind #:exn [exn exn:fail:raft]) who thunk)
  (define-values (results message kind)
    (call-as-atomic
     (lambda ()
       (call-with-values thunk
                         (lambda (status . results)
                           (if (eqv? status 0)
                               (values results #f #f)
                               (values #f (last-error) (last-error-kind))))))))
  (unless results
    (raise (exn (format "~a: ~a" who (message->string message))
                (current-continuation-marks)
                (kind->symbol kind))))
  (apply values results))

(define (view-release a) ;; noqa
  (lambda (view) (clear-view! view a)))

(begin-for-syntax
  (define-syntax-class view-binding
    #:description "a [name array-expr] binding"
    (pattern [name:id array:expr])))

(define-syntax-parse-rule (with-array-views (b:view-binding ...) body:expr ...+)
  #:fail-when (check-duplicate-identifier (syntax->list #'(b.name ...))) "duplicate binding name"
  #:with (a ...) (generate-temporaries #'(b.name ...))
  (let ([a b.array] ...)
    (with-release #:who 'with-array-views
                  ([b.name (and a (settled-view 'with-array-views a)) (view-release a)] ...)
                  body ...)))
