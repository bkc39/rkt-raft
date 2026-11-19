#lang racket/base

(require (only-in racket/format ~a)
         (only-in racket/list append* count drop-right first make-list range second third)
         (only-in racket/match match-define)
         (only-in rackunit check-equal? check-false check-true)
         (only-in "../../main.rkt"
                  csr-indices
                  csr-indptr
                  device-array?
                  device-csr-matrix
                  device-csr-matrix->list*
                  device-csr-matrix->triplets
                  device-csr-matrix?
                  device-matrix->list*
                  device-matrix?
                  device-vector->list
                  dtype
                  list*->device-csr-matrix
                  list*->device-matrix
                  list->device-vector
                  nnz
                  shape
                  triplets->device-csr-matrix)
         (only-in "../private/csr.rkt" parts triplets)
         (only-in "../private/gpu.rkt" test-gpu)
         (only-in "../private/raft-error.rkt" check-raft-error))

(define (G)
  (list*->device-csr-matrix '((0 1.5 0 0) (0 0 0 0) (2 0 0 -3)) #:dtype 'float32))

(define G-rows '((0.0 1.5 0.0 0.0) (0.0 0.0 0.0 0.0) (2.0 0.0 0.0 -3.0)))

(define (ints xs [element-type 'int32])
  (list->device-vector xs #:dtype element-type))

(test-gpu "reference: a CSR matrix prints its entries"
  (check-equal?
   (~a (G))
   "#<device-csr-matrix float32 [3×4] nnz=3 index=int32 cuda:0\n (0 1) 1.5\n (2 0) 2.0\n (2 3) -3.0>"))

(test-gpu "reference: shape and dtype answer for a CSR matrix"
  (check-equal? (shape (triplets->device-csr-matrix '(0 2) '(1 3) '(1.5 -3.0) #:shape '(3 4))) '(3 4))
  (check-equal? (dtype (list*->device-csr-matrix '((0 1.5)) #:dtype 'float32)) 'float32))

(test-gpu "reference: device-csr-matrix"
  (define indptr (ints '(0 2 2 3)))
  (define indices (ints '(3 0 1)))
  (define vals (list->device-vector '(0.5 1.0 2.0) #:dtype 'float32))
  (define A (device-csr-matrix indptr indices vals #:shape '(3 4)))
  (check-equal? (device-csr-matrix->list* A) '((1.0 0.0 0.0 0.5) (0.0 0.0 0.0 0.0) (0.0 2.0 0.0 0.0)))
  (check-true (eq? (csr-indices A) indices))
  (define (knn-graph neighbours distances n-fit)
    (match-define (list n k) (shape neighbours))
    (device-csr-matrix (ints (range 0 (add1 (* n k)) k))
                       (ints (append* (device-matrix->list* neighbours)))
                       (list->device-vector (append* (device-matrix->list* distances))
                                            #:dtype 'float32)
                       #:shape (list n n-fit)))
  (define knn
    (knn-graph (list*->device-matrix '((1 2) (0 2) (1 0)) #:dtype 'int32)
               (list*->device-matrix '((0.5 1.0) (0.5 0.75) (0.75 1.0)) #:dtype 'float32)
               3))
  (check-equal? (triplets knn) '((0 0 1 1 2 2) (1 2 0 2 1 0) (0.5 1.0 0.5 0.75 0.75 1.0)))
  (check-raft-error 'logic
                    "device-csr-matrix: indptr: entry 2 (2) is less than entry 1 (3)"
                    (lambda () (device-csr-matrix (ints '(0 3 2 3)) indices vals #:shape '(3 4))))
  (check-raft-error 'logic
                    "device-csr-matrix: indices: entry 2 is 7, outside [0, 4)"
                    (lambda () (device-csr-matrix indptr (ints '(3 0 7)) vals #:shape '(3 4))))
  (check-raft-error 'logic
                    "device-csr-matrix: indices: expected int32, as indptr is, got int64"
                    (lambda ()
                      (device-csr-matrix indptr (ints '(3 0 1) 'int64) vals #:shape '(3 4)))))

(test-gpu "reference: device-csr-matrix?"
  (define g (G))
  (check-true (device-csr-matrix? g))
  (check-false (device-csr-matrix? (list*->device-matrix '((1.0)))))
  (check-false (device-array? g))
  (define (->dense a)
    (cond
      [(device-csr-matrix? a) (device-csr-matrix->list* a)]
      [else (device-matrix->list* a)]))
  (check-equal? (->dense g) G-rows)
  (check-equal? (->dense (list*->device-matrix '((1.0 2.0)))) '((1.0 2.0)))
  (check-equal?
   (map shape (filter device-csr-matrix? (list (list*->device-matrix '((1.0))) g (csr-indptr g))))
   '((3 4))))

(test-gpu "reference: csr-indptr, csr-indices and csr-data"
  (define g (G))
  (define p (device-vector->list (csr-indptr g)))
  (check-equal? (parts g) '((0 1 1 3) (1 0 3) (1.5 2.0 -3.0)))
  (check-equal? (map - (cdr p) (drop-right p 1)) '(1 0 2))
  (check-equal? (dtype (csr-indices g)) 'int32)
  (check-equal? (dtype (csr-indptr (list*->device-csr-matrix '((1 0)) #:index-dtype 'int64))) 'int64))

(test-gpu "reference: nnz"
  (define g (G))
  (check-equal? (nnz g) 3)
  (check-equal? (nnz (list*->device-csr-matrix '((0 0) (0 0)))) 0)
  (check-equal? (/ (nnz g) (apply * (shape g))) 1/4)
  (check-equal?
   (nnz
    (device-csr-matrix (ints '(0 2)) (ints '(1 1)) (list->device-vector '(1.0 -1.0)) #:shape '(1 2)))
   2)
  (check-equal? (nnz (triplets->device-csr-matrix '(0 0) '(1 1) '(1.0 -1.0) #:shape '(1 2))) 1))

(test-gpu "reference: list*->device-csr-matrix"
  (check-equal? (device-csr-matrix->list* (G)) G-rows)
  (check-equal? (~a (list*->device-csr-matrix '((0 1) (2 0)) #:index-dtype 'int64))
                "#<device-csr-matrix float64 [2×2] nnz=2 index=int64 cuda:0\n (0 1) 1.0\n (1 0) 2.0>")
  (check-raft-error 'logic
                    "list*->device-csr-matrix: row 1 has 1 element, but row 0 has 2: '(3)"
                    (lambda () (list*->device-csr-matrix '((1 2) (3)))))
  (check-equal? (nnz (list*->device-csr-matrix (vector (vector 0 1.0) (vector 0 0)))) 1))

(test-gpu "reference: device-csr-matrix->list*"
  (check-equal? (device-csr-matrix->list* (device-csr-matrix (ints '(0 3))
                                                             (ints '(1 0 1))
                                                             (list->device-vector '(0.5 2.0 0.25))
                                                             #:shape '(1 2)))
                '((2.0 0.75)))
  (check-equal? (device-csr-matrix->list* (list*->device-csr-matrix '(() () ()))) '(() () ())))

(define edges '((0 1) (1 2) (2 0) (2 1)))

(define (adjacency)
  (triplets->device-csr-matrix (map first edges)
                               (map second edges)
                               (make-list (length edges) 1.0)
                               #:shape '(3 3)))

(test-gpu "reference: triplets->device-csr-matrix"
  (check-equal? (device-csr-matrix->list* (adjacency)) '((0.0 1.0 0.0) (0.0 0.0 1.0) (1.0 1.0 0.0)))
  (check-equal?
   (triplets (triplets->device-csr-matrix '(1 0 1) '(2 0 2) '(0.5 3.0 0.25) #:shape '(2 3)))
   '((0 1) (0 2) (3.0 0.75)))
  (check-raft-error 'logic
                    "triplets->device-csr-matrix: triplet 1 has row 3, outside [0, 3)"
                    (lambda ()
                      (triplets->device-csr-matrix '(0 3) '(0 1) '(1.0 2.0) #:shape '(3 3)))))

(test-gpu "reference: device-csr-matrix->triplets"
  (define g (G))
  (check-equal? (triplets g) '((0 2 2) (1 0 3) (1.5 2.0 -3.0)))
  (define-values (rs cs xs) (device-csr-matrix->triplets g))
  (check-equal? (device-csr-matrix->list* (triplets->device-csr-matrix rs cs xs #:shape (shape g)))
                G-rows)
  (define-values (sources _targets _weights) (device-csr-matrix->triplets (adjacency)))
  (check-equal? (for/list ([r (in-range 3)])
                  (count (lambda (s) (= s r)) sources))
                '(1 1 2)))

(test-gpu "guide: sparse matrices"
  (define graph-edges
    '((0 1 1.0) (1 2 1.0) (2 3 2.0) (3 4 1.0) (4 5 1.0) (5 0 1.0) (0 3 0.5) (0 1 1.0)))
  (define graph
    (triplets->device-csr-matrix (map first graph-edges)
                                 (map second graph-edges)
                                 (map third graph-edges)
                                 #:shape '(6 6)
                                 #:dtype 'float32))
  (check-equal?
   (~a graph)
   "#<device-csr-matrix float32 [6×6] nnz=7 index=int32 cuda:0\n (0 1) 2.0\n (0 3) 0.5\n (1 2) 1.0\n (2 3) 2.0\n (3 4) 1.0\n (4 5) 1.0\n (5 0) 1.0>")
  (define offsets (device-vector->list (csr-indptr graph)))
  (check-equal? (map - (cdr offsets) (drop-right offsets 1)) '(2 1 1 1 1 1))
  (check-equal? (first (device-csr-matrix->list* graph)) '(0.0 2.0 0.0 0.5 0.0 0.0))
  (check-equal? (nnz graph) 7))
