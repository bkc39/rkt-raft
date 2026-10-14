#lang racket/base

(require (for-syntax racket/base)
         (only-in ffi/unsafe/atomic call-as-atomic)
         ;; whole-module: it also provides syntax/parse at phase 1
         syntax/parse/define
         (only-in "private/array.rkt" settled-view)
         (only-in "private/error.rkt" call/raft)
         (only-in "private/exn.rkt" exn:fail:raft raise-native)
         (only-in "private/foreign/array.rkt" clear-view! keep-reachable)
         (only-in "private/foreign/core.rkt" rr-abi rr-resources-handle)
         (only-in "private/job.rkt" define-job)
         (only-in "private/resource.rkt" with-release)
         (only-in "private/resources.rkt" resources-handle))

(provide define-job ;; noqa
         raft-abi-pointer
         resources->handle-pointer
         status-checker
         with-array-views)

(define (raft-abi-pointer)
  (rr-abi))

(define (handle-for who r)
  (call/raft who (lambda () (rr-resources-handle (resources-handle who r)))))

(define (resources->handle-pointer r)
  (handle-for 'resources->handle-pointer r))

(define (message->string message)
  (if (bytes? message)
      (bytes->string/utf-8 message #\uFFFD)
      (format "~a" message)))

(define ((status-checker last-error last-error-kind #:exn [exn exn:fail:raft]) who thunk)
  (define-values (results message kind)
    (call-as-atomic (lambda ()
                      (call-with-values thunk
                                        (lambda (status . results)
                                          (if (eqv? status 0)
                                              (values results #f #f)
                                              (values #f (last-error) (last-error-kind))))))))
  (if results
      (apply values results)
      (raise-native exn who kind (message->string message))))

(define (view-release a) ;; noqa
  (lambda (view) (clear-view! view a)))

(begin-for-syntax
  (define-syntax-class view-binding
    #:description "a [name array-expr] binding"
    (pattern [name:id array:expr])))

(define (handle-release r) ;; noqa
  (lambda (_handle) (keep-reachable r)))

(define-syntax-parse-rule (with-array-views (~optional (~seq #:resources [handle:id resources:expr]))
                            (b:view-binding ...)
                            body:expr ...+)
  #:fail-when (check-duplicate-identifier (syntax->list #'((~? handle) b.name
                                                                       ...))) "duplicate binding name"
  #:with (a ...) (generate-temporaries #'(b.name ...))
  (let ([r (~? resources #f)]
        [a b.array] ...)
    (with-release #:who 'with-array-views
                  ((~? [handle (handle-for 'with-array-views r) (handle-release r)])
                   [b.name (and a (settled-view 'with-array-views a)) (view-release a)] ...)
                  body ...)))
