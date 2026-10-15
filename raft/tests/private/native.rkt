#lang racket/base

(require (only-in racket/flonum make-flvector)
         (only-in "../../private/error.rkt" call/raft)
         (only-in "../../private/foreign/array.rkt" rr-buffer-alloc rr-copy-d2h rr-copy-h2d)
         (only-in "../../private/foreign/core.rkt" rr-resources-create))

(provide copy-in!
         copy-out
         new-buffer
         new-resources)

(define (new-resources [device 0])
  (call/raft 'new-resources (lambda () (rr-resources-create device))))

(define (new-buffer resources size)
  (call/raft 'new-buffer (lambda () (rr-buffer-alloc resources size))))

(define (copy-in! buffer host)
  (call/raft 'copy-in! (lambda () (rr-copy-h2d buffer host))))

(define (copy-out buffer n)
  (define host (make-flvector n))
  (call/raft 'copy-out (lambda () (rr-copy-d2h host buffer)))
  host)
