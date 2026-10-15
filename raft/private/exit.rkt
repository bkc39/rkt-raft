#lang racket/base

(require (only-in ffi/unsafe/atomic call-as-atomic)
         (only-in ffi/unsafe/custodian make-custodian-at-root register-custodian-shutdown)
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
  (define-values (in-flight jobs releases) (rr-exit-drain))
  (define elapsed (- (current-inexact-monotonic-milliseconds) start))
  (log-raft-debug "exit: jobs in flight: ~a; waited ~a ms" in-flight (inexact->exact (floor elapsed)))
  (when (positive? (+ jobs releases))
    (log-raft-warning
     "exit: jobs still running: ~a; releases still running: ~a; exiting without native teardown"
     jobs
     releases)))

(when (= (call-as-atomic rr-os-thread-id) (rr-os-thread-id/original))
  (void (register-custodian-shutdown 'raft drain-at-exit (make-custodian-at-root) #:at-exit? #t)))
