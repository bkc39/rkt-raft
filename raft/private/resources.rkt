#lang racket/base

(require (for-syntax racket/base)
         (only-in racket/math exact-ceiling)
         ;; whole-module: it also provides syntax/parse at phase 1
         syntax/parse/define
         (only-in "error.rkt" call/raft)
         (only-in "exn.rkt" raise-raft)
         (only-in "foreign/core.rkt" rr-resources-create)
         (only-in "foreign/internal.rkt" rr-memory-resource-kind rr-resources-ready)
         (only-in "foreign/memory.rkt" released? rr-resources-free)
         (only-in "resource.rkt" with-release))

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

(define (open-resources who device)
  (handle->device-resources (call/raft who (lambda () (rr-resources-create device))) device))

(define (device-resources #:device [device 0]) ;; noqa
  (open-resources 'device-resources device))

(define (resources-device r)
  (device-resources-device r))

(define (resources-handle who r)
  (define handle (device-resources-handle r))
  (when (released? handle)
    (raise-raft who
                'logic
                "the device resources on device ~a were released"
                (device-resources-device r)))
  handle)

(define (release-resources! r) ;; noqa
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
  (define cached (hash-ref table device #f))
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
  #:fail-when (check-duplicate-identifier (syntax->list #'(b.name ...))) "duplicate binding name"
  (with-release #:who 'with-device-resources ([b.name b.init release-resources!] ...) body ...))
