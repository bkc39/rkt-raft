#lang racket/base

(require (only-in ffi/vector f32vector f32vector->list f64vector f64vector->list)
         (only-in math/array
                  array
                  array->list*
                  array-shape
                  array?
                  flarray
                  flarray-data
                  mutable-array?)
         (only-in math/matrix col-matrix? matrix matrix? row-matrix?)
         (only-in racket/flonum in-flvector)
         (only-in rackunit check-equal? check-false check-pred check-true)
         (only-in "../compat.rkt"
                  array->device-array
                  bytes->device-vector
                  device-array->array
                  device-array->list*
                  device-array->vector*
                  device-matrix->matrix
                  device-matrix->vector*
                  device-vector->bytes
                  device-vector->col-matrix
                  device-vector->f32vector
                  device-vector->f64vector
                  device-vector->list
                  device-vector->row-matrix
                  device-vector->vector
                  f32vector->device-vector
                  f64vector->device-vector
                  list*->device-array
                  list*->device-matrix
                  list->device-vector
                  matrix->device-matrix
                  matrix->device-vector
                  vector*->device-array
                  vector*->device-matrix
                  vector->device-vector)
         (only-in "../main.rkt"
                  contiguous?
                  device-matrix
                  device-matrix?
                  device-resources
                  device-vector
                  device-vector?
                  dtype
                  shape
                  with-device-resources)
         (only-in "private/arrays.rkt" storage)
         (only-in "private/gpu.rkt" test-gpu)
         (only-in "private/raft-error.rkt" check-raft-error))

(define (flvector->list v)
  (for/list ([x (in-flvector v)])
    x))

