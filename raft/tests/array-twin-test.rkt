#lang racket/base

(require (only-in racket/match match-define)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path
         (only-in rackunit check-equal?)
         (only-in "../main.rkt"
                  contiguous
                  contiguous?
                  device-matrix
                  device-matrix->list*
                  device-vector->list
                  dtype
                  layout
                  list*->device-matrix
                  list->device-vector
                  strides)
         (only-in "private/arrays.rkt" storage)
         (only-in "private/python-env.rkt" run-twin test-twin))

(define-runtime-path twin "python/arrays.py")

(define all-dtypes '(float32 float64 int32 int64))
(define orders (hasheq 'row-major "C" 'col-major "F"))

(define data '((1.5 -2.25 3.0 0.1) (1e10 -0.5 7.0 123456.789) (8.0 -9.5 10.25 1e-3)))
(define integer-data '((1 -2 3 4) (2147483647 -2147483648 0 7) (8 9 10 11)))

(define (data-for d)
  (if (memq d '(int32 int64)) integer-data data))

(define (other order)
  (if (eq? order 'row-major) 'col-major 'row-major))

(define pairs
  (for*/list ([d (in-list all-dtypes)]
              [order (in-list '(row-major col-major))])
    (list d order)))

(define (case-for pair)
  (match-define (list d order) pair)
  (hasheq 'data (data-for d) 'dtype (symbol->string d) 'order (hash-ref orders order)))

(define (results cases)
  (hash-ref (run-twin twin (hasheq 'cases cases)) 'results))

(define (matrix-for pair)
  (match-define (list d order) pair)
  (list*->device-matrix (data-for d) #:dtype d #:layout order))

(test-twin "round trips match pylibraft's device_ndarray in every dtype and layout"
  (for ([pair (in-list pairs)]
        [twin (in-list (results (map case-for pairs)))])
    (define m (matrix-for pair))
    (check-equal? (device-matrix->list* m) (hash-ref twin 'values) (format "~a" pair))
    (check-equal? (strides m) (hash-ref twin 'strides) (format "strides ~a" pair))
    (check-equal? (storage m) (hash-ref twin 'storage) (format "storage ~a" pair))))

(test-twin "contiguous matches np.asfortranarray and np.ascontiguousarray"
  (for ([pair (in-list pairs)]
        [twin (in-list (results (map case-for pairs)))])
    (match-define (list _ order) pair)
    (check-equal? (storage (contiguous (matrix-for pair) #:layout (other order)))
                  (hash-ref twin 'relaid)
                  (format "~a" pair))))

(test-twin "strides are NumPy's, contiguous? is NumPy's flags, and layout is pylibraft's c_contiguous"
  (define shaped
    (for*/list ([shape (in-list '((2 3) (0 3) (3 0) (1 1) (0 0) (1 5) (5 1)))]
                [order (in-list '(row-major col-major))])
      (list shape order)))
  (define cases
    (for/list ([s (in-list shaped)])
      (match-define (list shape order) s)
      (hasheq 'empty #t 'shape shape 'dtype "float32" 'order (hash-ref orders order))))
  (for ([s (in-list shaped)]
        [twin (in-list (results cases))])
    (match-define (list (list rows cols) order) s)
    (define m (device-matrix rows cols #:layout order))
    (check-equal? (strides m) (hash-ref twin 'strides) (format "~a" s))
    (check-equal? (eq? (layout m) 'row-major) (hash-ref twin 'c_contiguous) (format "layout ~a" s))
    (check-equal? (contiguous? m) (hash-ref twin 'numpy_c) (format "C ~a" s))
    (check-equal? (contiguous? m #:layout 'col-major) (hash-ref twin 'numpy_f) (format "F ~a" s))))

(test-twin "the inferred dtype is NumPy's, and integer dtypes truncate as NumPy's do"
  (define cases
    (list (hasheq 'data '(1 2 3) 'dtype #f 'order "C")
          (hasheq 'data '(1 2.5) 'dtype #f 'order "C")
          (hasheq 'data '((1 2) (3 4)) 'dtype #f 'order "C")
          (hasheq 'data '(1.7 -1.7 2.5 -2.5) 'dtype "int64" 'order "C")))
  (match-define (list ints mixed nested truncated) (results cases))
  (define (twin-dtype result)
    (string->symbol (hash-ref result 'dtype)))
  (check-equal? (dtype (list->device-vector '(1 2 3))) (twin-dtype ints))
  (check-equal? (dtype (list->device-vector '(1 2.5))) (twin-dtype mixed))
  (check-equal? (dtype (list*->device-matrix '((1 2) (3 4)))) (twin-dtype nested))
  (check-equal? (device-vector->list (list->device-vector '(1.7 -1.7 2.5 -2.5) #:dtype 'int64))
                (hash-ref truncated 'values)))
