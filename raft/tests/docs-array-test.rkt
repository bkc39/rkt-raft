#lang racket/base

(require (only-in datasets load-iris)
         (only-in polars in-dataframe-columns series->list)
         (only-in racket/flonum ->fl fl* fl+ flsqrt flvector for/flvector in-flvector)
         (only-in racket/format ~a)
         (only-in racket/list count first last make-list second take)
         (only-in racket/match match-define)
         (only-in racket/port with-output-to-string)
         (only-in racket/string string-join string-split)
         (only-in rackunit check-equal? check-exn check-false check-true test-case)
         (only-in "../main.rkt"
                  contiguous
                  contiguous?
                  device-array?
                  device-matrix
                  device-matrix->list*
                  device-matrix?
                  device-resources
                  device-vector
                  device-vector->flvector
                  device-vector->list
                  device-vector?
                  dtype
                  flvector->device-vector
                  layout
                  list*->device-matrix
                  list->device-vector
                  numel
                  shape
                  strides
                  with-device-resources)
         (only-in "private/collect.rkt" drain-finalizers!)
         (only-in "private/gpu.rkt" test-gpu)
         (only-in "private/raft-error.rkt" check-raft-error))

(define (printed v)
  (format "~a" v))

(define (flvector->list v)
  (for/list ([x (in-flvector v)])
    x))

(define iris
  '((5.1 3.5 1.4 0.2) (4.9 3.0 1.4 0.2)
                      (7.0 3.2 4.7 1.4)
                      (6.4 3.2 4.5 1.5)
                      (6.3 3.3 6.0 2.5)
                      (5.8 2.7 5.1 1.9)))

