#lang racket/base

(require (only-in racket/format ~a)
         (only-in racket/list drop-right first make-list second third)
         (only-in rackunit check-equal? check-false check-true)
         (only-in "../../main.rkt"
                  csr-indices
                  csr-indptr
                  device-array?
                  device-csr-matrix
                  device-csr-matrix->list*
                  device-csr-matrix?
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
  (check-raft-error 'logic
                    "device-csr-matrix: indptr: entry 2 (2) is less than entry 1 (3)"
                    (lambda () (device-csr-matrix (ints '(0 3 2 3)) indices vals #:shape '(3 4)))))

(test-gpu "reference: device-csr-matrix?"
  (define g (G))
  (check-true (device-csr-matrix? g))
  (check-false (device-csr-matrix? (list*->device-matrix '((1.0)))))
  (check-false (device-array? g)))

(test-gpu "reference: csr-indptr, csr-indices and csr-data"
  (check-equal? (parts (G)) '((0 1 1 3) (1 0 3) (1.5 2.0 -3.0))))

(test-gpu "reference: nnz"
  (check-equal? (nnz (G)) 3)
  (check-equal? (nnz (triplets->device-csr-matrix '(0 0) '(1 1) '(1.0 -1.0) #:shape '(1 2))) 1))

(test-gpu "reference: list*->device-csr-matrix"
  (check-equal? (device-csr-matrix->list* (G)) G-rows)
  (check-equal? (~a (list*->device-csr-matrix '((0 1) (2 0)) #:index-dtype 'int64))
                "#<device-csr-matrix float64 [2×2] nnz=2 index=int64 cuda:0\n (0 1) 1.0\n (1 0) 2.0>")
  (check-raft-error 'logic
                    "list*->device-csr-matrix: row 1 has 1 element, but row 0 has 2: '(3)"
                    (lambda () (list*->device-csr-matrix '((1 2) (3))))))

(define edges '((0 1) (1 2) (2 0) (2 1)))

(test-gpu "reference: triplets->device-csr-matrix"
  (define adjacency
    (triplets->device-csr-matrix (map first edges)
                                 (map second edges)
                                 (make-list (length edges) 1.0)
                                 #:shape '(3 3)))
  (check-equal? (device-csr-matrix->list* adjacency) '((0.0 1.0 0.0) (0.0 0.0 1.0) (1.0 1.0 0.0)))
  (check-raft-error 'logic
                    "triplets->device-csr-matrix: triplet 1 has row 3, outside [0, 3)"
                    (lambda ()
                      (triplets->device-csr-matrix '(0 3) '(0 1) '(1.0 2.0) #:shape '(3 3)))))

(test-gpu "reference: device-csr-matrix->triplets"
  (check-equal? (triplets (G)) '((0 2 2) (1 0 3) (1.5 2.0 -3.0))))

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
