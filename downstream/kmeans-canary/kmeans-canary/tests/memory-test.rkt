#lang racket/base

(require (only-in racket/list remove-duplicates)
         (only-in rackunit check-equal? check-true)
         (only-in raft shape)
         (only-in raft/private/foreign/memory buffer-drop-count release-failure-count)
         (only-in raft/tests/private/collect collect-until drain-finalizers!)
         (only-in raft/tests/private/probe test-pools)
         (only-in "../main.rkt" blobs kmeans-fit kmeans-predict)
         (only-in "../pool.rkt" canary-device-memory canary-pool-bytes))

(define fits 1000)
(define buffers-per-fit 2)
(define sample-every 100)

(define (fit-once X seed)
  (define-values (centroids _inertia _n-iter) (kmeans-fit X #:n-clusters 5 #:seed seed))
  (kmeans-predict centroids X)
  (void))

(define device-slack (* 256 1024 1024))

(define (pool-sample)
  (drain-finalizers!)
  (define-values (used _high reserved) (canary-pool-bytes))
  (define-values (free-bytes _total) (canary-device-memory))
  (list used reserved free-bytes))

(test-pools "1,000 fits leave device memory flat and the drop counters show every buffer freed"
  (define-values (X truth) (blobs 2000 8 #:centers 5 #:cluster-std 0.7 #:seed 3))
  (for ([seed (in-range 10)])
    (fit-once X seed))
  (define failures (release-failure-count))
  (define baseline (pool-sample))
  (define drops (buffer-drop-count))
  (define samples
    (for/list ([i (in-range fits)]
               #:when (begin
                        (fit-once X i)
                        (zero? (modulo (add1 i) sample-every))))
      (pool-sample)))
  (check-true (collect-until (lambda () (>= (buffer-drop-count) (+ drops (* buffers-per-fit fits))))))
  (define freed (- (buffer-drop-count) drops))
  (define used (map car samples))
  (define reserved (map cadr samples))
  (define frees (map caddr samples))
  (define lowest-free (apply min frees))
  (printf
   "memory: ~a fits; pool used ~a bytes before, ~a after each 100 (max ~a); reserved ~a before, ~a to ~a after; device free ~a before, lowest ~a after (cudaMemGetInfo, shared GPU); ~a buffers freed of ~a allocated; ~a release failures\n"
   fits
   (car baseline)
   (remove-duplicates used)
   (apply max used)
   (cadr baseline)
   (apply min reserved)
   (apply max reserved)
   (caddr baseline)
   lowest-free
   freed
   (* buffers-per-fit fits)
   (- (release-failure-count) failures))
  (check-equal? freed (* buffers-per-fit fits))
  (check-equal? (- (release-failure-count) failures) 0)
  (for ([u (in-list used)])
    (check-equal? u (car baseline) "pool use returns to the baseline after a collection"))
  (check-equal? (apply max reserved) (cadr baseline) "the pool reserves no more than after warm-up")
  (check-true (>= lowest-free (- (caddr baseline) device-slack))
              "no allocation outside the pool grew over the run (device-wide, within 256 MiB)")
  (check-equal? (map shape (list X truth)) '((2000 8) (2000)) "the data stayed live throughout"))
