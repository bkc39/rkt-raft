#lang racket/base

(require (only-in racket/match match-define)
         (only-in rackunit check-equal? check-true)
         (only-in raft list->device-vector nnz)
         (only-in raft/private/foreign/memory
                  buffer-drop-count
                  owner-release-count
                  release-failure-count)
         (only-in raft/tests/private/collect collect-until drain-finalizers!)
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
  (match-define (list drops releases buffers stale failures)
    (list (kc-owner-drop-count)
          (owner-release-count)
          (buffer-drop-count)
          (kc-owner-stale-count)
          (release-failure-count)))
  (for ([i (in-range cycles)])
    (check-equal? (nnz (cluster-graph labels 7 #:index-dtype (if (even? i) 'int32 'int64))) 200))
  (check-true (collect-until (lambda ()
                               (and (>= (owner-release-count) (+ releases cycles))
                                    (>= (kc-owner-drop-count) (+ drops cycles))
                                    (>= (buffer-drop-count) (+ buffers (* 3 cycles)))))))
  (define used (pool-used))
  (printf
   "memory: ~a cluster-graph cycles; pool used ~a bytes before, ~a after; ~a owners released, ~a dropped by the canary, ~a buffers freed, ~a stale; ~a release failures\n"
   cycles
   base-used
   used
   (- (owner-release-count) releases)
   (- (kc-owner-drop-count) drops)
   (- (buffer-drop-count) buffers)
   (- (kc-owner-stale-count) stale)
   (- (release-failure-count) failures))
  (check-equal? (- (owner-release-count) releases) cycles)
  (check-equal? (- (kc-owner-drop-count) drops) cycles)
  (check-equal? (- (buffer-drop-count) buffers) (* 3 cycles))
  (check-equal? (- (kc-owner-stale-count) stale) 0)
  (check-equal? (- (release-failure-count) failures) 0)
  (check-equal? used base-used "pool use returns to the baseline after a collection"))