(define measurements '("sepal-length" "sepal-width" "petal-length" "petal-width"))

(define (iris-rows)
  (apply map
         list
         (for/list ([column (in-dataframe-columns (load-iris) #:columns measurements)])
           (series->list column))))

(test-case "arrays guide: the iris dataframe and its rows"
  (check-equal? (printed (load-iris))
                (string-append
                 "shape: (150, 5)\n"
                 "┌──────────────┬─────────────┬──────────────┬─────────────┬────────────────┐\n"
                 "│ sepal-length ┆ sepal-width ┆ petal-length ┆ petal-width ┆ species        │\n"
                 "│ ---          ┆ ---         ┆ ---          ┆ ---         ┆ ---            │\n"
                 "│ f64          ┆ f64         ┆ f64          ┆ f64         ┆ str            │\n"
                 "╞══════════════╪═════════════╪══════════════╪═════════════╪════════════════╡\n"
                 "│ 5.1          ┆ 3.5         ┆ 1.4          ┆ 0.2         ┆ Iris-setosa    │\n"
                 "│ 4.9          ┆ 3.0         ┆ 1.4          ┆ 0.2         ┆ Iris-setosa    │\n"
                 "│ 4.7          ┆ 3.2         ┆ 1.3          ┆ 0.2         ┆ Iris-setosa    │\n"
                 "│ 4.6          ┆ 3.1         ┆ 1.5          ┆ 0.2         ┆ Iris-setosa    │\n"
                 "│ 5.0          ┆ 3.6         ┆ 1.4          ┆ 0.2         ┆ Iris-setosa    │\n"
                 "│ …            ┆ …           ┆ …            ┆ …           ┆ …              │\n"
                 "│ 6.7          ┆ 3.0         ┆ 5.2          ┆ 2.3         ┆ Iris-virginica │\n"
                 "│ 6.3          ┆ 2.5         ┆ 5.0          ┆ 1.9         ┆ Iris-virginica │\n"
                 "│ 6.5          ┆ 3.0         ┆ 5.2          ┆ 2.0         ┆ Iris-virginica │\n"
                 "│ 6.2          ┆ 3.4         ┆ 5.4          ┆ 2.3         ┆ Iris-virginica │\n"
                 "│ 5.9          ┆ 3.0         ┆ 5.1          ┆ 1.8         ┆ Iris-virginica │\n"
                 "└──────────────┴─────────────┴──────────────┴─────────────┴────────────────┘"))
  (define rows (iris-rows))
  (check-equal? (length rows) 150)
  (check-equal? (take rows 3) '((5.1 3.5 1.4 0.2) (4.9 3.0 1.4 0.2) (4.7 3.2 1.3 0.2))))

(test-gpu "arrays guide: a dataset on the GPU"
  (define X (list*->device-matrix (iris-rows) #:dtype 'float32))
  (check-equal? (printed X)
                (string-append "#<device-matrix float32[150×4] row-major cuda:0\n"
                               " [[5.1 3.5 1.4 0.2]\n"
                               "  [4.9 3.0 1.4 0.2]\n"
                               "  [4.7 3.2 1.3 0.2]\n"
                               "  ...\n"
                               "  [6.5 3.0 5.2 2.0]\n"
                               "  [6.2 3.4 5.4 2.3]\n"
                               "  [5.9 3.0 5.1 1.8]]>"))
  (check-equal? (list (shape X) (dtype X) (layout X) (strides X) (numel X))
                '((150 4) float32 row-major (4 1) 600)))

(test-gpu "arrays guide: changing the layout"
  (define rows (iris-rows))
  (define X (list*->device-matrix rows #:dtype 'float32))
  (define F (contiguous X #:layout 'col-major))
  (check-equal? (list (layout F) (strides F)) '(col-major (1 150)))
  (check-true (contiguous? F #:layout 'col-major))
  (check-true (equal? (device-matrix->list* F) (device-matrix->list* X)))
  (check-true (eq? (contiguous F #:layout 'col-major) F))
  (check-true (eq? (contiguous X) X))
  (define F* (list*->device-matrix rows #:dtype 'float32 #:layout 'col-major))
  (check-equal? (strides F*) '(1 150))
  (check-true (equal? (device-matrix->list* F*) (device-matrix->list* F))))

(test-gpu "arrays guide: bringing values back"
  (define rows (iris-rows))
  (define widths (for/flvector ([row (in-list rows)]) (last row)))
  (define y (flvector->device-vector widths #:dtype 'float32))
  (check-equal? (printed y) "#<device-vector float32[150] cuda:0 [0.2 0.2 0.2 ... 2.0 2.3 1.8]>")
  (check-equal? (take (device-vector->list y) 4) (make-list 4 0.20000000298023224))
  (define X (list*->device-matrix rows #:dtype 'float32))
  (check-equal? (first (device-matrix->list* X))
                '(5.099999904632568 3.5 1.399999976158142 0.20000000298023224))
  (check-equal? (first (device-matrix->list* (list*->device-matrix rows))) '(5.1 3.5 1.4 0.2)))

(test-gpu "arrays guide: letting go"
  (drain-finalizers!)
  (define before (current-memory-use))
  (define scratch (device-matrix 1024 1024))
  (check-equal? (quotient (- (current-memory-use) before) (* 1024 1024)) 4)
  (check-equal? (numel scratch) (* 1024 1024))
  (set! scratch #f)
  (drain-finalizers!)
  (check-true (< (- (current-memory-use) before) (* 1024 1024))))

(define samples (take iris 4))

(define (sample-matrix)
  (list*->device-matrix samples #:dtype 'float32))

(define (kmeans-input? v)
  (and (device-matrix? v) (eq? (layout v) 'row-major) (memq (dtype v) '(float32 float64)) #t))

(test-gpu "reference: device-matrix"
  (define X (sample-matrix))
  (define out (device-matrix 1000 128))
  (check-equal? (list (shape out) (dtype out) (layout out)) '((1000 128) float32 row-major))
  (define (distance-matrix data k)
    (match-define (list n _) (shape data))
    (device-matrix n k #:dtype (dtype data)))
  (define distances (distance-matrix X 3))
  (check-equal? (list (shape distances) (dtype distances)) '((4 3) float32))
  (check-equal? (with-device-resources ([r (device-resources)])
                  (define coefficients
                    (device-matrix 3 2 #:dtype 'float64 #:layout 'col-major #:resources r))
                  (list (layout coefficients) (strides coefficients)))
                '(col-major (1 3)))
  (check-raft-error
   'logic
   "device-matrix: unsupported dtype float16; expected float32, float64, int32 or int64"
   (lambda () (device-matrix 2 2 #:dtype 'float16))))

(test-gpu "reference: device-vector"
  (define X (sample-matrix))
  (define labels (device-vector (first (shape X)) #:dtype 'int32))
  (check-equal? (list (shape labels) (dtype labels) (strides labels)) '((4) int32 (1)))
  (define weights (device-vector 4 #:dtype 'float64))
  (check-equal? (list (numel weights) (dtype weights)) '(4 float64))
  (define (per-column m)
    (device-vector (second (shape m)) #:dtype (dtype m)))
  (check-equal? (shape (per-column X)) '(4)))

(test-gpu "reference: device-array?"
  (define X (sample-matrix))
  (define labels (device-vector 4 #:dtype 'int32))
  (check-equal? (map device-array? (list X labels samples)) '(#t #t #f))
  (define (on-device data)
    (if (device-array? data)
        data
        (list*->device-matrix data #:dtype 'float32)))
  (check-true (eq? (on-device X) X))
  (check-equal? (shape (on-device '((1.0 2.0)))) '(1 2))
  (check-equal? (count device-array? (list X labels samples)) 2))

(test-gpu "reference: device-matrix?"
  (define X (sample-matrix))
  (define labels (device-vector 4 #:dtype 'int32))
  (check-equal? (list (device-matrix? X) (device-matrix? labels)) '(#t #f))
  (check-true (kmeans-input? X))
  (check-false (kmeans-input? (contiguous X #:layout 'col-major)))
  (define (row-count a)
    (if (device-matrix? a)
        (first (shape a))
        1))
  (check-equal? (map row-count (list X labels)) '(4 1)))

(test-gpu "reference: device-vector?"
  (define X (sample-matrix))
  (define labels (device-vector 4 #:dtype 'int32))
  (define weights (device-vector 4 #:dtype 'float64))
  (check-equal? (list (device-vector? labels) (device-vector? X)) '(#t #f))
  (define (->racket a)
    (if (device-vector? a)
        (device-vector->list a)
        (device-matrix->list* a)))
  (check-equal? (->racket (list->device-vector '(1 2 3))) '(1 2 3))
  (check-equal? (->racket (list*->device-matrix '((1 2) (3 4)))) '((1 2) (3 4)))
  (define (weights-fit? w m)
    (and (device-vector? w) (= (first (shape w)) (first (shape m)))))
  (check-true (weights-fit? weights X))
  (check-false (weights-fit? labels (device-matrix 5 2))))

(test-gpu "reference: shape"
  (define X (sample-matrix))
  (check-equal? (list (shape X) (shape (device-vector 4 #:dtype 'int32))) '((4 4) (4)))
  (match-define (list n d) (shape X))
  (define centroids (device-matrix 3 d))
  (check-equal? (list n d (shape centroids)) '(4 4 (3 4)))
  (define (same-shape? a b)
    (equal? (shape a) (shape b)))
  (check-true (same-shape? X (contiguous X #:layout 'col-major)))
  (check-false (same-shape? X centroids)))

(test-gpu "reference: dtype"
  (check-equal? (list (dtype (sample-matrix)) (dtype (device-vector 4 #:dtype 'int32)))
                '(float32 int32))
  (define (scratch-like a)
    (match-define (list rows cols) (shape a))
    (device-matrix rows cols #:dtype (dtype a)))
  (check-equal? (dtype (scratch-like (list*->device-matrix '((1 2)) #:dtype 'int32))) 'int32)
  (check-equal? (map dtype
                     (list (list->device-vector '(1 2 3))
                           (list->device-vector '(1 2.5))
                           (list->device-vector '(1/2))))
                '(int64 float64 float64)))

(test-gpu "reference: layout"
  (define X (sample-matrix))
  (check-equal? (list (layout X) (layout (contiguous X #:layout 'col-major))) '(row-major col-major))
  (define column (device-matrix 5 1 #:layout 'col-major))
  (check-equal? (list (strides column) (layout column) (layout (device-vector 4 #:dtype 'int32)))
                '((1 5) row-major row-major))
  (check-true (contiguous? column #:layout 'col-major))
  (define labels (device-vector 4 #:dtype 'int32))
  (check-equal? (with-output-to-string (lambda ()
                                         (for ([a (list X labels)])
                                           (printf "~a ~a ~a\n" (dtype a) (shape a) (layout a)))))
                "float32 (4 4) row-major\nint32 (4) row-major\n"))

(test-gpu "reference: contiguous?"
  (define X (sample-matrix))
  (check-equal? (list (contiguous? X)
                      (contiguous? X #:layout 'col-major)
                      (contiguous? (contiguous X #:layout 'col-major) #:layout 'col-major))
                '(#t #f #t))
  (define one-feature (list*->device-matrix '((5.1) (4.9) (7.0)) #:dtype 'float32))
  (check-equal? (list (contiguous? one-feature) (contiguous? one-feature #:layout 'col-major))
                '(#t #t))
  (check-true (eq? (contiguous one-feature #:layout 'col-major) one-feature))
  (define (require-fortran-order m)
    (unless (contiguous? m #:layout 'col-major)
      (error 'least-squares "expected a col-major matrix, given ~a" (layout m)))
    m)
  (check-equal? (shape (require-fortran-order (contiguous X #:layout 'col-major))) '(4 4))
  (check-equal? (shape (require-fortran-order one-feature)) '(3 1))
  (check-exn #rx"^least-squares: expected a col-major matrix, given row-major$"
             (lambda () (require-fortran-order X))))

(test-gpu "reference: strides"
  (define X (sample-matrix))
  (check-equal? (list (strides X) (strides (contiguous X #:layout 'col-major))) '((4 1) (1 4)))
  (define (element-index a i j)
    (+ (* i (first (strides a))) (* j (second (strides a)))))
  (check-equal? (list (element-index X 2 1) (element-index (contiguous X #:layout 'col-major) 2 1))
                '(9 6))
  (define (byte-strides a)
    (define size (if (memq (dtype a) '(float32 int32)) 4 8))
    (map (lambda (s) (* s size)) (strides a)))
  (check-equal? (byte-strides X) '(16 4))
  (check-equal? (strides (device-matrix 0 4)) '(0 0)))

(test-gpu "reference: numel"
  (check-equal? (list (numel (sample-matrix)) (numel (device-vector 4 #:dtype 'int32))) '(16 4))
  (define (megabytes a)
    (define size (if (memq (dtype a) '(float32 int32)) 4 8))
    (/ (* (numel a) size) (* 1024 1024.0)))
  (check-equal? (megabytes (device-matrix 1000 128)) 0.48828125)
  (define (mean-of v)
    (if (zero? (numel v))
        +nan.0
        (/ (apply + (device-vector->list v)) (numel v))))
  (check-equal? (mean-of (list->device-vector '(1.0 2.0 4.5))) 2.5)
  (check-equal? (mean-of (list->device-vector '())) +nan.0))

(test-gpu "reference: contiguous"
  (define X (sample-matrix))
  (define Xf (contiguous X #:layout 'col-major))
  (check-equal? (list (layout Xf) (strides Xf)) '(col-major (1 4)))
  (check-true (equal? (device-matrix->list* Xf) (device-matrix->list* X)))
  (check-true (eq? (contiguous Xf #:layout 'col-major) Xf))
  (check-true (eq? (contiguous X) X))
  (define Xr (contiguous Xf))
  (check-equal? (list (layout Xr) (kmeans-input? Xr)) '(row-major #t))
  (check-equal? (printed (contiguous (list*->device-matrix '((1 2 3) (4 5 6)) #:dtype 'int32)
                                     #:layout 'col-major))
                "#<device-matrix int32[2×3] col-major cuda:0\n [[1 2 3]\n  [4 5 6]]>"))

(test-gpu "reference: list->device-vector"
  (check-equal? (printed (list->device-vector '(3 1 4 1 5)))
                "#<device-vector int64[5] cuda:0 [3 1 4 1 5]>")
  (check-equal? (printed (list->device-vector '(0.25 0.5) #:dtype 'float32))
                "#<device-vector float32[2] cuda:0 [0.25  0.5]>")
  (check-equal? (device-vector->list (list->device-vector '(1/2 1/4 3))) '(0.5 0.25 3.0))
  (define assigned (list->device-vector '(0 2 1 2) #:dtype 'int32))
  (check-equal? (list (dtype assigned) (shape assigned)) '(int32 (4)))
  (check-raft-error 'logic
                    "list->device-vector: cannot infer a dtype: 2+3i is not a real number"
                    (lambda () (list->device-vector '(1 2+3i))))
  (check-raft-error 'logic
                    "list->device-vector: 3000000000 does not fit int32"
                    (lambda () (list->device-vector '(3000000000) #:dtype 'int32))))

(test-gpu "reference: device-vector->list"
  (check-equal? (device-vector->list (list->device-vector '(0 2 1 2) #:dtype 'int32)) '(0 2 1 2))
  (define (cluster-sizes labels k)
    (define all (device-vector->list labels))
    (for/list ([c (in-range k)])
      (count (lambda (l) (= l c)) all)))
  (check-equal? (cluster-sizes (list->device-vector '(0 2 1 2) #:dtype 'int32) 3) '(1 1 2))
  (check-equal? (device-vector->list (list->device-vector '(0.1 0.5) #:dtype 'float32))
                '(0.10000000149011612 0.5)))

(test-gpu "reference: list*->device-matrix"
  (check-equal? (printed (list*->device-matrix '((1 2) (3 4))))
                "#<device-matrix int64[2×2] row-major cuda:0\n [[1 2]\n  [3 4]]>")
  (check-equal? (printed (list*->device-matrix samples #:dtype 'float32 #:layout 'col-major))
                (string-append "#<device-matrix float32[4×4] col-major cuda:0\n"
                               " [[5.1 3.5 1.4 0.2]\n"
                               "  [4.9 3.0 1.4 0.2]\n"
                               "  [7.0 3.2 4.7 1.4]\n"
                               "  [6.4 3.2 4.5 1.5]]>"))
  (define lines '("5.1,3.5,1.4,0.2" "7.0,3.2,4.7,1.4"))
  (define parsed
    (for/list ([line (in-list lines)])
      (map string->number (string-split line ","))))
  (check-equal? (shape (list*->device-matrix parsed #:dtype 'float32)) '(2 4))
  (check-raft-error 'logic
                    "list*->device-matrix: row 2 has 2 elements, but row 0 has 3: '(7 8)"
                    (lambda () (list*->device-matrix '((1 2 3) (4 5 6) (7 8))))))

(test-gpu "reference: device-matrix->list*"
  (check-equal? (device-matrix->list* (list*->device-matrix '((1 2) (3 4)))) '((1 2) (3 4)))
  (check-equal? (device-matrix->list* (list*->device-matrix '((1 2) (3 4)) #:layout 'col-major))
                '((1 2) (3 4)))
  (define found (list*->device-matrix '((5.0 3.4) (6.6 3.0)) #:dtype 'float64))
  (check-equal?
   (with-output-to-string (lambda ()
                            (for ([row (in-list (device-matrix->list* found))]
                                  [c (in-naturals)])
                              (printf "cluster ~a: ~a\n" c (string-join (map ~a row) " ")))))
   "cluster 0: 5.0 3.4\ncluster 1: 6.6 3.0\n"))

(test-gpu "reference: flvector->device-vector"
  (check-equal? (printed (flvector->device-vector (flvector 0.5 1.5 2.5)))
                "#<device-vector float64[3] cuda:0 [0.5 1.5 2.5]>")
  (define roots (for/flvector ([i (in-range 5)]) (flsqrt (->fl i))))
  (check-equal?
   (printed (flvector->device-vector roots #:dtype 'float32))
   "#<device-vector float32[5] cuda:0 [      0.0       1.0 1.4142135 1.7320508       2.0]>")
  (check-equal? (device-vector->list (flvector->device-vector (flvector 0.7 2.2 -1.5) #:dtype 'int64))
                '(0 2 -1)))

(test-gpu "reference: device-vector->flvector"
  (check-equal? (flvector->list (device-vector->flvector (flvector->device-vector (flvector 1.0
                                                                                            2.0))))
                '(1.0 2.0))
  (check-equal? (flvector->list (device-vector->flvector (list->device-vector '(0.1)
                                                                              #:dtype 'float32)))
                '(0.10000000149011612))
  (check-equal? (flvector->list (device-vector->flvector (list->device-vector '(1 2 3))))
                '(1.0 2.0 3.0))
  (define v (device-vector->flvector (list->device-vector '(3.0 4.0))))
  (check-equal? (flsqrt (for/fold ([sum 0.0]) ([x (in-flvector v)])
                          (fl+ sum (fl* x x))))
                5.0))

(test-gpu "concepts: making and using arrays"
  (check-equal? (printed (list->device-vector '(1.5 -2.25 0.0)))
                "#<device-vector float64[3] cuda:0 [  1.5 -2.25   0.0]>")
  (check-equal? (printed (list->device-vector '(3 1 4) #:dtype 'int32))
                "#<device-vector int32[3] cuda:0 [3 1 4]>")
  (check-equal? (printed (list*->device-matrix '((1 2 3) (4 5 6))))
                "#<device-matrix int64[2×3] row-major cuda:0\n [[1 2 3]\n  [4 5 6]]>")
  (define m (list*->device-matrix '((1 2 3) (4 5 6)) #:dtype 'float32 #:layout 'col-major))
  (check-equal? (printed m)
                "#<device-matrix float32[2×3] col-major cuda:0\n [[1.0 2.0 3.0]\n  [4.0 5.0 6.0]]>")
  (define out (device-matrix 1000 128 #:dtype 'float64))
  (check-equal? (list (shape out) (dtype out) (layout out)) '((1000 128) float64 row-major))
  (define labels (device-vector 1000 #:dtype 'int32))
  (check-equal? (list (shape labels) (dtype labels)) '((1000) int32))
  (check-equal? (list (shape m) (dtype m) (layout m) (strides m) (numel m))
                '((2 3) float32 col-major (1 2) 6))
  (check-equal? (list (contiguous? m) (contiguous? m #:layout 'col-major)) '(#f #t))
  (check-equal? (strides (contiguous m)) '(3 1))
  (check-equal? (device-matrix->list* m) '((1.0 2.0 3.0) (4.0 5.0 6.0)))
  (check-equal? (flvector->list (device-vector->flvector (list->device-vector '(0.5 1.5))))
                '(0.5 1.5)))
