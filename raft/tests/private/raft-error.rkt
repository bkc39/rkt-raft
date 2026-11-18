#lang racket/base

(require (only-in racket/match match)
         (only-in rackunit check-equal? check-exn check-pred check-regexp-match)
         (only-in "../../private/exn.rkt" exn:fail:raft exn:fail:raft-kind exn:fail:raft?))

(provide check-raft-error
         (struct-out exn:fail:canary)
         raised-and-logged)

(struct exn:fail:canary exn:fail:raft ())

(define (check-raft-error kind expected thunk #:exn [exn? exn:fail:raft?])
  (check-exn (lambda (e)
               (check-pred exn? e)
               (check-pred exn:fail:raft? e)
               (check-equal? (exn:fail:raft-kind e) kind)
               (if (string? expected)
                   (check-equal? (exn-message e) expected)
                   (check-regexp-match expected (exn-message e)))
               #t)
             thunk))

(define (drain receiver)
  (match (sync/timeout 0 receiver)
    [#f '()]
    [(vector level message _ topic) (cons (list level topic message) (drain receiver))]))

(define (raised-and-logged thunk)
  (define receiver (make-log-receiver (current-logger) 'debug 'raft))
  (define e
    (with-handlers ([exn:fail:raft? values])
      (thunk)))
  (list (exn-message e) (drain receiver)))
