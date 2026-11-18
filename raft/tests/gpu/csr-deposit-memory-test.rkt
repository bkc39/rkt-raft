#lang racket/base

(require (only-in rackunit check-equal?)
         (only-in "../../main.rkt" current-device-resources)
         (only-in "../../private/dtype.rkt" dtype->code)
         (only-in "../../unsafe.rkt"
                  deposit
                  deposit->device-csr-matrix
                  with-array-views
                  with-deposits)
         (only-in "../private/collect.rkt" drain-finalizers!)
         (only-in "../private/deposits.rkt"
                  counters
                  counts
                  counts-buffers
                  counts-failures
                  counts-owners
                  settles-to)
         (only-in "../private/probe.rkt" call/probe probe-deposit-csr probe-pool-used test-pools))

(define (cycle!)
  (define r (current-device-resources))
  (define d (deposit #:resources r))
  (with-deposits ([out d])
                 (with-array-views #:resources [h r] ()
                   (call/probe 'probe-deposit-csr
                               (lambda ()
                                 (probe-deposit-csr h
                                                    out
                                                    (dtype->code 'int32)
                                                    (dtype->code 'float32)
                                                    '(0 2 2 3)
                                                    '(3 0 1)
                                                    '(0.5 1.0 2.0)
                                                    0)))))
  (deposit->device-csr-matrix d #:shape '(3 4)))

(define cycles 1000)

(test-pools "law 17: memory stays flat over 1,000 cycles of CSR fill, adoption and drop"
  (for ([_ (in-range 10)])
    (cycle!))
  (drain-finalizers!)
  (define baseline (probe-pool-used 0))
  (define before (counters))
  (for ([_ (in-range cycles)])
    (cycle!))
  (define expected (counts cycles cycles cycles (* 3 cycles) 0))
  (define settled (settles-to before expected))
  (drain-finalizers!)
  (define used (probe-pool-used 0))
  (printf
   "memory: ~a CSR deposits; pool used ~a bytes before, ~a after; ~a owners released, ~a buffers freed; ~a release failures\n"
   cycles
   baseline
   used
   (counts-owners settled)
   (counts-buffers settled)
   (counts-failures settled))
  (check-equal? settled expected)
  (check-equal? used baseline))
