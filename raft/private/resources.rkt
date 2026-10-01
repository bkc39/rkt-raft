#lang racket/base

(require (for-syntax racket/base
                     ;; whole-module: syntax-parse needs its syntax classes
                     syntax/parse)
         (only-in "error.rkt" call/raft exn:fail:raft)
         (only-in "foreign/core.rkt" rr-resources-create rr-resources-ready)
         (only-in "foreign/memory.rkt" released? rr-memory-resource-kind rr-resources-free)
         (only-in "resource.rkt" with-release)
         ;; whole-module: its syntax classes come with it
         syntax/parse/define)

(provide current-device-resources
         device-resources
         device-resources?
         memory-resource-kind
         resources-device
         resources-handle
         resources-sync!
         with-device-resources)

(struct device-resources (handle device)
  #:name device-resources-type
  #:constructor-name wrap-resources
  #:property prop:custom-write
  (lambda (r port _mode)
    (write-string (format "#<device-resources device ~a~a>"
                          (device-resources-device r)
                          (if (released? (device-resources-handle r)) " released" ""))
                  port)))

(define (open-resources who device)
  (wrap-resources (call/raft who (lambda () (rr-resources-create device))) device))

(define (device-resources #:device [device 0])
  (open-resources 'device-resources device))

(define (resources-device r)
  (device-resources-device r))

(define (resources-handle who r)
  (define handle (device-resources-handle r))
  (if (released? handle)
      (raise (exn:fail:raft (format "~a: the device resources on device ~a were released"
                                    who (device-resources-device r))
                            (current-continuation-marks)
                            'logic))
      handle))

(define (release-resources! r)
  (rr-resources-free (device-resources-handle r)))

(define spin-polls 16)
(define first-pause 1e-5)
(define longest-pause 1e-3)

;; A poll, never a blocking call: a blocked foreign call would stall every
;; Racket thread in the place, the collector included, and ignore breaks.
(define (resources-sync! r)
  (define handle (resources-handle 'resources-sync! r))
  (let poll ([polls 0] [pause 0.0])
    (unless (eq? 'ready (call/raft 'resources-sync! (lambda () (rr-resources-ready handle))))
      (sleep pause)
      (poll (add1 polls)
            (cond
              [(< polls spin-polls) 0.0]
              [(zero? pause) first-pause]
              [else (min longest-pause (* 2 pause))])))))

;; Not a parameter: a new thread must start without its parent's resources,
;; or the two would share a stream.
(define defaults (make-thread-cell #hasheqv()))

(define (current-device-resources [device 0])
  (define table (thread-cell-ref defaults))
  (define cached (hash-ref table device #f))
  (if (and cached (not (released? (device-resources-handle cached))))
      cached
      (let ([fresh (open-resources 'current-device-resources device)])
        (thread-cell-set! defaults (hash-set table device fresh))
        fresh)))

(define (memory-resource-kind [device 0])
  (call/raft 'memory-resource-kind (lambda () (rr-memory-resource-kind device))))

(begin-for-syntax
  (define-syntax-class resources-binding
    #:description "a [name resources-expr] binding"
    (pattern [name:id init:expr])))

(define-syntax-parse-rule (with-device-resources (b:resources-binding ...) body:expr ...+)
  #:fail-when (check-duplicate-identifier (syntax->list #'(b.name ...)))
  "duplicate binding name"
  (with-release ([b.name b.init release-resources!] ...) body ...))
