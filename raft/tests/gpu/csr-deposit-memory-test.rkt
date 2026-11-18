#lang racket/base

(require (only-in rackunit check-equal?)
         (only-in "../../unsafe.rkt" deposit->device-csr-matrix)
         (only-in "../private/collect.rkt" drain-finalizers!)
         (only-in "../private/deposits.rkt"
                  counters
                  counts
                  counts-buffers
                  counts-failures
                  counts-owners
                  csr-filled
                  settles-to)
         (only-in "../private/probe.rkt" probe-pool-used test-pools))

(define (cycle! two-phase?)
  (deposit->device-csr-matrix
   (csr-filled '(0 2 2 3) '(3 0 1) '(0.5 1.0 2.0) #:dtype 'float32 #:two-phase? two-phase?)
   #:shape '(3 4)))

(define cycles 1000)

(test-pools "law 17: memory stays flat over 1,000 cycles of CSR fill, adoption and drop, in both phases"
  (for ([i (in-range 10)])
    (cycle! (odd? i)))
  (drain-finalizers!)
  (define baseline (probe-pool-used 0))
  (define before (counters))
  (for ([i (in-range cycles)])
    (cycle! (odd? i)))
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
