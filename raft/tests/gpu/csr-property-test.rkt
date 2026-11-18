#lang racket/base

(require (only-in racket/list append*)
         (only-in rackunit check-equal? check-true)
         (only-in "../../main.rkt"
                  csr-data
                  csr-indices
                  csr-indptr
                  device-csr-matrix
                  device-csr-matrix->list*
                  device-csr-matrix->triplets
                  device-vector->list
                  list*->device-csr-matrix
                  list->device-vector
                  nnz
                  shape
                  triplets->device-csr-matrix)
         (only-in "../private/gpu.rkt" test-gpu))

(define entries (vector 0 0.0 -0.0 1.5 -2.25 3 +nan.0))
(define stored (vector 0.0 -0.0 1.5 -2.25 3.0 +nan.0))

(define (seeded seed)
  (vector->pseudo-random-generator (vector seed 2 3 4 5 6)))

(define (pick state choices)
  (vector-ref choices (random (vector-length choices) state)))

(define (dense-cases n)
  (define state (seeded 1))
  (for/list ([_ (in-range n)])
    (define rows (random 7 state))
    (define cols (random 7 state))
    (for/list ([_ (in-range rows)])
      (for/list ([_ (in-range cols)])
        (pick state entries)))))

(define (as-flonums rows)
  (for/list ([row (in-list rows)])
    (for/list ([x (in-list row)])
      (if (zero? x)
          0.0
          (real->double-flonum x)))))

(define (parts m)
  (map device-vector->list (list (csr-indptr m) (csr-indices m) (csr-data m))))

(define cases (dense-cases 200))
(define dtype-pairs '((float32 int32) (float32 int64) (float64 int32) (float64 int64)))

(test-gpu "law 3: dense rows round-trip through a CSR matrix for every dtype pair"
  (for* ([D (in-list cases)]
         [pair (in-list dtype-pairs)])
    (define m (list*->device-csr-matrix D #:dtype (car pair) #:index-dtype (cadr pair)))
    (check-equal? (device-csr-matrix->list* m) (as-flonums D) (format "~s as ~a" D pair))))

(define (prefix-sums counts)
  (for/fold ([sums '(0)]
             #:result (reverse sums))
            ([n (in-list counts)])
    (cons (+ n (car sums)) sums)))

(define (ascending? xs)
  (or (null? xs) (null? (cdr xs)) (and (< (car xs) (cadr xs)) (ascending? (cdr xs)))))

(test-gpu "law 4: nnz counts the non-zero entries, columns ascend in each row, indptr sums the rows"
  (for ([D (in-list cases)])
    (define m (list*->device-csr-matrix D))
    (define counts
      (for/list ([row (in-list D)])
        (for/sum ([x (in-list row)]) (if (= x 0) 0 1))))
    (check-equal? (nnz m) (apply + counts))
    (define-values (indptr indices _data) (apply values (parts m)))
    (check-equal? indptr (prefix-sums counts))
    (for ([start (in-list indptr)]
          [end (in-list (cdr indptr))])
      (check-true (ascending? (for/list ([k (in-range start end)])
                                (list-ref indices k)))))))

(define (through-triplets m)
  (define-values (rows cols vals) (device-csr-matrix->triplets m))
  (triplets->device-csr-matrix rows cols vals #:shape (shape m)))

(test-gpu "law 5: triplets-> inverts ->triplets on canonical matrices"
  (for ([D (in-list cases)])
    (define m (list*->device-csr-matrix D #:dtype 'float32))
    (check-equal? (parts (through-triplets m)) (parts m))))

(define (random-csr state)
  (define rows (random 7 state))
  (define cols (add1 (random 6 state)))
  (define per-row
    (for/list ([_ (in-range rows)])
      (for/list ([_ (in-range (random 5 state))])
        (cons (random cols state) (pick state stored)))))
  (device-csr-matrix (list->device-vector (prefix-sums (map length per-row)) #:dtype 'int32)
                     (list->device-vector (map car (append* per-row)) #:dtype 'int32)
                     (list->device-vector (map cdr (append* per-row)) #:dtype 'float64)
                     #:shape (list rows cols)))

(test-gpu "law 5: triplets-> of ->triplets has the same dense form for repeats and unsorted rows"
  (define state (seeded 2))
  (for ([_ (in-range 200)])
    (define m (random-csr state))
    (check-equal? (device-csr-matrix->list* (through-triplets m)) (device-csr-matrix->list* m))))
