#lang racket/base

(require (for-syntax racket/base)
         (only-in ffi/unsafe/os-async-channel make-os-async-channel os-async-channel-put)
         (only-in ffi/unsafe/os-thread call-in-os-thread)
         (only-in racket/match match)
         ;; whole-module: it also provides syntax/parse at phase 1
         syntax/parse/define
         (only-in "private/array.rkt" settled-view)
         (only-in "private/error.rkt" call/raft exn:fail:raft)
         (only-in "private/foreign/array.rkt" clear-view! keep-reachable)
         (only-in "private/foreign/core.rkt" rr-abi rr-resources-handle)
         (only-in "private/resource.rkt" with-release)
         (only-in "private/resources.rkt" resources-handle))

(provide raft-abi-pointer
         resources->handle-pointer
         status-checker
         with-array-views)

(define (raft-abi-pointer)
  (rr-abi))

(define (handle-for who r)
  (call/raft who (lambda () (rr-resources-handle (resources-handle who r)))))

(define (resources->handle-pointer r)
  (handle-for 'resources->handle-pointer r))

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

(define (fresh-message message)
  (if (bytes? message)
      (bytes-copy message)
      message))

(define ((call-reading-error thunk last-error last-error-kind))
  (call/ec (lambda (escape)
             (call-with-exception-handler
              (lambda (e) (escape (list 'raised e)))
              (lambda ()
                (call-with-values thunk
                                  (lambda (status . results)
                                    (if (eqv? status 0)
                                        (list 'ok results)
                                        (list 'failed
                                              (fresh-message (last-error))
                                              (last-error-kind))))))))))

(define (deliver-pending-break)
  (parameterize-break (break-enabled)
    (void)))

(define (call-in-os-thread/wait call)
  (define channel (make-os-async-channel))
  (call-in-os-thread (lambda () (os-async-channel-put channel (call))))
  (begin0 (parameterize-break #f
            (sync channel))
    (deliver-pending-break)))

(define ((status-checker last-error last-error-kind #:exn [exn exn:fail:raft]) who thunk)
  (match (call-in-os-thread/wait (call-reading-error thunk last-error last-error-kind))
    [(list 'ok results) (apply values results)]
    [(list 'raised e) (raise e)]
    [(list 'failed message kind)
     (raise (exn (format "~a: ~a" who (message->string message))
                 (current-continuation-marks)
                 (kind->symbol kind)))]))

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
