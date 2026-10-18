((define samples
   '((5.1 3.5 1.4 0.2) (4.9 3.0 1.4 0.2) (7.0 3.2 4.7 1.4) (6.4 3.2 4.5 1.5)))
 (values "")
 ""
 "")
((define X (list*->device-matrix samples #:dtype 'float32)) (values "") "" "")
((define out (device-matrix 1000 128)) (values "") "" "")
((list (shape out) (dtype out) (layout out))
 (values "'((1000 128) float32 row-major)\n")
 ""
 "")
((define (distance-matrix data k)
   (match-define (list n _) (shape data))
   (device-matrix n k #:dtype (dtype data)))
 (values "")
 ""
 "")
((define distances (distance-matrix X 3)) (values "") "" "")
((list (shape distances) (dtype distances))
 (values "'((4 3) float32)\n")
 ""
 "")
((with-device-resources
  ((r (device-resources)))
  (define coefficients
    (device-matrix 3 2 #:dtype 'float64 #:layout 'col-major #:resources r))
  (list (layout coefficients) (strides coefficients)))
 (values "'(col-major (1 3))\n")
 ""
 "")
((device-matrix 2 2 #:dtype 'float16)
 (raise
  "device-matrix: unsupported dtype float16; expected float32, float64, int32 or int64")
 ""
 "")
((define labels (device-vector (first (shape X)) #:dtype 'int32))
 (values "")
 ""
 "")
((list (shape labels) (dtype labels) (strides labels))
 (values "'((4) int32 (1))\n")
 ""
 "")
((define weights (device-vector 4 #:dtype 'float64)) (values "") "" "")
((list (numel weights) (dtype weights)) (values "'(4 float64)\n") "" "")
((define (per-column m) (device-vector (second (shape m)) #:dtype (dtype m)))
 (values "")
 ""
 "")
((shape (per-column X)) (values "'(4)\n") "" "")
((device-array? X) (values "#t\n") "" "")
((device-array? labels) (values "#t\n") "" "")
((device-array? samples) (values "#f\n") "" "")
((define (on-device data)
   (if (device-array? data) data (list*->device-matrix data #:dtype 'float32)))
 (values "")
 ""
 "")
((eq? (on-device X) X) (values "#t\n") "" "")
((shape (on-device '((1.0 2.0)))) (values "'(1 2)\n") "" "")
((count device-array? (list X labels samples)) (values "2\n") "" "")
((device-matrix? X) (values "#t\n") "" "")
((device-matrix? labels) (values "#f\n") "" "")
((define (kmeans-input? v)
   (and (device-matrix? v)
        (eq? (layout v) 'row-major)
        (memq (dtype v) '(float32 float64))
        #t))
 (values "")
 ""
 "")
((kmeans-input? X) (values "#t\n") "" "")
((kmeans-input? (contiguous X #:layout 'col-major)) (values "#f\n") "" "")
((define (row-count a) (if (device-matrix? a) (first (shape a)) 1))
 (values "")
 ""
 "")
((map row-count (list X labels)) (values "'(4 1)\n") "" "")
((device-vector? labels) (values "#t\n") "" "")
((device-vector? X) (values "#f\n") "" "")
((define (->racket a)
   (if (device-vector? a) (device-vector->list a) (device-matrix->list* a)))
 (values "")
 ""
 "")
((->racket (list->device-vector '(1 2 3))) (values "'(1 2 3)\n") "" "")
((->racket (list*->device-matrix '((1 2) (3 4))))
 (values "'((1 2) (3 4))\n")
 ""
 "")
((define (weights-fit? w m)
   (and (device-vector? w) (= (first (shape w)) (first (shape m)))))
 (values "")
 ""
 "")
((weights-fit? weights X) (values "#t\n") "" "")
((weights-fit? labels (device-matrix 5 2)) (values "#f\n") "" "")
((shape X) (values "'(4 4)\n") "" "")
((shape labels) (values "'(4)\n") "" "")
((match-define (list n d) (shape X)) (values "") "" "")
((define centroids (device-matrix 3 d)) (values "") "" "")
((list n d (shape centroids)) (values "'(4 4 (3 4))\n") "" "")
((define (same-shape? a b) (equal? (shape a) (shape b))) (values "") "" "")
((same-shape? X (contiguous X #:layout 'col-major)) (values "#t\n") "" "")
((same-shape? X centroids) (values "#f\n") "" "")
((dtype X) (values "'float32\n") "" "")
((dtype labels) (values "'int32\n") "" "")
((define (scratch-like a)
   (match-define (list rows cols) (shape a))
   (device-matrix rows cols #:dtype (dtype a)))
 (values "")
 ""
 "")
((dtype (scratch-like (list*->device-matrix '((1 2)) #:dtype 'int32)))
 (values "'int32\n")
 ""
 "")
((map
  dtype
  (list
   (list->device-vector '(1 2 3))
   (list->device-vector '(1 2.5))
   (list->device-vector '(1/2))))
 (values "'(int64 float64 float64)\n")
 ""
 "")
((layout X) (values "'row-major\n") "" "")
((layout (contiguous X #:layout 'col-major)) (values "'col-major\n") "" "")
((define column (device-matrix 5 1 #:layout 'col-major)) (values "") "" "")
((list (strides column) (layout column) (layout labels))
 (values "'((1 5) row-major row-major)\n")
 ""
 "")
((contiguous? column #:layout 'col-major) (values "#t\n") "" "")
((for
  ((a (list X labels)))
  (printf "~a ~a ~a\n" (dtype a) (shape a) (layout a)))
 (values "")
 "float32 (4 4) row-major\nint32 (4) row-major\n"
 "")
((strides X) (values "'(4 1)\n") "" "")
((strides (contiguous X #:layout 'col-major)) (values "'(1 4)\n") "" "")
((strides (device-matrix 0 4)) (values "'(0 0)\n") "" "")
((define (element-index a i j)
   (+ (* i (first (strides a))) (* j (second (strides a)))))
 (values "")
 ""
 "")
((element-index X 2 1) (values "9\n") "" "")
((element-index (contiguous X #:layout 'col-major) 2 1) (values "6\n") "" "")
((define (byte-strides a)
   (define size (if (memq (dtype a) '(float32 int32)) 4 8))
   (map (lambda (s) (* s size)) (strides a)))
 (values "")
 ""
 "")
((byte-strides X) (values "'(16 4)\n") "" "")
((numel X) (values "16\n") "" "")
((numel labels) (values "4\n") "" "")
((define (megabytes a)
   (define size (if (memq (dtype a) '(float32 int32)) 4 8))
   (/ (* (numel a) size) (* 1024 1024.0)))
 (values "")
 ""
 "")
((megabytes out) (values "0.48828125\n") "" "")
((define (mean-of v)
   (if (zero? (numel v))
     +nan.0
     (/ (apply + (device-vector->list v)) (numel v))))
 (values "")
 ""
 "")
((mean-of (list->device-vector '(1.0 2.0 4.5))) (values "2.5\n") "" "")
((mean-of (list->device-vector '())) (values "+nan.0\n") "" "")
((contiguous? X) (values "#t\n") "" "")
((contiguous? X #:layout 'col-major) (values "#f\n") "" "")
((contiguous? (contiguous X #:layout 'col-major) #:layout 'col-major)
 (values "#t\n")
 ""
 "")
((define one-feature
   (list*->device-matrix '((5.1) (4.9) (7.0)) #:dtype 'float32))
 (values "")
 ""
 "")
((list (contiguous? one-feature) (contiguous? one-feature #:layout 'col-major))
 (values "'(#t #t)\n")
 ""
 "")
((eq? (contiguous one-feature #:layout 'col-major) one-feature)
 (values "#t\n")
 ""
 "")
((define (require-fortran-order m)
   (unless (contiguous? m #:layout 'col-major)
     (error 'least-squares "expected a col-major matrix, given ~a" (layout m)))
   m)
 (values "")
 ""
 "")
((shape (require-fortran-order (contiguous X #:layout 'col-major)))
 (values "'(4 4)\n")
 ""
 "")
((shape (require-fortran-order one-feature)) (values "'(3 1)\n") "" "")
((require-fortran-order X)
 (raise "least-squares: expected a col-major matrix, given row-major")
 ""
 "")
((define Xf (contiguous X #:layout 'col-major)) (values "") "" "")
((list (layout Xf) (strides Xf)) (values "'(col-major (1 4))\n") "" "")
((equal? (device-matrix->list* Xf) (device-matrix->list* X))
 (values "#t\n")
 ""
 "")
((eq? (contiguous Xf #:layout 'col-major) Xf) (values "#t\n") "" "")
((eq? (contiguous X) X) (values "#t\n") "" "")
((define Xr (contiguous Xf)) (values "") "" "")
((list (layout Xr) (kmeans-input? Xr)) (values "'(row-major #t)\n") "" "")
((contiguous
  (list*->device-matrix '((1 2 3) (4 5 6)) #:dtype 'int32)
  #:layout
  'col-major)
 (values
  "#<device-matrix int32[2×3] col-major cuda:0\n [[1 2 3]\n  [4 5 6]]>\n")
 ""
 "")
((list->device-vector '(3 1 4 1 5))
 (values "#<device-vector int64[5] cuda:0 [3 1 4 1 5]>\n")
 ""
 "")
((list->device-vector '(0.25 0.5) #:dtype 'float32)
 (values "#<device-vector float32[2] cuda:0 [0.25  0.5]>\n")
 ""
 "")
((device-vector->list (list->device-vector '(1/2 1/4 3)))
 (values "'(0.5 0.25 3.0)\n")
 ""
 "")
((list->device-vector '(1 2+3i))
 (raise "list->device-vector: cannot infer a dtype: 2+3i is not a real number")
 ""
 "")
((list->device-vector '(3000000000) #:dtype 'int32)
 (raise "list->device-vector: 3000000000 does not fit int32")
 ""
 "")
((define assigned (list->device-vector '(0 2 1 2) #:dtype 'int32))
 (values "")
 ""
 "")
((list (dtype assigned) (shape assigned)) (values "'(int32 (4))\n") "" "")
((device-vector->list assigned) (values "'(0 2 1 2)\n") "" "")
((define (cluster-sizes labels k)
   (define all (device-vector->list labels))
   (for/list ((c (in-range k))) (count (lambda (l) (= l c)) all)))
 (values "")
 ""
 "")
((cluster-sizes assigned 3) (values "'(1 1 2)\n") "" "")
((device-vector->list (list->device-vector '(0.1 0.5) #:dtype 'float32))
 (values "'(0.10000000149011612 0.5)\n")
 ""
 "")
((list*->device-matrix '((1 2) (3 4)))
 (values "#<device-matrix int64[2×2] row-major cuda:0\n [[1 2]\n  [3 4]]>\n")
 ""
 "")
((list*->device-matrix samples #:dtype 'float32 #:layout 'col-major)
 (values
  "#<device-matrix float32[4×4] col-major cuda:0\n [[5.1 3.5 1.4 0.2]\n  [4.9 3.0 1.4 0.2]\n  [7.0 3.2 4.7 1.4]\n  [6.4 3.2 4.5 1.5]]>\n")
 ""
 "")
((define lines '("5.1,3.5,1.4,0.2" "7.0,3.2,4.7,1.4")) (values "") "" "")
((define parsed
   (for/list
    ((line (in-list lines)))
    (map string->number (string-split line ","))))
 (values "")
 ""
 "")
((shape (list*->device-matrix parsed #:dtype 'float32))
 (values "'(2 4)\n")
 ""
 "")
((list*->device-matrix '((1 2 3) (4 5 6) (7 8)))
 (raise "list*->device-matrix: row 2 has 2 elements, but row 0 has 3: '(7 8)")
 ""
 "")
((device-matrix->list* (list*->device-matrix '((1 2) (3 4))))
 (values "'((1 2) (3 4))\n")
 ""
 "")
((device-matrix->list*
  (list*->device-matrix '((1 2) (3 4)) #:layout 'col-major))
 (values "'((1 2) (3 4))\n")
 ""
 "")
((define found (list*->device-matrix '((5.0 3.4) (6.6 3.0)) #:dtype 'float64))
 (values "")
 ""
 "")
((for
  ((row (in-list (device-matrix->list* found))) (c (in-naturals)))
  (printf "cluster ~a: ~a\n" c (string-join (map ~a row) " ")))
 (values "")
 "cluster 0: 5.0 3.4\ncluster 1: 6.6 3.0\n"
 "")
((flvector->device-vector (flvector 0.5 1.5 2.5))
 (values "#<device-vector float64[3] cuda:0 [0.5 1.5 2.5]>\n")
 ""
 "")
((define roots (for/flvector ((i (in-range 5))) (flsqrt (->fl i))))
 (values "")
 ""
 "")
((flvector->device-vector roots #:dtype 'float32)
 (values
  "#<device-vector float32[5] cuda:0 [      0.0       1.0 1.4142135 1.7320508       2.0]>\n")
 ""
 "")
((device-vector->list
  (flvector->device-vector (flvector 0.7 2.2 -1.5) #:dtype 'int64))
 (values "'(0 2 -1)\n")
 ""
 "")
((device-vector->flvector (flvector->device-vector (flvector 1.0 2.0)))
 (values "(flvector 1.0 2.0)\n")
 ""
 "")
((device-vector->flvector (list->device-vector '(0.1) #:dtype 'float32))
 (values "(flvector 0.10000000149011612)\n")
 ""
 "")
((device-vector->flvector (list->device-vector '(1 2 3)))
 (values "(flvector 1.0 2.0 3.0)\n")
 ""
 "")
((define v (device-vector->flvector (list->device-vector '(3.0 4.0))))
 (values "")
 ""
 "")
((flsqrt (for/fold ((sum 0.0)) ((x (in-flvector v))) (fl+ sum (fl* x x))))
 (values "5.0\n")
 ""
 "")
