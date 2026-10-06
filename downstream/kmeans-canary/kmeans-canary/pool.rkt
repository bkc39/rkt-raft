#lang racket/base

(require (only-in "private/native.rkt" call/kc kc-current-is-async kc-pool-bytes kc-pool-reset-high))

(provide canary-current-is-async?
         canary-pool-bytes
         canary-pool-reset-high!)

(define (canary-current-is-async? [device 0])
  (call/kc 'canary-current-is-async? (lambda () (kc-current-is-async device))))

(define (canary-pool-bytes [device 0])
  (call/kc 'canary-pool-bytes (lambda () (kc-pool-bytes device))))

(define (canary-pool-reset-high! [device 0])
  (call/kc 'canary-pool-reset-high! (lambda () (kc-pool-reset-high device))))
