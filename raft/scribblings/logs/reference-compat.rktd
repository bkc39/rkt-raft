((require ffi/vector
          json
          math/array
          math/matrix
          racket/file
          racket/vector
          raft/compat)
 (values "")
 ""
 "")
((vector->device-vector #(3 1 4 1 5))
 (values "#<device-vector int64[5] cuda:0 [3 1 4 1 5]>\n")
 ""
 "")
((vector->device-vector #(0.5 1.5 2.5) #:dtype 'float32)
 (values "#<device-vector float32[3] cuda:0 [0.5 1.5 2.5]>\n")
 ""
 "")
((define weights (for/vector ((i (in-range 6))) (/ 1.0 (add1 i))))
 (values "")
 ""
 "")
((vector->device-vector weights #:dtype 'float32)
 (values
  "#<device-vector float32[6] cuda:0 [       1.0        0.5 0.33333334       0.25        0.2 0.16666667]>\n")
 ""
 "")
((define flowers
   (vector #("setosa" 5.1 3.5) #("versicolor" 7.0 3.2) #("virginica" 6.3 3.3)))
 (values "")
 ""
 "")
((define lengths (vector-map (lambda (row) (vector-ref row 1)) flowers))
 (values "")
 ""
 "")
((device-vector->list (vector->device-vector lengths))
 (values "'(5.1 7.0 6.3)\n")
 ""
 "")
((vector->device-vector (vector-map (lambda (row) (vector-ref row 0)) flowers))
 (raise
  "vector->device-vector: cannot infer a dtype: \"setosa\" is not a real number")
 ""
 "")
((device-vector->vector (vector->device-vector #(2 7 1 8)))
 (values "'#(2 7 1 8)\n")
 ""
 "")
((define labels (vector->device-vector #(0 2 1 2 2 0) #:dtype 'int32))
 (values "")
 ""
 "")
((define counts (make-vector 3 0)) (values "") "" "")
((for
  ((label (in-vector (device-vector->vector labels))))
  (vector-set! counts label (add1 (vector-ref counts label))))
 (values "")
 ""
 "")
(counts (values "'#(2 1 3)\n") "" "")
((define scores (device-vector->vector (vector->device-vector #(0.2 0.9 0.4))))
 (values "")
 ""
 "")
((define best (vector-argmax values scores)) (values "") "" "")
((list best (vector-member best scores)) (values "'(0.9 1)\n") "" "")
((vector*->device-matrix #(#(1 2 3) #(4 5 6)))
 (values
  "#<device-matrix int64[2×3] row-major cuda:0\n [[1 2 3]\n  [4 5 6]]>\n")
 ""
 "")
((define grid
   (for/vector
    ((x (in-range 3)))
    (for/vector ((y (in-range 2))) (+ (* 0.5 x) y))))
 (values "")
 ""
 "")
((define G (vector*->device-matrix grid #:dtype 'float32 #:layout 'col-major))
 (values "")
 ""
 "")
((list (shape G) (contiguous? G #:layout 'col-major) (strides G))
 (values "'((3 2) #t (1 3))\n")
 ""
 "")
((vector*->device-matrix #(#(1.0 2.0) #(3.0)))
 (raise
  "vector*->device-matrix: row 1 has 1 element, but row 0 has 2: '#(3.0)")
 ""
 "")
((device-matrix->vector* (vector*->device-matrix #(#(1 2) #(3 4))))
 (values "'#(#(1 2) #(3 4))\n")
 ""
 "")
((define centroids
   (vector*->device-matrix #(#(5.0 3.4) #(6.6 3.0) #(5.9 2.8))))
 (values "")
 ""
 "")
((vector-ref (device-matrix->vector* centroids) 1)
 (values "'#(6.6 3.0)\n")
 ""
 "")
((device-matrix->vector* G)
 (values "'#(#(0.0 1.0) #(0.5 1.5) #(1.0 2.0))\n")
 ""
 "")
((list*->device-array '(1.0 2.0 3.0))
 (values "#<device-vector float64[3] cuda:0 [1.0 2.0 3.0]>\n")
 ""
 "")
((list*->device-array '((1 2) (3 4)))
 (values "#<device-matrix int64[2×2] row-major cuda:0\n [[1 2]\n  [3 4]]>\n")
 ""
 "")
((define (upload data) (list*->device-array data #:dtype 'float32))
 (values "")
 ""
 "")
((map
  shape
  (list (upload '(0.5 1.5)) (upload '((0.5 1.5) (2.5 3.5) (4.5 5.5)))))
 (values "'((2) (3 2))\n")
 ""
 "")
((shape (list*->device-array '())) (values "'(0)\n") "" "")
((list*->device-array '(((1 2) (3 4))))
 (raise
  "list*->device-array: rank 3 is not supported yet; rank 1 and 2 convert, and any rank arrives in leg 3")
 ""
 "")
((list*->device-array '(1.0 (2.0 3.0)))
 (raise
  "list*->device-array: element 1 is a list, but element 0 is not: '(2.0 3.0)")
 ""
 "")
((vector*->device-array #(1 2 3))
 (values "#<device-vector int64[3] cuda:0 [1 2 3]>\n")
 ""
 "")
((vector*->device-array #(#(1 2) #(3 4)))
 (values "#<device-matrix int64[2×2] row-major cuda:0\n [[1 2]\n  [3 4]]>\n")
 ""
 "")
((define saved
   (read (open-input-string "#(#(0.1 0.2) #(0.3 0.4) #(0.5 0.6))")))
 (values "")
 ""
 "")
((shape (vector*->device-array saved #:dtype 'float32))
 (values "'(3 2)\n")
 ""
 "")
((vector*->device-array (vector #(1 2) 3))
 (raise
  "vector*->device-array: row 1 is not a list or vector, but row 0 is: 3")
 ""
 "")
((device-array->list* (list*->device-array '(1 2 3)))
 (values "'(1 2 3)\n")
 ""
 "")
((device-array->list* (list*->device-array '((1 2) (3 4)) #:layout 'col-major))
 (values "'((1 2) (3 4))\n")
 ""
 "")
((define (results->json a)
   (jsexpr->string (hasheq 'shape (shape a) 'values (device-array->list* a))))
 (values "")
 ""
 "")
((results->json (list*->device-array '((1 2) (3 4)) #:dtype 'int32))
 (values "\"{\\\"shape\\\":[2,2],\\\"values\\\":[[1,2],[3,4]]}\"\n")
 ""
 "")
((results->json (vector->device-vector #(0.5 0.25)))
 (values "\"{\\\"shape\\\":[2],\\\"values\\\":[0.5,0.25]}\"\n")
 ""
 "")
((define (total a)
   (define xs (device-array->list* a))
   (apply + (if (device-matrix? a) (apply append xs) xs)))
 (values "")
 ""
 "")
((map
  total
  (list (list*->device-array '(1 2 3)) (list*->device-array '((1 2) (3 4)))))
 (values "'(6 10)\n")
 ""
 "")
((device-array->vector* (vector*->device-array #(1 2 3)))
 (values "'#(1 2 3)\n")
 ""
 "")
((device-array->vector* (vector*->device-array #(#(1 2) #(3 4))))
 (values "'#(#(1 2) #(3 4))\n")
 ""
 "")
((define table (device-array->vector* centroids)) (values "") "" "")
((vector-ref (vector-ref table 2) 0) (values "5.9\n") "" "")
((define distances (vector->device-vector #(2.5 0.5 1.5))) (values "") "" "")
((vector-sort (device-array->vector* distances) <)
 (values "'#(0.5 1.5 2.5)\n")
 ""
 "")
((device-vector->list distances) (values "'(2.5 0.5 1.5)\n") "" "")
((f32vector->device-vector (f32vector 0.5 1.5 2.5))
 (values "#<device-vector float32[3] cuda:0 [0.5 1.5 2.5]>\n")
 ""
 "")
((define samples (make-f32vector 4 0.25)) (values "") "" "")
((f32vector-set! samples 2 -0.75) (values "") "" "")
((define on-gpu (f32vector->device-vector samples)) (values "") "" "")
((list (dtype on-gpu) (device-vector->list on-gpu))
 (values "'(float32 (0.25 0.25 -0.75 0.25))\n")
 ""
 "")
((device-vector->list
  (f32vector->device-vector (f32vector 0.1 2.7) #:dtype 'float64))
 (values "'(0.10000000149011612 2.700000047683716)\n")
 ""
 "")
((device-vector->list
  (f32vector->device-vector (f32vector 0.1 2.7) #:dtype 'int32))
 (values "'(0 2)\n")
 ""
 "")
((f64vector->device-vector (f64vector 1.0 2.0 3.0))
 (values "#<device-vector float64[3] cuda:0 [1.0 2.0 3.0]>\n")
 ""
 "")
((define readings (list->f64vector '(21.5 21.75 22.0 22.5))) (values "") "" "")
((f64vector->device-vector readings #:dtype 'float32)
 (values "#<device-vector float32[4] cuda:0 [ 21.5 21.75  22.0  22.5]>\n")
 ""
 "")
((dtype (f64vector->device-vector (f64vector 3.0 0.0 12.0) #:dtype 'int64))
 (values "'int64\n")
 ""
 "")
((f32vector->list
  (device-vector->f32vector (f32vector->device-vector (f32vector 0.5 1.5))))
 (values "'(0.5 1.5)\n")
 ""
 "")
((define out (device-vector->f32vector (vector->device-vector #(0.1 0.2))))
 (values "")
 ""
 "")
((list (f32vector-length out) (f32vector-ref out 0))
 (values "'(2 0.10000000149011612)\n")
 ""
 "")
((f32vector->list (device-vector->f32vector labels))
 (values "'(0.0 2.0 1.0 2.0 2.0 0.0)\n")
 ""
 "")
((f64vector->list
  (device-vector->f64vector (f64vector->device-vector readings)))
 (values "'(21.5 21.75 22.0 22.5)\n")
 ""
 "")
((f64vector->list
  (device-vector->f64vector (vector->device-vector #(0.1) #:dtype 'float32)))
 (values "'(0.10000000149011612)\n")
 ""
 "")
((define totals
   (device-vector->f64vector (vector->device-vector #(1.5 2.5 3.0))))
 (values "")
 ""
 "")
((for/sum ((i (in-range (f64vector-length totals)))) (f64vector-ref totals i))
 (values "7.0\n")
 ""
 "")
((define raw
   (bytes-append
    (real->floating-point-bytes 0.5 4)
    (real->floating-point-bytes 1.5 4)))
 (values "")
 ""
 "")
((bytes->device-vector raw #:dtype 'float32)
 (values "#<device-vector float32[2] cuda:0 [0.5 1.5]>\n")
 ""
 "")
((define label-file (make-temporary-file)) (values "") "" "")
((define label-bytes
   (apply
    bytes-append
    (for/list
     ((label (in-list '(0 2 1 1))))
     (integer->integer-bytes label 4 #t))))
 (values "")
 ""
 "")
((display-to-file label-bytes label-file #:exists 'truncate) (values "") "" "")
((device-vector->list
  (bytes->device-vector (file->bytes label-file) #:dtype 'int32))
 (values "'(0 2 1 1)\n")
 ""
 "")
((delete-file label-file) (values "") "" "")
((bytes->device-vector (make-bytes 6) #:dtype 'float32)
 (raise
  "bytes->device-vector: 6 bytes do not hold a whole number of 4-byte float32 elements")
 ""
 "")
((device-vector->bytes (vector->device-vector #(1 2) #:dtype 'int32))
 (values "#\"\\1\\0\\0\\0\\2\\0\\0\\0\"\n")
 ""
 "")
((define result-file (make-temporary-file)) (values "") "" "")
((display-to-file
  (device-vector->bytes (vector->device-vector #(0.5 0.25)))
  result-file
  #:exists
  'truncate)
 (values "")
 ""
 "")
((file-size result-file) (values "16\n") "" "")
((device-vector->list
  (bytes->device-vector (file->bytes result-file) #:dtype 'float64))
 (values "'(0.5 0.25)\n")
 ""
 "")
((delete-file result-file) (values "") "" "")
((define one
   (device-vector->bytes (vector->device-vector #(1.0) #:dtype 'float32)))
 (values "")
 ""
 "")
((device-vector->list (bytes->device-vector one #:dtype 'int32))
 (values "'(1065353216)\n")
 ""
 "")
((matrix->device-matrix (matrix ((1.0 2.0) (3.0 4.0))))
 (values
  "#<device-matrix float64[2×2] row-major cuda:0\n [[1.0 2.0]\n  [3.0 4.0]]>\n")
 ""
 "")
((define A (matrix ((1.0 2.0) (3.0 4.0) (5.0 6.0)))) (values "") "" "")
((define gram (matrix* (matrix-transpose A) A)) (values "") "" "")
((matrix->device-matrix gram #:dtype 'float32)
 (values
  "#<device-matrix float32[2×2] row-major cuda:0\n [[35.0 44.0]\n  [44.0 56.0]]>\n")
 ""
 "")
((dtype (matrix->device-matrix (identity-matrix 3))) (values "'int64\n") "" "")
((define I
   (matrix->device-matrix
    (identity-matrix 3)
    #:dtype
    'float64
    #:layout
    'col-major))
 (values "")
 ""
 "")
((list (dtype I) (contiguous? I #:layout 'col-major))
 (values "'(float64 #t)\n")
 ""
 "")
((device-matrix->matrix (matrix->device-matrix (matrix ((1.0 2.0) (3.0 4.0)))))
 (values "(flarray #[#[1.0 2.0] #[3.0 4.0]])\n")
 ""
 "")
((define back (device-matrix->matrix (matrix->device-matrix gram)))
 (values "")
 ""
 "")
((list (matrix-trace back) (matrix-determinant back))
 (values "'(91.0 24.0)\n")
 ""
 "")
((define counts-matrix
   (device-matrix->matrix
    (list*->device-matrix '((2 1) (1 3)) #:dtype 'int32)))
 (values "")
 ""
 "")
((matrix-inverse counts-matrix)
 (values "(array #[#[3/5 -1/5] #[-1/5 2/5]])\n")
 ""
 "")
((matrix->device-vector (col-matrix (1 2 3)))
 (values "#<device-vector int64[3] cuda:0 [1 2 3]>\n")
 ""
 "")
((matrix->device-vector (row-matrix (0.5 1.5)))
 (values "#<device-vector float64[2] cuda:0 [0.5 1.5]>\n")
 ""
 "")
((define x
   (matrix-solve (matrix ((2.0 1.0) (1.0 3.0))) (col-matrix (3.0 5.0))))
 (values "")
 ""
 "")
((matrix->device-vector x #:dtype 'float32)
 (values "#<device-vector float32[2] cuda:0 [0.8 1.4]>\n")
 ""
 "")
((matrix->device-vector gram)
 (raise
  "matrix->device-vector: a 2×2 matrix is neither a row nor a column matrix")
 ""
 "")
((device-vector->col-matrix (vector->device-vector #(1.0 2.0 3.0)))
 (values "(flarray #[#[1.0] #[2.0] #[3.0]])\n")
 ""
 "")
((define coefficients (vector->device-vector #(1.0 -1.0))) (values "") "" "")
((matrix* A (device-vector->col-matrix coefficients))
 (values "(array #[#[-1.0] #[-1.0] #[-1.0]])\n")
 ""
 "")
((matrix-norm (device-vector->col-matrix (vector->device-vector #(3.0 4.0))))
 (values "5.0\n")
 ""
 "")
((device-vector->row-matrix (vector->device-vector #(1 2 3)))
 (values "(mutable-array #[#[1 2 3]])\n")
 ""
 "")
((define runs
   (list
    (vector->device-vector #(0.25 0.5))
    (vector->device-vector #(0.75 1.0))))
 (values "")
 ""
 "")
((matrix-stack (map device-vector->row-matrix runs))
 (values "(array #[#[0.25 0.5] #[0.75 1.0]])\n")
 ""
 "")
((define u (vector->device-vector #(1.0 2.0))) (values "") "" "")
((matrix* (device-vector->row-matrix u) (device-vector->col-matrix u))
 (values "(array #[#[5.0]])\n")
 ""
 "")
((array->device-array (flarray #(#(1.0 2.0) #(3.0 4.0))))
 (values
  "#<device-matrix float64[2×2] row-major cuda:0\n [[1.0 2.0]\n  [3.0 4.0]]>\n")
 ""
 "")
((array->device-array (array #(1 2 3)))
 (values "#<device-vector int64[3] cuda:0 [1 2 3]>\n")
 ""
 "")
((define distances-table
   (build-array
    #(3 3)
    (lambda (js) (abs (- (vector-ref js 0) (vector-ref js 1))))))
 (values "")
 ""
 "")
((array->device-array distances-table #:dtype 'float32)
 (values
  "#<device-matrix float32[3×3] row-major cuda:0\n [[0.0 1.0 2.0]\n  [1.0 0.0 1.0]\n  [2.0 1.0 0.0]]>\n")
 ""
 "")
((define measurements
   (flarray #(#(5.1 3.5 1.4) #(7.0 3.2 4.7) #(6.3 3.3 6.0))))
 (values "")
 ""
 "")
((define first-two (array-slice-ref measurements (list (::) (:: 0 2))))
 (values "")
 ""
 "")
((device-array->list* (array->device-array first-two))
 (values "'((5.1 3.5) (7.0 3.2) (6.3 3.3))\n")
 ""
 "")
((array->device-array (array #(#(#(1 2)))))
 (raise
  "array->device-array: rank 3 is not supported yet; rank 1 and 2 convert, and any rank arrives in leg 3")
 ""
 "")
((device-array->array (vector->device-vector #(1.5 2.5)))
 (values "(flarray #[1.5 2.5])\n")
 ""
 "")
((device-array->array (list*->device-matrix '((1 2) (3 4)) #:dtype 'int32))
 (values "(mutable-array #[#[1 2] #[3 4]])\n")
 ""
 "")
((array-all-sum (device-array->array (vector->device-vector #(0.5 1.5 2.0))))
 (values "4.0\n")
 ""
 "")
((define scaled
   (array-scale
    (device-array->array (vector->device-vector #(1.0 2.0 3.0)))
    10.0))
 (values "")
 ""
 "")
((array->device-array scaled)
 (values "#<device-vector float64[3] cuda:0 [10.0 20.0 30.0]>\n")
 ""
 "")
