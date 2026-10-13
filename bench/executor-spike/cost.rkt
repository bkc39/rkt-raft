#lang racket/base
(require (only-in kmeans-canary/private/native call/kc kc-noop kc-noop-job)
         (only-in racket/match match match-define)
         (only-in raft current-device-resources)
         (only-in raft/unsafe current-job-wait)
         (only-in threading ~>))

(define calls (string->number (or (getenv "CALLS") "20000")))
(define r (current-device-resources))

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

(define rows
  (list (list "bare _fun (kc_noop)" (lambda () (kc-noop 1)))
        (list "status-checker, OS thread per call (kc_noop)"
              (lambda () (call/kc 'noop (lambda () (kc-noop 1)))))
        (list "job, unsafe-poller + eventfd wakeup"
              (lambda () (parameterize ([current-job-wait 'poller]) (kc-noop-job 'noop r 1))))
        (list "job, spinning on rr_job_done (no scheduler sleep; breakdown only)"
              (lambda () (parameterize ([current-job-wait 'spin]) (kc-noop-job 'noop r 1))))
        (list "job, unsafe-fd->evt on the eventfd"
              (lambda () (parameterize ([current-job-wait 'fd-evt]) (kc-noop-job 'noop r 1))))))

(display "| kc_noop through | ns/call |\n|---|---:|\n")
(for ([row (in-list rows)])
  (match-define (list name call) row)
  (printf "| ~a | ~a |\n" name (round (ns-per-call call))))
