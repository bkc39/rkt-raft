#lang racket/base

(require (only-in rackunit check-equal?)
         (only-in raft list->device-vector nnz)
         (only-in raft/tests/private/collect drain-finalizers!)
         (only-in raft/tests/private/deposits
                  counters
                  counts
                  counts-buffers
                  counts-failures
                  counts-owners
                  counts-probe-drops
                  settles-to)
         (only-in raft/tests/private/probe test-pools)
         (only-in "../main.rkt" cluster-graph)
         (only-in "../pool.rkt" canary-pool-bytes)
         (only-in "../private/native.rkt" kc-owner-drop-count kc-owner-stale-count))

(define cycles 1000)

(define (pool-used)
  (drain-finalizers!)
  (define-values (used _high _reserved) (canary-pool-bytes))
  used)

(define labels
  (list->device-vector (for/list ([i (in-range 200)])
                         (modulo i 7))
                       #:dtype 'int32))

(test-pools "law 21: 1,000 cluster-graph cycles leave the pool flat and drop every owner once"
  (for ([_ (in-range 10)])
    (cluster-graph labels 7))
  (define base-used (pool-used))
  (define before (counters #:drops kc-owner-drop-count))
  (define stale (kc-owner-stale-count))
  (for ([i (in-range cycles)])
    (check-equal? (nnz (cluster-graph labels 7 #:index-dtype (if (even? i) 'int32 'int64))) 200))
  (define expected (counts cycles cycles cycles (* 3 cycles) 0))
  (define settled (settles-to before expected #:drops kc-owner-drop-count))
  (define used (pool-used))
  (printf
   "memory: ~a cluster-graph cycles; pool used ~a bytes before, ~a after; ~a owners released, ~a dropped by the canary, ~a buffers freed, ~a stale; ~a release failures\n"
   cycles
   base-used
   used
   (counts-owners settled)
   (counts-probe-drops settled)
   (counts-buffers settled)
   (- (kc-owner-stale-count) stale)
   (counts-failures settled))
  (check-equal? settled expected)
  (check-equal? (- (kc-owner-stale-count) stale) 0)
  (check-equal? used base-used "pool use returns to the baseline after a collection"))
