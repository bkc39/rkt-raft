#lang racket/base

(require (only-in racket/list remove-duplicates)
         (only-in racket/port with-output-to-string)
         (only-in racket/system system*)
         (only-in rackunit check-equal? check-true)
         (only-in raft device-resources shape with-device-resources)
         (only-in raft/private/foreign/memory
                  buffer-drop-count
                  owner-release-count
                  release-failure-count)
         (only-in raft/tests/private/collect collect-until drain-finalizers!)
         (only-in raft/tests/private/probe test-pools)
         (only-in "../main.rkt" blobs cluster-members kmeans-fit kmeans-predict)
         (only-in "../pool.rkt" canary-device-memory canary-pool-bytes)
         (only-in "../private/native.rkt" kc-owner-drop-count kc-owner-stale-count))

(define fits 1000)
(define buffers-per-fit 2)
(define sample-every 100)

(define (fit-once X seed)
  (define-values (centroids _inertia _n-iter) (kmeans-fit X #:n-clusters 5 #:seed seed))
  (kmeans-predict centroids X)
  (void))

(define device-slack (* 256 1024 1024))

(define (other-processes)
  (define nvidia-smi (find-executable-path "nvidia-smi"))
  (if nvidia-smi
      (with-output-to-string
       (lambda ()
         (system* nvidia-smi "--query-compute-apps=pid,process_name,used_memory" "--format=csv")))
      "nvidia-smi is not on PATH"))

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
  (define floor-free (- (caddr baseline) device-slack))
  (define settled-free
    (if (>= lowest-free floor-free)
        lowest-free
        (caddr (pool-sample))))
  (check-true
   (>= settled-free floor-free)
   (format "device-wide free memory fell ~a bytes below the baseline (twice); other processes:\n~a"
           (- (caddr baseline) settled-free)
           (other-processes)))
  (check-equal? (map shape (list X truth)) '((2000 8) (2000)) "the data stayed live throughout"))

(define member-cycles 1000)

(test-pools "1,000 cluster-members cycles leave the pool flat and release every owner once"
  (define-values (X labels) (blobs 2000 8 #:centers 5 #:cluster-std 0.7 #:seed 3))
  (for ([_ (in-range 10)])
    (cluster-members X labels 1))
  (define kept
    (box (call-with-values (lambda ()
                             (with-device-resources ([r (device-resources)])
                               (cluster-members X labels 2 #:resources r)))
                           list)))
  (check-equal? (car (shape (car (unbox kept)))) (car (shape (cadr (unbox kept)))))
  (define stale (kc-owner-stale-count))
  (define failures (release-failure-count))
  (define baseline (pool-sample))
  (define drops (kc-owner-drop-count))
  (define releases (owner-release-count))
  (for ([i (in-range member-cycles)])
    (cluster-members X labels (modulo i 5)))
  (check-true (collect-until (lambda ()
                               (and (>= (owner-release-count) (+ releases member-cycles))
                                    (>= (kc-owner-drop-count) (+ drops member-cycles))))))
  (define after (pool-sample))
  (printf
   "memory: ~a cluster-members cycles; pool used ~a bytes before, ~a after; reserved ~a before, ~a after; ~a owners released, ~a dropped by the canary, ~a stale; ~a release failures\n"
   member-cycles
   (car baseline)
   (car after)
   (cadr baseline)
   (cadr after)
   (- (owner-release-count) releases)
   (- (kc-owner-drop-count) drops)
   (- (kc-owner-stale-count) stale)
   (- (release-failure-count) failures))
  (check-equal? (- (owner-release-count) releases) member-cycles)
  (check-equal? (- (kc-owner-drop-count) drops) member-cycles)
  (check-equal? (car after) (car baseline) "pool use returns to the baseline after a collection")
  (check-equal? (cadr after) (cadr baseline) "the pool reserves no more than after warm-up")
  (check-equal? (- (release-failure-count) failures) 0)
  (set-box! kept #f)
  (check-true (collect-until (lambda () (>= (kc-owner-drop-count) (+ drops member-cycles 1)))))
  (check-equal? (- (kc-owner-stale-count) stale)
                0
                "an owner whose resources went first finds its handle alive"))