(test-gpu "vectors infer their dtype as lists do"
  (check-equal? (dtype (vector->device-vector #(1 2 3))) 'int64)
  (check-equal? (dtype (vector->device-vector #(1 2.5))) 'float64)
  (check-equal? (dtype (vector->device-vector #())) 'float64)
  (check-equal? (device-vector->vector (vector->device-vector #(1/2 3))) #(0.5 3.0))
  (check-equal? (dtype (vector*->device-matrix #(#(1 2) #(3 4)))) 'int64)
  (check-equal? (dtype (vector*->device-matrix #(#(1 2) #(3 4.0)))) 'float64)
  (check-equal? (device-vector->vector (vector->device-vector #(1.7 -1.7) #:dtype 'int32)) #(1 -1)))

(test-gpu "nested vectors come back as nested vectors, whatever the layout"
  (define m (vector*->device-matrix #(#(1 2 3) #(4 5 6)) #:layout 'col-major))
  (check-equal? (list (shape m) (contiguous? m #:layout 'col-major) (storage m))
                '((2 3) #t (1 4 2 5 3 6)))
  (check-equal? (device-matrix->vector* m) #(#(1 2 3) #(4 5 6)))
  (check-equal? (device-matrix->vector* (vector*->device-matrix #())) #())
  (check-equal? (shape (vector*->device-matrix #(#() #()))) '(2 0)))

(test-gpu "list*->device-array and vector*->device-array infer the rank from the nesting"
  (check-true (device-vector? (list*->device-array '(1 2 3))))
  (check-true (device-matrix? (list*->device-array '((1 2) (3 4)))))
  (check-equal? (shape (list*->device-array '())) '(0))
  (check-equal? (shape (list*->device-array '(() ()))) '(2 0))
  (check-true (device-vector? (vector*->device-array #(1.0 2.0))))
  (check-equal? (shape (vector*->device-array #(#(1 2 3)))) '(1 3))
  (check-equal? (device-array->list* (list*->device-array '((1 2) (3 4)) #:layout 'col-major))
                '((1 2) (3 4)))
  (check-equal? (device-array->list* (list*->device-array '(1 2))) '(1 2))
  (check-equal? (device-array->vector* (vector*->device-array #(#(1 2) #(3 4)))) #(#(1 2) #(3 4)))
  (check-equal? (device-array->vector* (vector*->device-array #(5 6))) #(5 6)))

(test-gpu "a ragged or mixed nesting raises, naming the row or element"
  (check-raft-error 'logic
                    "list*->device-array: row 1 has 1 element, but row 0 has 2: '(3)"
                    (lambda () (list*->device-array '((1 2) (3)))))
  (check-raft-error 'logic
                    "vector*->device-matrix: row 1 has 1 element, but row 0 has 2: '#(3)"
                    (lambda () (vector*->device-matrix #(#(1 2) #(3)))))
  (check-raft-error 'logic
                    "vector*->device-array: row 1 is not a vector, but row 0 is: 3"
                    (lambda () (vector*->device-array #(#(1 2) 3))))
  (check-raft-error 'logic
                    "list*->device-array: element 1 is a list, but element 0 is not: '(2 3)"
                    (lambda () (list*->device-array '(1 (2 3))))))

(test-gpu "ranks above 2, and rank 0, raise and point at the leg that brings them"
  (check-raft-error
   'logic
   "list*->device-array: rank 3 is not supported yet; rank 1 and 2 convert, and any rank arrives in leg 3"
   (lambda () (list*->device-array '(((1 2) (3 4))))))
  (check-raft-error
   'logic
   "vector*->device-array: rank 4 is not supported yet; rank 1 and 2 convert, and any rank arrives in leg 3"
   (lambda () (vector*->device-array #(#(#(#(1)))))))
  (check-raft-error
   'logic
   "array->device-array: rank 3 is not supported yet; rank 1 and 2 convert, and any rank arrives in leg 3"
   (lambda () (array->device-array (array #[#[#[1 2]]]))))
  (check-raft-error
   'logic
   "array->device-array: rank 0 is not supported yet; rank 1 and 2 convert, and any rank arrives in leg 3"
   (lambda () (array->device-array (array 5)))))

(test-gpu "complex and out-of-range values raise, naming the procedure"
  (check-raft-error 'logic
                    "vector->device-vector: cannot infer a dtype: 2+1i is not a real number"
                    (lambda () (vector->device-vector #(1 2+1i))))
  (check-raft-error 'logic
                    "matrix->device-matrix: cannot infer a dtype: 0+1i is not a real number"
                    (lambda () (matrix->device-matrix (matrix [[1 0+1i]]))))
  (check-raft-error 'logic
                    "matrix->device-matrix: 0+1i is not a real number"
                    (lambda () (matrix->device-matrix (matrix [[1 0+1i]]) #:dtype 'float32)))
  (check-raft-error 'logic
                    "vector->device-vector: 3000000000 does not fit int32"
                    (lambda () (vector->device-vector #(3000000000) #:dtype 'int32)))
  (check-raft-error 'logic
                    "array->device-array: +inf.0 is not a finite number"
                    (lambda () (array->device-array (flarray #[1.0 +inf.0]) #:dtype 'int32)))
  (check-raft-error 'logic
                    "f64vector->device-vector: +nan.0 is not a finite number"
                    (lambda () (f64vector->device-vector (f64vector +nan.0) #:dtype 'int64))))

(test-gpu "math/matrix matrices round-trip, exact integers as int64, exact rationals as floats"
  (define ints (matrix->device-matrix (matrix [[1 2] [3 4]])))
  (check-equal? (list (dtype ints) (shape ints)) '(int64 (2 2)))
  (define back (device-matrix->matrix ints))
  (check-true (matrix? back))
  (check-equal? (array->list* back) '((1 2) (3 4)))
  (define halves (matrix->device-matrix (matrix [[1/2 1/4] [3 4]])))
  (check-equal? (dtype halves) 'float64)
  (check-equal? (array->list* (device-matrix->matrix halves)) '((0.5 0.25) (3.0 4.0)))
  (define narrow (matrix->device-matrix (matrix [[1/3 2]]) #:dtype 'float32 #:layout 'col-major))
  (check-equal? (array->list* (device-matrix->matrix narrow)) '((0.3333333432674408 2.0))))

(test-gpu "row and column matrices become vectors, and vectors become either"
  (define v (matrix->device-vector (matrix [[1.0] [2.0] [3.0]])))
  (check-equal? (list (shape v) (dtype v)) '((3) float64))
  (check-equal? (device-vector->list (matrix->device-vector (matrix [[1 2 3]]))) '(1 2 3))
  (check-equal? (device-vector->list (matrix->device-vector (matrix [[7]]) #:dtype 'int32)) '(7))
  (define col (device-vector->col-matrix v))
  (check-true (col-matrix? col))
  (check-equal? (array-shape col) #(3 1))
  (define row (device-vector->row-matrix v))
  (check-true (row-matrix? row))
  (check-equal? (array->list* row) '((1.0 2.0 3.0)))
  (check-raft-error 'logic
                    "matrix->device-vector: a 2×2 matrix is neither a row nor a column matrix"
                    (lambda () (matrix->device-vector (matrix [[1 2] [3 4]])))))

(test-gpu "math/array arrays of rank 1 and 2 round-trip; floats come back as FlArrays"
  (define fl (array->device-array (flarray #[#[1.0 2.0] #[3.0 4.0]])))
  (check-equal? (list (dtype fl) (shape fl)) '(float64 (2 2)))
  (define back (device-array->array fl))
  (check-equal? (flvector->list (flarray-data back)) '(1.0 2.0 3.0 4.0))
  (define col-major (array->device-array (flarray #[#[1.0 2.0] #[3.0 4.0]]) #:layout 'col-major))
  (check-equal? (storage col-major) '(1.0 3.0 2.0 4.0))
  (check-equal? (flvector->list (flarray-data (device-array->array col-major))) '(1.0 2.0 3.0 4.0))
  (define ints (device-array->array (array->device-array (array #[5 6 7]))))
  (check-true (mutable-array? ints))
  (check-equal? (array->list* ints) '(5 6 7))
  (define empty (device-matrix->matrix (device-matrix 0 3)))
  (check-true (array? empty))
  (check-false (matrix? empty))
  (check-equal? (array-shape empty) #(0 3)))

(test-gpu "f32vectors and f64vectors cross in their own type and convert to others"
  (define v (f32vector->device-vector (f32vector 0.1 2.5)))
  (check-equal? (dtype v) 'float32)
  (check-equal? (f32vector->list (device-vector->f32vector v)) '(0.10000000149011612 2.5))
  (check-equal? (dtype (f64vector->device-vector (f64vector 0.1))) 'float64)
  (check-equal? (device-vector->list (f32vector->device-vector (f32vector 1.5 -2.5) #:dtype 'int32))
                '(1 -2))
  (check-equal? (f64vector->list (device-vector->f64vector (list->device-vector '(1 2)
                                                                                #:dtype 'int64)))
                '(1.0 2.0))
  (check-equal? (f32vector->list (device-vector->f32vector (list->device-vector '(0.1))))
                '(0.10000000149011612))
  (check-equal? (f64vector->list (device-vector->f64vector (f64vector->device-vector (f64vector))))
                '()))

(test-gpu "bytes cross as raw elements of the given dtype"
  (define v (bytes->device-vector (real->floating-point-bytes 1.5 4) #:dtype 'float32))
  (check-equal? (device-vector->list v) '(1.5))
  (define ints (list->device-vector '(1 -2) #:dtype 'int32))
  (check-equal? (device-vector->bytes ints)
                (bytes-append (integer->integer-bytes 1 4 #t) (integer->integer-bytes -2 4 #t)))
  (check-equal? (device-vector->bytes (bytes->device-vector #"" #:dtype 'int64)) #"")
  (check-raft-error
   'logic
   "bytes->device-vector: 6 bytes do not hold a whole number of 4-byte float32 elements"
   (lambda () (bytes->device-vector (make-bytes 6) #:dtype 'float32)))
  (check-raft-error
   'logic
   "bytes->device-vector: unsupported dtype float16; expected float32, float64, int32 or int64"
   (lambda () (bytes->device-vector (make-bytes 4) #:dtype 'float16))))

(test-gpu "released resources are refused, naming the procedure"
  (define released (with-device-resources ([r (device-resources)]) r))
  (check-raft-error 'logic
                    "vector->device-vector: the device resources on device 0 were released"
                    (lambda () (vector->device-vector #(1) #:resources released)))
  (check-raft-error 'logic
                    "array->device-array: the device resources on device 0 were released"
                    (lambda () (array->device-array (flarray #[1.0]) #:resources released)))
  (check-raft-error 'logic
                    "bytes->device-vector: the device resources on device 0 were released"
                    (lambda ()
                      (bytes->device-vector (make-bytes 8) #:dtype 'float64 #:resources released))))

(test-gpu "an empty device vector converts to every empty form"
  (define v (device-vector 0 #:dtype 'int32))
  (check-equal? (device-vector->vector v) #())
  (check-equal? (device-array->list* v) '())
  (check-equal? (array-shape (device-vector->col-matrix v)) #(0 1))
  (check-pred bytes? (device-vector->bytes v))
  (check-equal? (array-shape (device-matrix->matrix (list*->device-matrix '(() ())))) #(2 0))
  (check-equal? (f32vector->list (device-vector->f32vector v)) '()))

(test-gpu "a finite value that overflows a float type raises on every path, naming the procedure"
  (check-raft-error 'logic
                    "vector->device-vector: 1e+300 does not fit float32"
                    (lambda () (vector->device-vector #(1.0 1e300) #:dtype 'float32)))
  (check-raft-error 'logic
                    #rx"^vector->device-vector: 1000+[.]* does not fit float64$"
                    (lambda () (vector->device-vector (vector 1/2 (expt 10 400)))))
  (check-raft-error 'logic
                    "f64vector->device-vector: 1e+300 does not fit float32"
                    (lambda () (f64vector->device-vector (f64vector 1e300) #:dtype 'float32)))
  (check-raft-error 'logic
                    "array->device-array: 1e+300 does not fit float32"
                    (lambda () (array->device-array (flarray #[1.0 1e300]) #:dtype 'float32)))
  (check-raft-error
   'logic
   "array->device-array: 1e+300 does not fit float32"
   (lambda ()
     (array->device-array (flarray #[#[1.0] #[1e300]]) #:dtype 'float32 #:layout 'col-major)))
  (check-raft-error 'logic
                    "matrix->device-matrix: 1e+300 does not fit float32"
                    (lambda () (matrix->device-matrix (matrix [[1e300 2.0]]) #:dtype 'float32)))
  (check-raft-error 'logic
                    "vector*->device-matrix: 1e+300 does not fit float32"
                    (lambda () (vector*->device-matrix #(#(1e300)) #:dtype 'float32)))
  (check-raft-error 'logic
                    "device-vector->f32vector: 1e+300 does not fit float32"
                    (lambda () (device-vector->f32vector (vector->device-vector #(1e300)))))
  (check-equal? (f32vector->list (device-vector->f32vector (vector->device-vector #(+inf.0 -inf.0))))
                '(+inf.0 -inf.0))
  (check-equal? (device-vector->list (f64vector->device-vector (f64vector +inf.0) #:dtype 'float32))
                '(+inf.0)))
