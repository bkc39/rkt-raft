#lang racket/base

(require (only-in ffi/unsafe/atomic call-as-atomic)
         (only-in ffi/unsafe/os-async-channel make-os-async-channel os-async-channel-put)
         (only-in ffi/unsafe/os-thread call-in-os-thread))

(provide call-in-os-thread/deferring-breaks
         calls-in-flight) ;; noqa

(define in-flight (box 0))
(define exit-waiters (box 0))
(define call-settled (make-os-async-channel))

(define (box-add! b delta)
  (define n (unbox b))
  (if (box-cas! b n (+ n delta))
      (memory-order-release)
      (box-add! b delta)))

(define (settle-call!)
  (box-add! in-flight -1)
  (when (positive? (unbox exit-waiters))
    (os-async-channel-put call-settled #t)))

(define (wait-for-calls-in-flight _)
  (box-add! exit-waiters 1)
  (let loop ()
    (unless (zero? (unbox in-flight))
      (sync call-settled)
      (loop)))
  (box-add! exit-waiters -1))

(void (plumber-add-flush! (current-plumber) wait-for-calls-in-flight))

(define (call-in-os-thread/deferring-breaks call)
  (define channel (make-os-async-channel))
  ;; Counting after the fork, atomically, leaves no count that no call will settle.
  (call-as-atomic (lambda ()
                    (call-in-os-thread (lambda ()
                                         (define outcome (call))
                                         (settle-call!)
                                         (os-async-channel-put channel outcome)))
                    (box-add! in-flight 1)))
  (define outcome (parameterize-break #f (sync channel)))
  ;; Leaving the #f extent does not raise a break queued during the wait; this does.
  (parameterize-break (break-enabled) (void))
  outcome)

(define (calls-in-flight)
  (unbox in-flight))
