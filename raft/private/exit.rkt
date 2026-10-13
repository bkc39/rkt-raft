#lang racket/base

(require (only-in ffi/unsafe/custodian make-custodian-at-root register-custodian-shutdown)
         (only-in racket/math exact-floor)
         (only-in "exn.rkt" raise-raft)
         (only-in "foreign/job-api.rkt" rr-exit-drain rr-os-thread-id rr-os-thread-id/original))

(provide current-exit-wait)

(define-logger raft)

(define current-exit-wait
  (make-parameter 10
                  (lambda (v)
                    (if (and (real? v) (>= v 0))
                        v
                        (raise-raft 'current-exit-wait
                                    'logic
                                    "expected a non-negative real number of seconds, given ~e"
                                    v)))
                  'current-exit-wait))

(define (drain-at-exit _value)
  (define start (current-inexact-monotonic-milliseconds))
  (define-values (in-flight still-running) (rr-exit-drain))
  (define waited (exact-floor (- (current-inexact-monotonic-milliseconds) start)))
  (log-raft-debug "exit: jobs in flight: ~a; waited ~a ms" in-flight waited)
  (cond
    [(positive? still-running)
     (log-raft-warning "exit: jobs still running: ~a; exiting without native teardown"
                       still-running)]
    [else (void)]))

(define exit-hook ;; noqa
  (and (= (rr-os-thread-id) (rr-os-thread-id/original))
       (register-custodian-shutdown 'raft drain-at-exit (make-custodian-at-root) #:at-exit? #t)))
