#lang racket/base

;; whole-module: define-runtime-path needs bindings only-in strips
(require racket/runtime-path
         (only-in rackunit check-equal?)
         (only-in "../main.rkt"
                  contiguous
                  device-matrix
                  device-matrix->list*
                  device-vector->list
                  dtype
                  list*->device-matrix
                  list->device-vector
                  strides)
         (only-in "private/arrays.rkt" storage)
         (only-in "private/python-env.rkt" run-twin test-twin))

(define-runtime-path twin "python/arrays.py")

(define all-dtypes '(float32 float64 int32 int64))
(define orders '((row-major . "C") (col-major . "F")))

(define data '((1.5 -2.25 3.0 0.1) (1e10 -0.5 7.0 123456.789) (8.0 -9.5 10.25 1e-3)))
(define integer-data '((1 -2 3 4) (2147483647 -2147483648 0 7) (8 9 10 11)))

(define (data-for d)
  (if (memq d '(int32 int64)) integer-data data))

(define (case-for d layout)
  (hasheq 'data (data-for d) 'dtype (symbol->string d) 'order (cdr (assq layout orders))))

(define (results cases)
  (hash-ref (run-twin twin (hasheq 'cases cases)) 'results))

(test-twin "round trips match pylibraft's device_ndarray in every dtype and layout"
  (define pairs
    (for*/list ([d (in-list all-dtypes)]
                [layout (in-list (map car orders))])
      (cons d layout)))
  (for ([pair (in-list pairs)]
        [twin (in-list (results (for/list ([p (in-list pairs)])
                                  (case-for (car p) (cdr p)))))])
    (define m (list*->device-matrix (data-for (car pair)) #:dtype (car pair) #:layout (cdr pair)))
    (check-equal? (device-matrix->list* m) (hash-ref twin 'values) (format "~a" pair))
    (check-equal? (strides m) (hash-ref twin 'strides) (format "strides ~a" pair))
    (check-equal? (storage m) (hash-ref twin 'storage) (format "storage ~a" pair))))

(test-twin "contiguous matches np.asfortranarray and np.ascontiguousarray"
  (define pairs
    (for*/list ([d (in-list all-dtypes)]
                [layout (in-list (map car orders))])
      (cons d layout)))
  (for ([pair (in-list pairs)]
        [twin (in-list (results (for/list ([p (in-list pairs)])
                                  (case-for (car p) (cdr p)))))])
    (define m (list*->device-matrix (data-for (car pair)) #:dtype (car pair) #:layout (cdr pair)))
    (define other (if (eq? (cdr pair) 'row-major) 'col-major 'row-major))
    (check-equal? (storage (contiguous m #:layout other))
                  (hash-ref twin 'relaid)
                  (format "~a" pair))))

(test-twin "strides are NumPy's byte strides over the itemsize, empty shapes included"
  (define shapes '((2 3) (0 3) (3 0) (1 1) (0 0) (1 5) (5 1)))
  (define cases
    (for*/list ([s (in-list shapes)]
                [order (in-list orders)])
      (hasheq 'empty #t 'shape s 'dtype "float32" 'order (cdr order))))
  (for ([c (in-list cases)]
        [twin (in-list (results cases))])
    (define layout (car (findf (lambda (o) (equal? (cdr o) (hash-ref c 'order))) orders)))
    (define m (device-matrix (car (hash-ref c 'shape)) (cadr (hash-ref c 'shape)) #:layout layout))
    (check-equal? (strides m) (hash-ref twin 'strides) (format "~a" c))))

(test-twin "the inferred dtype is NumPy's, and integer dtypes truncate as NumPy's do"
  (define cases
    (list (hasheq 'data '(1 2 3) 'dtype #f 'order "C")
          (hasheq 'data '(1 2.5) 'dtype #f 'order "C")
          (hasheq 'data '((1 2) (3 4)) 'dtype #f 'order "C")
          (hasheq 'data '(1.7 -1.7 2.5 -2.5) 'dtype "int64" 'order "C")))
  (define twins (results cases))
  (check-equal? (dtype (list->device-vector '(1 2 3))) (string->symbol (hash-ref (car twins) 'dtype)))
  (check-equal? (dtype (list->device-vector '(1 2.5)))
                (string->symbol (hash-ref (cadr twins) 'dtype)))
  (check-equal? (dtype (list*->device-matrix '((1 2) (3 4))))
                (string->symbol (hash-ref (caddr twins) 'dtype)))
  (check-equal? (device-vector->list (list->device-vector '(1.7 -1.7 2.5 -2.5) #:dtype 'int64))
                (hash-ref (cadddr twins) 'values)))
