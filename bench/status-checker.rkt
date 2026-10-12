#lang racket/base
(require (only-in ffi/unsafe/atomic call-as-atomic)
         (only-in kmeans-canary/private/native call/kc kc-pool-bytes)
         (only-in racket/match match match-define)
         (only-in raft current-device-resources)
         (only-in threading ~>))

(define calls 20000)

(void (current-device-resources))

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

(define (call-as-atomic/status thunk)
  (call-as-atomic (lambda ()
                    (call-with-values thunk
                                      (lambda (status . results)
                                        (and (eqv? status 0) (apply values results)))))))

(define rows
  (list (list "the bare _fun" (lambda () (kc-pool-bytes 0)))
        (list "call-as-atomic (status-checker before #21)"
              (lambda () (call-as-atomic/status (lambda () (kc-pool-bytes 0)))))
        (list "status-checker (an OS thread per call)"
              (lambda () (call/kc 'canary-pool-bytes (lambda () (kc-pool-bytes 0)))))))

(display "| kc_pool_bytes through | ns/call |\n|---|---:|\n")
(for ([row (in-list rows)])
  (match-define (list name call) row)
  (printf "| ~a | ~a |\n" name (round (ns-per-call call))))
