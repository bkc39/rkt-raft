#lang racket/base
(require (only-in kmeans-canary/private/native call/kc kc-noop kc-noop-job)
         (only-in racket/match match match-define)
         (only-in raft current-device-resources)
         (only-in threading ~>))

(define calls 20000)

(define (milliseconds-for call)
  (collect-garbage 'minor)
  (define start (current-inexact-monotonic-milliseconds))
  (for ([_ (in-range calls)])
    (call))
  (- (current-inexact-monotonic-milliseconds) start))

(define (median-of-five runs)
  (match (sort runs <)
    [(list _ _ median _ _) median]))

(define (ns-per-call call)
  (call)
  (~> (for/list ([_ (in-range 5)])
        (milliseconds-for call))
      median-of-five
      (* 1e6)
      (/ calls)))

(define r (current-device-resources))

(define rows
  (list (list "the bare _fun" (lambda () (kc-noop 1)))
        (list "status-checker (call-as-atomic)" (lambda () (call/kc 'noop (lambda () (kc-noop 1)))))
        (list "a job (kc_noop_job, unsafe-poller)" (lambda () (kc-noop-job 'noop r 1)))))

(display "| kc_noop through | ns/call |\n|---|---:|\n")
(for ([row (in-list rows)])
  (match-define (list name call) row)
  (printf "| ~a | ~a |\n" name (round (ns-per-call call))))
