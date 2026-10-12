#lang racket/base

(require (only-in ffi/unsafe/atomic call-as-atomic)
         (only-in ffi/unsafe/os-async-channel make-os-async-channel os-async-channel-put)
         (only-in ffi/unsafe/os-thread call-in-os-thread))

(provide call-in-os-thread/deferring-breaks
         calls-in-flight) ;; noqa

(define in-flight (box 0))

(define (count-calls! delta)
  (define n (unbox in-flight))
  (unless (box-cas! in-flight n (+ n delta))
    (count-calls! delta)))

(define (call-in-os-thread/deferring-breaks call)
  (define channel (make-os-async-channel))
  ;; Counting after the fork, atomically, leaves no count that no call will settle.
  (call-as-atomic (lambda ()
                    (call-in-os-thread (lambda ()
                                         (define outcome (call))
                                         (count-calls! -1)
                                         (os-async-channel-put channel outcome)))
                    (count-calls! 1)))
  (define outcome (parameterize-break #f (sync channel)))
  ;; Leaving the #f extent does not raise a break queued during the wait; this does.
  (parameterize-break (break-enabled) (void))
  outcome)

(define (calls-in-flight)
  (unbox in-flight))
