#lang racket/base

(require (only-in ffi/vector
                  f32vector
                  f32vector->list
                  f32vector-length
                  f32vector-ref
                  f32vector-set!
                  f64vector
                  f64vector->list
                  f64vector-length
                  f64vector-ref
                  f64vector-set!
                  list->f64vector
                  make-f32vector
                  make-f64vector)
         (only-in json jsexpr->string)
         (only-in math/array
                  ::
                  array
                  array->list*
                  array-abs
                  array-all-max
                  array-all-sum
                  array-axis-sum
                  array-scale
                  array-shape
                  array-slice-ref
                  array-
                  build-array
                  flarray)
         (only-in math/matrix
                  col-matrix
                  identity-matrix
                  list*->matrix
                  make-matrix
                  matrix
                  matrix*
                  matrix-
                  matrix-determinant
                  matrix-inverse
                  matrix-norm
                  matrix-num-rows
                  matrix-scale
                  matrix-solve
                  matrix-stack
                  matrix-trace
                  matrix-transpose
                  matrix?
                  row-matrix)
         (only-in racket/file file->bytes make-temporary-file)
         (only-in racket/list first index-of last remove-duplicates take)
         (only-in racket/port port->lines)
         (only-in racket/string string-split)
         (only-in racket/vector vector-argmax vector-map vector-member vector-sort)
         (only-in rackunit check-equal? check-true)
         (only-in "../compat.rkt"
                  array->device-array
                  bytes->device-vector
                  device-array->array
                  device-array->list*
                  device-array->vector*
                  device-matrix->list*
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
                  matrix->device-matrix
                  matrix->device-vector
                  vector*->device-array
                  vector*->device-matrix
                  vector->device-vector)
         (only-in "../main.rkt" device-matrix? dtype layout shape strides)
         (only-in "private/gpu.rkt" test-gpu)
         (only-in "private/raft-error.rkt" check-raft-error))

(define (printed v)
  (format "~a" v))

(define (lines . parts)
  (apply string-append
         (for/list ([part (in-list parts)]
                    [i (in-naturals)])
           (if (zero? i)
               part
               (string-append "\n" part)))))

