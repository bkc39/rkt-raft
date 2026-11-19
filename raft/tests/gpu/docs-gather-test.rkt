#lang racket/base

(require (only-in datasets load-iris)
         (only-in polars in-dataframe-columns series->list)
         (only-in racket/list index-of range remove-duplicates third)
         (only-in rackunit check-equal?)
         (only-in "../../main.rkt"
                  compare
                  device-matrix->list*
                  device-vector->list
                  gather
                  list*->device-matrix
                  list->device-vector
                  select
                  shape)
         (only-in "../private/gather.rkt" taken)
         (only-in "../private/gpu.rkt" test-gpu)
         (only-in "../private/raft-error.rkt" check-raft-error))

(define samples '((5.1 3.5 1.4 0.2) (4.9 3.0 1.4 0.2) (7.0 3.2 4.7 1.4) (6.4 3.2 4.5 1.5)))

(define (X)
  (list*->device-matrix samples #:dtype 'float32))

(define (float32-rows rows)
  (device-matrix->list* (list*->device-matrix rows #:dtype 'float32)))

(define (ints xs)
  (list->device-vector xs #:dtype 'int32))

(define (printed v)
  (format "~a" v))

(test-gpu "reference: gather"
  (define x (X))
  (define order (ints '(2 0 0)))
  (check-equal? (printed (gather x order))
                (string-append "#<device-matrix float32[3×4] row-major cuda:0\n"
                               " [[7.0 3.2 4.7 1.4]\n"
                               "  [5.1 3.5 1.4 0.2]\n"
                               "  [5.1 3.5 1.4 0.2]]>"))
  (check-equal? (device-vector->list (gather (list->device-vector '(10 20 30)) order)) '(30 10 10))
  (define by-petal (sort (range 4) < #:key (lambda (i) (third (list-ref samples i)))))
  (check-equal? by-petal '(0 1 3 2))
  (check-equal? (device-matrix->list* (gather x (ints by-petal)))
                (float32-rows (taken samples by-petal)))
  (define centroid-rows '((5.0 3.25 1.4 0.2) (6.7 3.2 4.6 1.45)))
  (define centroids (list*->device-matrix centroid-rows #:dtype 'float32))
  (check-equal? (device-matrix->list* (gather centroids (ints '(0 0 1 1))))
                (float32-rows (taken centroid-rows '(0 0 1 1))))
  (check-raft-error 'logic
                    "gather: indices: entry 1 is 4, outside [0, 4)"
                    (lambda () (gather x (ints '(1 4)))))
  (check-raft-error 'logic
                    "gather: indices: entry 0 is -1, outside [0, 4)"
                    (lambda () (gather x (ints '(-1))))))

(test-gpu "reference: select"
  (define x (X))
  (check-equal? (device-matrix->list* (select x (ints '(1 0 0 1))))
                (float32-rows (taken samples '(0 3))))
  (check-equal? (shape (select x (ints '(0 0 0 0)))) '(0 4))
  (define labels (ints '(0 -1 1 1)))
  (define clustered (compare labels '>= 0))
  (check-equal? (list (device-vector->list (select labels clustered)) (shape (select x clustered)))
                '((0 1 1) (3 4)))
  (define fold (ints '(0 1 0 1)))
  (define training (select x (compare fold '= 0)))
  (define held-out (select x fold))
  (check-equal? (device-matrix->list* training) (float32-rows (taken samples '(0 2))))
  (check-equal? (device-matrix->list* held-out) (float32-rows (taken samples '(1 3))))
  (check-raft-error 'logic
                    "select: mask: expected 4 elements, got 3"
                    (lambda () (select x (ints '(1 0 1))))))

(test-gpu "reference: compare"
  (define x (X))
  (define labels (ints '(0 -1 1 1)))
  (check-equal? (device-vector->list (compare labels '>= 0)) '(1 0 1 1))
  (check-equal? (device-matrix->list* (compare x '< 3.0)) '((0 0 1 1) (0 0 1 1) (0 0 0 1) (0 0 0 1)))
  (define petals (list->device-vector (map third samples) #:dtype 'float32))
  (check-equal? (device-matrix->list* (select x (compare petals '> 4.0)))
                (float32-rows (taken samples '(2 3))))
  (check-equal? (apply + (device-vector->list (compare labels '= 1))) 2)
  (check-equal? (apply + (device-vector->list (compare petals '> 4.0))) 2)
  (check-raft-error 'logic
                    "compare: 3000000000 does not fit int32"
                    (lambda () (compare labels '< 3000000000))))

(define measurements '("sepal-length" "sepal-width" "petal-length" "petal-width"))

(define (columns names)
  (for/list ([column (in-dataframe-columns (load-iris) #:columns names)])
    (series->list column)))

(test-gpu "arrays guide: choosing rows"
  (define rows (apply map list (columns measurements)))
  (define species (car (columns '("species"))))
  (define names (remove-duplicates species))
  (define labels (ints (map (lambda (s) (index-of names s)) species)))
  (define x (list*->device-matrix rows #:dtype 'float32))
  (define setosa (select x (compare labels '= 0)))
  (check-equal? (shape setosa) '(50 4))
  (check-equal? (device-matrix->list* setosa) (float32-rows (taken rows (range 50))))
  (define firsts (map (lambda (name) (index-of species name)) names))
  (check-equal? firsts '(0 50 100))
  (check-equal? (device-matrix->list* (gather x (ints firsts))) (float32-rows (taken rows firsts))))
