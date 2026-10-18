#lang racket/base

(require (only-in rackunit check-true)
         (only-in "../../main.rkt" current-device-resources)
         (only-in "../../private/job.rkt" executor-threads)
         (only-in "../private/collect.rkt" collect-until drain-finalizers!)
         (only-in "../private/probe.rkt" probe-thread-id-job test-probe))

(define short-lived-threads 500)
(define peak-allowance 100)

(test-probe "short-lived threads' default workers are reclaimed as they go"
  (drain-finalizers!)
  (define baseline (executor-threads))
  (define peak
    (for/fold ([peak baseline]) ([_ (in-range short-lived-threads)])
      (thread-wait (thread (lambda () (probe-thread-id-job 'demo (current-device-resources)))))
      (max peak (executor-threads))))
  (check-true (< (- peak baseline) peak-allowance)
              (format "~a workers over the baseline at the peak" (- peak baseline)))
  (check-true (collect-until (lambda () (= (executor-threads) baseline)))))
