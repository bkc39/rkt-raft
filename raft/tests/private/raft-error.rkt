#lang racket/base

(require (only-in rackunit check-equal? check-exn check-pred check-regexp-match)
         (only-in "../../private/error.rkt" exn:fail:raft-kind exn:fail:raft?))

(provide check-raft-error)

(define (check-raft-error kind expected thunk)
  (check-exn (lambda (e)
               (check-pred exn:fail:raft? e)
               (check-equal? (exn:fail:raft-kind e) kind)
               (if (string? expected)
                   (check-equal? (exn-message e) expected)
                   (check-regexp-match expected (exn-message e)))
               #t)
             thunk))