(define flowers (vector #("setosa" 5.1 3.5) #("versicolor" 7.0 3.2) #("virginica" 6.3 3.3)))

(test-gpu "compat reference: vector->device-vector"
  (check-equal? (printed (vector->device-vector #(3 1 4 1 5)))
                "#<device-vector int64[5] cuda:0 [3 1 4 1 5]>")
  (check-equal? (printed (vector->device-vector #(0.5 1.5 2.5) #:dtype 'float32))
                "#<device-vector float32[3] cuda:0 [0.5 1.5 2.5]>")
  (define weights
    (for/vector ([i (in-range 6)])
      (/ 1.0 (add1 i))))
  (check-equal?
   (printed (vector->device-vector weights #:dtype 'float32))
   "#<device-vector float32[6] cuda:0 [       1.0        0.5 0.33333334       0.25        0.2 0.16666667]>")
  (define lengths (vector-map (lambda (row) (vector-ref row 1)) flowers))
  (check-equal? (device-vector->list (vector->device-vector lengths)) '(5.1 7.0 6.3))
  (check-raft-error
   'logic
   "vector->device-vector: cannot infer a dtype: \"setosa\" is not a real number"
   (lambda () (vector->device-vector (vector-map (lambda (row) (vector-ref row 0)) flowers)))))

(test-gpu "compat reference: device-vector->vector"
  (check-equal? (device-vector->vector (vector->device-vector #(2 7 1 8))) #(2 7 1 8))
  (define labels (vector->device-vector #(0 2 1 2 2 0) #:dtype 'int32))
  (define counts (make-vector 3 0))
  (for ([label (in-vector (device-vector->vector labels))])
    (vector-set! counts label (add1 (vector-ref counts label))))
  (check-equal? counts #(2 1 3))
  (define scores (device-vector->vector (vector->device-vector #(0.2 0.9 0.4))))
  (define best (vector-argmax values scores))
  (check-equal? (list best (vector-member best scores)) '(0.9 1)))

(define grid
  (for/vector ([x (in-range 3)])
    (for/vector ([y (in-range 2)])
      (+ (* 0.5 x) y))))

(test-gpu "compat reference: vector*->device-matrix and device-matrix->vector*"
  (check-equal? (printed (vector*->device-matrix #(#(1 2 3) #(4 5 6))))
                (lines "#<device-matrix int64[2×3] row-major cuda:0" " [[1 2 3]" "  [4 5 6]]>"))
  (define G (vector*->device-matrix grid #:dtype 'float32 #:layout 'col-major))
  (check-equal? (list (shape G) (layout G) (strides G)) '((3 2) col-major (1 3)))
  (check-raft-error 'logic
                    "vector*->device-matrix: row 1 has 1 element, but row 0 has 2: '#(3.0)"
                    (lambda () (vector*->device-matrix #(#(1.0 2.0) #(3.0)))))
  (check-equal? (device-matrix->vector* (vector*->device-matrix #(#(1 2) #(3 4)))) #(#(1 2) #(3 4)))
  (define centroids (vector*->device-matrix #(#(5.0 3.4) #(6.6 3.0) #(5.9 2.8))))
  (check-equal? (vector-ref (device-matrix->vector* centroids) 1) #(6.6 3.0))
  (check-equal? (device-matrix->vector* G) #(#(0.0 1.0) #(0.5 1.5) #(1.0 2.0)))
  (check-equal? (vector-ref (vector-ref (device-array->vector* centroids) 2) 0) 5.9))

(test-gpu "compat reference: list*->device-array and vector*->device-array"
  (check-equal? (printed (list*->device-array '(1.0 2.0 3.0)))
                "#<device-vector float64[3] cuda:0 [1.0 2.0 3.0]>")
  (check-equal? (printed (list*->device-array '((1 2) (3 4))))
                (lines "#<device-matrix int64[2×2] row-major cuda:0" " [[1 2]" "  [3 4]]>"))
  (define (upload data)
    (list*->device-array data #:dtype 'float32))
  (check-equal? (map shape (list (upload '(0.5 1.5)) (upload '((0.5 1.5) (2.5 3.5) (4.5 5.5)))))
                '((2) (3 2)))
  (check-equal? (shape (list*->device-array '())) '(0))
  (check-raft-error
   'logic
   "list*->device-array: rank 3 is not supported yet; rank 1 and 2 convert, and any rank arrives in leg 3"
   (lambda () (list*->device-array '(((1 2) (3 4))))))
  (check-raft-error 'logic
                    "list*->device-array: element 1 is a list, but element 0 is not: '(2.0 3.0)"
                    (lambda () (list*->device-array '(1.0 (2.0 3.0)))))
  (check-equal? (printed (vector*->device-array #(1 2 3)))
                "#<device-vector int64[3] cuda:0 [1 2 3]>")
  (define saved (read (open-input-string "#(#(0.1 0.2) #(0.3 0.4) #(0.5 0.6))")))
  (check-equal? (shape (vector*->device-array saved #:dtype 'float32)) '(3 2))
  (check-raft-error 'logic
                    "vector*->device-array: row 1 is not a vector, but row 0 is: 3"
                    (lambda () (vector*->device-array (vector #(1 2) 3)))))

(test-gpu "compat reference: device-array->list* and device-array->vector*"
  (check-equal? (device-array->list* (list*->device-array '(1 2 3))) '(1 2 3))
  (check-equal? (device-array->list* (list*->device-array '((1 2) (3 4)) #:layout 'col-major))
                '((1 2) (3 4)))
  (define (results->json a)
    (jsexpr->string (hasheq 'shape (shape a) 'values (device-array->list* a))))
  (check-equal? (results->json (list*->device-array '((1 2) (3 4)) #:dtype 'int32))
                "{\"shape\":[2,2],\"values\":[[1,2],[3,4]]}")
  (check-equal? (results->json (vector->device-vector #(0.5 0.25)))
                "{\"shape\":[2],\"values\":[0.5,0.25]}")
  (define (total a)
    (define xs (device-array->list* a))
    (apply +
           (if (device-matrix? a)
               (apply append xs)
               xs)))
  (check-equal? (map total (list (list*->device-array '(1 2 3)) (list*->device-array '((1 2) (3 4)))))
                '(6 10))
  (check-equal? (device-array->vector* (vector*->device-array #(1 2 3))) #(1 2 3))
  (check-equal? (device-array->vector* (vector*->device-array #(#(1 2) #(3 4)))) #(#(1 2) #(3 4)))
  (define distances (vector->device-vector #(2.5 0.5 1.5)))
  (check-equal? (vector-sort (device-array->vector* distances) <) #(0.5 1.5 2.5))
  (check-equal? (device-vector->list distances) '(2.5 0.5 1.5)))

(test-gpu "compat reference: f32vectors and f64vectors"
  (check-equal? (printed (f32vector->device-vector (f32vector 0.5 1.5 2.5)))
                "#<device-vector float32[3] cuda:0 [0.5 1.5 2.5]>")
  (define samples (make-f32vector 4 0.25))
  (f32vector-set! samples 2 -0.75)
  (define on-gpu (f32vector->device-vector samples))
  (check-equal? (list (dtype on-gpu) (device-vector->list on-gpu)) '(float32 (0.25 0.25 -0.75 0.25)))
  (check-equal? (device-vector->list (f32vector->device-vector (f32vector 0.1 2.7) #:dtype 'float64))
                '(0.10000000149011612 2.700000047683716))
  (check-equal? (device-vector->list (f32vector->device-vector (f32vector 0.1 2.7) #:dtype 'int32))
                '(0 2))
  (check-equal? (printed (f64vector->device-vector (f64vector 1.0 2.0 3.0)))
                "#<device-vector float64[3] cuda:0 [1.0 2.0 3.0]>")
  (define readings (list->f64vector '(21.5 21.75 22.0 22.5)))
  (check-equal? (printed (f64vector->device-vector readings #:dtype 'float32))
                "#<device-vector float32[4] cuda:0 [ 21.5 21.75  22.0  22.5]>")
  (check-equal? (dtype (f64vector->device-vector (f64vector 3.0 0.0 12.0) #:dtype 'int64)) 'int64)
  (check-equal? (f32vector->list (device-vector->f32vector (f32vector->device-vector (f32vector 0.5
                                                                                             1.5))))
                '(0.5 1.5))
  (define out (device-vector->f32vector (vector->device-vector #(0.1 0.2))))
  (check-equal? (list (f32vector-length out) (f32vector-ref out 0)) '(2 0.10000000149011612))
  (define labels (vector->device-vector #(0 2 1 2 2 0) #:dtype 'int32))
  (check-equal? (f32vector->list (device-vector->f32vector labels)) '(0.0 2.0 1.0 2.0 2.0 0.0))
  (check-equal? (f64vector->list (device-vector->f64vector (f64vector->device-vector readings)))
                '(21.5 21.75 22.0 22.5))
  (check-equal? (f64vector->list (device-vector->f64vector (vector->device-vector #(0.1)
                                                                                  #:dtype 'float32)))
                '(0.10000000149011612))
  (define totals (device-vector->f64vector (vector->device-vector #(1.5 2.5 3.0))))
  (check-equal? (for/sum ([i (in-range (f64vector-length totals))]) (f64vector-ref totals i)) 7.0))

(test-gpu "compat reference: bytes"
  (define raw (bytes-append (real->floating-point-bytes 0.5 4) (real->floating-point-bytes 1.5 4)))
  (check-equal? (printed (bytes->device-vector raw #:dtype 'float32))
                "#<device-vector float32[2] cuda:0 [0.5 1.5]>")
  (define label-file (make-temporary-file))
  (call-with-output-file label-file
                         #:exists 'truncate
                         (lambda (out)
                           (for ([label (in-list '(0 2 1 1))])
                             (write-bytes (integer->integer-bytes label 4 #t) out))))
  (check-equal? (device-vector->list (bytes->device-vector (file->bytes label-file) #:dtype 'int32))
                '(0 2 1 1))
  (delete-file label-file)
  (check-raft-error 'logic
                    "bytes->device-vector: 6 bytes do not hold a whole number of 4-byte float32 elements"
                    (lambda () (bytes->device-vector (make-bytes 6) #:dtype 'float32)))
  (check-equal? (device-vector->bytes (vector->device-vector #(1 2) #:dtype 'int32))
                #"\1\0\0\0\2\0\0\0")
  (define result-file (make-temporary-file))
  (call-with-output-file
   result-file
   #:exists 'truncate
   (lambda (out) (void (write-bytes (device-vector->bytes (vector->device-vector #(0.5 0.25))) out))))
  (check-equal? (file-size result-file) 16)
  (check-equal? (device-vector->list (bytes->device-vector (file->bytes result-file) #:dtype 'float64))
                '(0.5 0.25))
  (delete-file result-file)
  (define one (device-vector->bytes (vector->device-vector #(1.0) #:dtype 'float32)))
  (check-equal? (device-vector->list (bytes->device-vector one #:dtype 'int32)) '(1065353216)))

(define A (matrix [[1.0 2.0] [3.0 4.0] [5.0 6.0]]))
(define gram (matrix* (matrix-transpose A) A))

(test-gpu "compat reference: math/matrix"
  (check-equal? (printed (matrix->device-matrix (matrix [[1.0 2.0] [3.0 4.0]])))
                (lines "#<device-matrix float64[2×2] row-major cuda:0" " [[1.0 2.0]" "  [3.0 4.0]]>"))
  (check-equal? (printed (matrix->device-matrix gram #:dtype 'float32))
                (lines "#<device-matrix float32[2×2] row-major cuda:0" " [[35.0 44.0]" "  [44.0 56.0]]>"))
  (check-equal? (dtype (matrix->device-matrix (identity-matrix 3))) 'int64)
  (define I (matrix->device-matrix (identity-matrix 3) #:dtype 'float64 #:layout 'col-major))
  (check-equal? (list (dtype I) (layout I)) '(float64 col-major))
  (check-equal? (printed (device-matrix->matrix (matrix->device-matrix (matrix [[1.0 2.0] [3.0 4.0]]))))
                "(flarray #[#[1.0 2.0] #[3.0 4.0]])")
  (define back (device-matrix->matrix (matrix->device-matrix gram)))
  (check-equal? (list (matrix-trace back) (matrix-determinant back)) '(91.0 24.0))
  (define counts-matrix
    (device-matrix->matrix (list*->device-matrix '((2 1) (1 3)) #:dtype 'int32)))
  (check-equal? (array->list* (matrix-inverse counts-matrix)) '((3/5 -1/5) (-1/5 2/5)))
  (check-equal? (printed (matrix->device-vector (col-matrix [1 2 3])))
                "#<device-vector int64[3] cuda:0 [1 2 3]>")
  (check-equal? (printed (matrix->device-vector (row-matrix [0.5 1.5])))
                "#<device-vector float64[2] cuda:0 [0.5 1.5]>")
  (define x (matrix-solve (matrix [[2.0 1.0] [1.0 3.0]]) (col-matrix [3.0 5.0])))
  (check-equal? (printed (matrix->device-vector x #:dtype 'float32))
                "#<device-vector float32[2] cuda:0 [0.8 1.4]>")
  (check-raft-error 'logic
                    "matrix->device-vector: a 2×2 matrix is neither a row nor a column matrix"
                    (lambda () (matrix->device-vector gram))))

(test-gpu "compat reference: row and column matrices"
  (check-equal? (printed (device-vector->col-matrix (vector->device-vector #(1.0 2.0 3.0))))
                "(flarray #[#[1.0] #[2.0] #[3.0]])")
  (define coefficients (vector->device-vector #(1.0 -1.0)))
  (check-equal? (array->list* (matrix* A (device-vector->col-matrix coefficients)))
                '((-1.0) (-1.0) (-1.0)))
  (check-equal? (matrix-norm (device-vector->col-matrix (vector->device-vector #(3.0 4.0)))) 5.0)
  (check-equal? (printed (device-vector->row-matrix (vector->device-vector #(1 2 3))))
                "(mutable-array #[#[1 2 3]])")
  (define runs (list (vector->device-vector #(0.25 0.5)) (vector->device-vector #(0.75 1.0))))
  (check-equal? (array->list* (matrix-stack (map device-vector->row-matrix runs)))
                '((0.25 0.5) (0.75 1.0)))
  (define u (vector->device-vector #(1.0 2.0)))
  (check-equal? (array->list* (matrix* (device-vector->row-matrix u) (device-vector->col-matrix u)))
                '((5.0))))

(test-gpu "compat reference: math/array"
  (check-equal? (printed (array->device-array (flarray #[#[1.0 2.0] #[3.0 4.0]])))
                (lines "#<device-matrix float64[2×2] row-major cuda:0" " [[1.0 2.0]" "  [3.0 4.0]]>"))
  (check-equal? (printed (array->device-array (array #[1 2 3])))
                "#<device-vector int64[3] cuda:0 [1 2 3]>")
  (define distances-table
    (build-array #(3 3) (lambda (js) (abs (- (vector-ref js 0) (vector-ref js 1))))))
  (check-equal? (device-matrix->list* (array->device-array distances-table #:dtype 'float32))
                '((0.0 1.0 2.0) (1.0 0.0 1.0) (2.0 1.0 0.0)))
  (define measurements (flarray #[#[5.1 3.5 1.4] #[7.0 3.2 4.7] #[6.3 3.3 6.0]]))
  (define first-two (array-slice-ref measurements (list (::) (:: 0 2))))
  (check-equal? (shape (array->device-array first-two #:dtype 'float32)) '(3 2))
  (check-raft-error
   'logic
   "array->device-array: rank 3 is not supported yet; rank 1 and 2 convert, and any rank arrives in leg 3"
   (lambda () (array->device-array (array #[#[#[1 2]]]))))
  (check-equal? (printed (device-array->array (vector->device-vector #(1.5 2.5)))) "(flarray #[1.5 2.5])")
  (check-equal? (printed (device-array->array (list*->device-matrix '((1 2) (3 4)) #:dtype 'int32)))
                "(mutable-array #[#[1 2] #[3 4]])")
  (check-equal? (array-all-sum (device-array->array (vector->device-vector #(0.5 1.5 2.0)))) 4.0)
  (define scaled (array-scale (device-array->array (vector->device-vector #(1.0 2.0 3.0))) 10.0))
  (check-equal? (device-vector->list (array->device-array scaled)) '(10.0 20.0 30.0)))

(define csv
  (string-append "sepal_length,sepal_width,petal_length,petal_width,species\n"
                 "5.1,3.5,1.4,0.2,setosa\n"
                 "4.9,3.0,1.4,0.2,setosa\n"
                 "7.0,3.2,4.7,1.4,versicolor\n"
                 "6.4,3.2,4.5,1.5,versicolor\n"
                 "6.3,3.3,6.0,2.5,virginica\n"
                 "5.8,2.7,5.1,1.9,virginica\n"))

(define table
  (for/list ([line (in-list (cdr (port->lines (open-input-string csv))))])
    (string-split line ",")))

(define rows
  (for/list ([fields (in-list table)])
    (map string->number (take fields 4))))

(define species (map last table))
(define names (remove-duplicates species))

(define (labels-of)
  (vector->device-vector (for/vector ([s (in-list species)])
                           (index-of names s))
                         #:dtype 'int32))

(test-gpu "moving-data guide: rows from a text file"
  (check-equal? (printed (list*->device-array rows #:dtype 'float32))
                (lines "#<device-matrix float32[6×4] row-major cuda:0"
                       " [[5.1 3.5 1.4 0.2]"
                       "  [4.9 3.0 1.4 0.2]"
                       "  [7.0 3.2 4.7 1.4]"
                       "  [6.4 3.2 4.5 1.5]"
                       "  [6.3 3.3 6.0 2.5]"
                       "  [5.8 2.7 5.1 1.9]]>"))
  (check-equal? (printed (labels-of)) "#<device-vector int32[6] cuda:0 [0 0 1 1 2 2]>"))

(test-gpu "moving-data guide: choosing float32"
  (check-equal? (dtype (list*->device-array rows)) 'float64)
  (check-equal? (dtype (list*->device-array '((1 2) (3 4)))) 'int64)
  (check-equal? (first (device-array->list* (list*->device-array rows #:dtype 'float32)))
                '(5.099999904632568 3.5 1.399999976158142 0.20000000298023224)))

(define M (list*->matrix rows))
(define n (matrix-num-rows M))

(define (covariance-of M)
  (define means (matrix-scale (matrix* (make-matrix 1 n 1) M) (/ 1.0 n)))
  (define centered (matrix- M (matrix* (make-matrix n 1 1) means)))
  (matrix-scale (matrix* (matrix-transpose centered) centered) (/ 1.0 (sub1 n))))

(test-gpu "moving-data guide: a matrix computed on the host"
  (define covariance (covariance-of M))
  (define C (matrix->device-matrix covariance #:dtype 'float32))
  (check-equal? (printed C)
                (lines "#<device-matrix float32[4×4] row-major cuda:0"
                       " [[ 0.6536667      0.011      1.281  0.5223333]"
                       "  [     0.011      0.075     -0.131     -0.059]"
                       "  [     1.281     -0.131      3.867      1.787]"
                       "  [ 0.5223333     -0.059      1.787 0.85366666]]>"))
  (define C* (device-matrix->matrix C))
  (check-equal? (array-shape C*) #(4 4))
  (check-true (matrix? C*))
  (check-true (< (array-all-max (array-abs (array- C* covariance))) 1e-6)))

(define (weights-of)
  (define weights (make-f64vector n))
  (for ([i (in-range n)])
    (f64vector-set! weights
                    i
                    (if (< i 2)
                        2.0
                        1.0)))
  weights)

(test-gpu "moving-data guide: weights from foreign code"
  (check-equal? (printed (f64vector->device-vector (weights-of) #:dtype 'float32))
                "#<device-vector float32[6] cuda:0 [2.0 2.0 1.0 1.0 1.0 1.0]>"))

(test-gpu "moving-data guide: a layout for the solver"
  (define F (list*->device-array rows #:dtype 'float32 #:layout 'col-major))
  (check-equal? (list (layout F) (strides F)) '(col-major (1 6)))
  (define F* (matrix->device-matrix M #:dtype 'float32 #:layout 'col-major))
  (check-equal? (device-array->list* F) (device-array->list* F*)))

(test-gpu "moving-data guide: results back in Racket"
  (define X* (device-array->array (list*->device-array rows #:dtype 'float32)))
  (check-equal? (array->list* (array-scale (array-axis-sum X* 0) (/ 1.0 n)))
                '(5.916666746139526 3.150000015894572 3.849999944368998 1.283333326379458))
  (define counts (make-vector (length names) 0))
  (for ([label (in-vector (device-vector->vector (labels-of)))])
    (vector-set! counts label (add1 (vector-ref counts label))))
  (check-equal? counts #(2 2 2))
  (define w (f64vector->device-vector (weights-of) #:dtype 'float32))
  (define saved (make-temporary-file))
  (call-with-output-file saved
                         #:exists 'truncate
                         (lambda (out) (void (write-bytes (device-vector->bytes w) out))))
  (check-equal? (file-size saved) 24)
  (check-equal? (device-vector->list (bytes->device-vector (file->bytes saved) #:dtype 'float32))
                '(2.0 2.0 1.0 1.0 1.0 1.0))
  (delete-file saved))
