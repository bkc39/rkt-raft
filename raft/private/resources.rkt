#lang racket/base

(require (for-syntax racket/base
                     ;; whole-module: syntax-parse needs its syntax classes
                     syntax/parse)
         (only-in racket/math exact-ceiling)
         (only-in "error.rkt" call/raft raise-raft)
         (only-in "foreign/core.rkt" rr-device-count rr-resources-create rr-resources-ready)
         (only-in "foreign/internal.rkt" rr-memory-resource-kind)
         (only-in "foreign/memory.rkt" released? rr-resources-free)
         (only-in "resource.rkt" with-release)
         ;; whole-module: its syntax classes come with it
         syntax/parse/define)

(provide current-device-resources
         device-resources
         device-resources?
         in-backoff
         memory-resource-kind
         resources-device
         resources-handle
         resources-sync!
         with-device-resources)

(struct device-resources (handle device)
  #:omit-define-syntaxes
  #:constructor-name handle->device-resources
  #:property prop:custom-write
  (lambda (r port _mode)
    (fprintf port
             "#<device-resources device ~a~a>"
             (device-resources-device r)
             (if (released? (device-resources-handle r)) " released" ""))))

(define (resources-arg who v)
  (if (device-resources? v)
      v
      (raise-raft who 'logic "expected device resources, given: ~e" v)))

(define int32-limit (expt 2 31))

(define (device-arg who d)
  (cond
    [(not (exact-integer? d)) (raise-raft who 'logic "expected a device number, given: ~e" d)]
    [(< (- int32-limit) d int32-limit) d]
    [else (raise-raft who 'logic "no device ~a among ~a" d (call/raft who rr-device-count))]))

(define (open-resources who device)
  (define d (device-arg who device))
  (handle->device-resources (call/raft who (lambda () (rr-resources-create d))) d))

(define (device-resources #:device [device 0])
  (open-resources 'device-resources device))

(define (resources-device r)
  (device-resources-device (resources-arg 'resources-device r)))

(define (resources-handle who r)
  (define handle (device-resources-handle (resources-arg who r)))
  (when (released? handle)
    (raise-raft who
                'logic
                "the device resources on device ~a were released"
                (device-resources-device r)))
  handle)

(define (release-resources! r)
  (rr-resources-free (device-resources-handle r)))

(define spin-polls 16)
(define first-pause 1e-5)
(define longest-pause 1e-3)
(define doublings (exact-ceiling (/ (log (/ longest-pause first-pause)) (log 2))))

(define (pause-after polls)
  (if (< polls spin-polls)
      0.0
      (min longest-pause (* first-pause (expt 2 (min doublings (- polls spin-polls)))))))

(define (in-backoff)
  (make-do-sequence (lambda () (values pause-after add1 0 #f #f #f))))

(define (stream-ready? who r)
  (eq? 'ready (call/raft who (lambda () (rr-resources-ready (resources-handle who r))))))

(define (resources-sync! r)
  (for ([pause (in-backoff)]
        #:break (stream-ready? 'resources-sync! r))
    (sleep pause)))

(define defaults (make-thread-cell #hasheqv()))

(define (current-device-resources [device 0])
  (define table (thread-cell-ref defaults))
  (define cached (hash-ref table (device-arg 'current-device-resources device) #f))
  (cond
    [(and cached (not (released? (device-resources-handle cached)))) cached]
    [else
     (define fresh (open-resources 'current-device-resources device))
     (thread-cell-set! defaults (hash-set table device fresh))
     fresh]))

(define (memory-resource-kind [device 0])
  (call/raft 'memory-resource-kind (lambda () (rr-memory-resource-kind device))))

(begin-for-syntax
  (define-syntax-class resources-binding
    #:description "a [name resources-expr] binding"
    (pattern [name:id init:expr])))

(define-syntax-parse-rule (with-device-resources (b:resources-binding ...) body:expr ...+)
  #:fail-when (check-duplicate-identifier (syntax->list #'(b.name ...)))
  "duplicate binding name"
  (with-release ([b.name (resources-arg 'with-device-resources b.init) release-resources!] ...)
    body ...))
