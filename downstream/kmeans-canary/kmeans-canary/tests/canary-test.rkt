#lang racket/base

(require (only-in ffi/unsafe _int32 memcpy ptr-set!)
         (only-in racket/flonum make-flvector)
         (only-in racket/list remove-duplicates)
         (only-in rackunit check-equal? check-true)
         (only-in raft
                  contiguous
                  device-matrix->list*
                  device-resources
                  device-vector->list
                  dtype
                  flvector->device-vector
                  layout
                  list*->device-matrix
                  shape
                  with-device-resources)
         (only-in raft/tests/private/gpu test-gpu)
         (only-in raft/tests/private/raft-error check-raft-error)
         (only-in raft/unsafe raft-abi-pointer)
         (only-in "../main.rkt" blobs kmeans-fit kmeans-predict)
         (only-in "../private/native.rkt" call/kc kc-check-abi))

(define (same-partition? a b)
  (define pairs (remove-duplicates (map cons a b)))
  (and (= (length pairs) (length (remove-duplicates a)))
       (= (length pairs) (length (remove-duplicates b)))))

(define (close? a b [tolerance 1e-4])
  (<= (abs (- a b)) (* tolerance (max 1.0 (abs b)))))

(test-gpu "blobs makes labelled data in the dtype and layout asked for"
  (define-values (X y) (blobs 40 3 #:centers 4 #:seed 3 #:dtype 'float64 #:layout 'col-major))
  (check-equal? (list (shape X) (dtype X) (layout X)) '((40 3) float64 col-major))
  (check-equal? (list (shape y) (dtype y)) '((40) int32))
  (check-equal? (sort (remove-duplicates (device-vector->list y)) <) '(0 1 2 3)))

(test-gpu "blobs is reproducible from its seed"
  (define-values (a _a) (blobs 20 2 #:seed 11))
  (define-values (b _b) (blobs 20 2 #:seed 11))
  (check-equal? (device-matrix->list* a) (device-matrix->list* b)))

(test-gpu "kmeans-fit and kmeans-predict recover well-separated blobs"
  (define-values (X truth) (blobs 300 5 #:centers 4 #:cluster-std 0.5 #:seed 7))
  (define-values (centroids inertia n-iter) (kmeans-fit X #:n-clusters 4 #:seed 42))
  (check-equal? (list (shape centroids) (dtype centroids)) '((4 5) float32))
  (check-true (and (> inertia 0) (>= n-iter 1)))
  (define-values (labels score) (kmeans-predict centroids X))
  (check-true (close? score inertia 1e-3))
  (check-true (same-partition? (device-vector->list labels) (device-vector->list truth))))

(test-gpu "every init method fits"
  (define-values (X _) (blobs 200 2 #:centers 3 #:cluster-std 0.5 #:seed 5))
  (for ([init (in-list '(k-means++ scalable-k-means++ random))])
    (define-values (centroids inertia _n-iter) (kmeans-fit X #:n-clusters 3 #:init init #:seed 1))
    (check-equal? (shape centroids) '(3 2) (format "~a" init))
    (check-true (> inertia 0) (format "~a" init)))
  (define start (list*->device-matrix '((0 0) (1 1) (2 2)) #:dtype 'float32))
  (define-values (centroids _inertia _n-iter) (kmeans-fit X #:init start))
  (check-equal? (shape centroids) '(3 2))
  (check-equal? (device-matrix->list* start) '((0.0 0.0) (1.0 1.0) (2.0 2.0)) "init is not written"))

(test-gpu "unit sample weights fit as no weights do"
  (define-values (X _) (blobs 100 2 #:centers 2 #:seed 9 #:dtype 'float64))
  (define ones (flvector->device-vector (make-flvector 100 1.0)))
  (define-values (_c plain _n) (kmeans-fit X #:n-clusters 2 #:seed 4 #:init 'k-means++))
  (define-values (_d weighted _m)
    (kmeans-fit X #:n-clusters 2 #:seed 4 #:init 'k-means++ #:sample-weight ones))
  (check-true (close? weighted plain)))

(test-gpu "the canary runs on resources other than the default"
  (with-device-resources ([r (device-resources)])
    (define-values (X _) (blobs 60 2 #:centers 2 #:seed 2 #:resources r))
    (define-values (centroids _inertia _n) (kmeans-fit X #:n-clusters 2 #:resources r))
    (define-values (labels _s) (kmeans-predict centroids X #:resources r))
    (check-equal? (shape labels) '(60))))

(test-gpu "refusals raise exn:fail:raft naming the procedure and the argument"
  (define ints (list*->device-matrix '((1 2) (3 4) (5 6)) #:dtype 'int32))
  (check-raft-error 'logic
                    "kmeans-fit: X: expected float32 or float64, got int32"
                    (lambda () (kmeans-fit ints #:n-clusters 2)))
  (define-values (X _) (blobs 10 2 #:seed 1))
  (check-raft-error 'logic
                    "kmeans-fit: X: expected row-major, got col-major 10x2"
                    (lambda () (kmeans-fit (contiguous X #:layout 'col-major) #:n-clusters 2)))
  (check-raft-error 'logic
                    "kmeans-fit: X: 10 samples are fewer than the 11 clusters"
                    (lambda () (kmeans-fit X #:n-clusters 11)))
  (check-raft-error 'logic "kmeans-fit: unknown init code -1" (lambda () (kmeans-fit X #:init 'bogus)))
  (define wide (list*->device-matrix '((0 0 0)) #:dtype 'float32))
  (check-raft-error 'logic
                    "kmeans-predict: X: expected 3 columns, got 2"
                    (lambda () (kmeans-predict wide X))))

(test-gpu "the canary refuses a libraftrkt built against other headers"
  (define forged (make-bytes 56))
  (memcpy forged (raft-abi-pointer) 56)
  (ptr-set! forged _int32 2 10)
  (check-raft-error
   'logic
   "kmeans-canary: RAFT: built against 26.08.00, but libraftrkt has 26.10.00; build both against the same rapids package set"
   (lambda () (call/kc 'kmeans-canary (lambda () (kc-check-abi forged)))))
  (check-equal? (call-with-values (lambda ()
                                    (call/kc 'kmeans-canary (lambda () (kc-check-abi (raft-abi-pointer)))))
                                  list)
                '()))

