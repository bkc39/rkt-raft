((putenv "POLARS_TABLE_WIDTH" "100") (values "#t\n") "" "")
((require datasets (only-in polars in-dataframe-columns series->list))
 (values "")
 ""
 "")
((define iris (load-iris)) (values "") "" "")
(iris
 (values
  "shape: (150, 5)\n┌──────────────┬─────────────┬──────────────┬─────────────┬────────────────┐\n│ sepal-length ┆ sepal-width ┆ petal-length ┆ petal-width ┆ species        │\n│ ---          ┆ ---         ┆ ---          ┆ ---         ┆ ---            │\n│ f64          ┆ f64         ┆ f64          ┆ f64         ┆ str            │\n╞══════════════╪═════════════╪══════════════╪═════════════╪════════════════╡\n│ 5.1          ┆ 3.5         ┆ 1.4          ┆ 0.2         ┆ Iris-setosa    │\n│ 4.9          ┆ 3.0         ┆ 1.4          ┆ 0.2         ┆ Iris-setosa    │\n│ 4.7          ┆ 3.2         ┆ 1.3          ┆ 0.2         ┆ Iris-setosa    │\n│ 4.6          ┆ 3.1         ┆ 1.5          ┆ 0.2         ┆ Iris-setosa    │\n│ 5.0          ┆ 3.6         ┆ 1.4          ┆ 0.2         ┆ Iris-setosa    │\n│ …            ┆ …           ┆ …            ┆ …           ┆ …              │\n│ 6.7          ┆ 3.0         ┆ 5.2          ┆ 2.3         ┆ Iris-virginica │\n│ 6.3          ┆ 2.5         ┆ 5.0          ┆ 1.9         ┆ Iris-virginica │\n│ 6.5          ┆ 3.0         ┆ 5.2          ┆ 2.0         ┆ Iris-virginica │\n│ 6.2          ┆ 3.4         ┆ 5.4          ┆ 2.3         ┆ Iris-virginica │\n│ 5.9          ┆ 3.0         ┆ 5.1          ┆ 1.8         ┆ Iris-virginica │\n└──────────────┴─────────────┴──────────────┴─────────────┴────────────────┘\n")
 ""
 "")
((define measurements
   '("sepal-length" "sepal-width" "petal-length" "petal-width"))
 (values "")
 ""
 "")
((define rows
   (apply
    map
    list
    (for/list
     ((column (in-dataframe-columns iris #:columns measurements)))
     (series->list column))))
 (values "")
 ""
 "")
((length rows) (values "150\n") "" "")
((take rows 3)
 (values "'((5.1 3.5 1.4 0.2) (4.9 3.0 1.4 0.2) (4.7 3.2 1.3 0.2))\n")
 ""
 "")
((define X (list*->device-matrix rows #:dtype 'float32)) (values "") "" "")
(X
 (values
  "#<device-matrix float32[150×4] row-major cuda:0\n [[5.1 3.5 1.4 0.2]\n  [4.9 3.0 1.4 0.2]\n  [4.7 3.2 1.3 0.2]\n  ...\n  [6.5 3.0 5.2 2.0]\n  [6.2 3.4 5.4 2.3]\n  [5.9 3.0 5.1 1.8]]>\n")
 ""
 "")
((shape X) (values "'(150 4)\n") "" "")
((dtype X) (values "'float32\n") "" "")
((layout X) (values "'row-major\n") "" "")
((strides X) (values "'(4 1)\n") "" "")
((numel X) (values "600\n") "" "")
((define F (contiguous X #:layout 'col-major)) (values "") "" "")
((layout F) (values "'col-major\n") "" "")
((strides F) (values "'(1 150)\n") "" "")
((contiguous? F #:layout 'col-major) (values "#t\n") "" "")
((equal? (device-matrix->list* F) (device-matrix->list* X))
 (values "#t\n")
 ""
 "")
((eq? (contiguous F #:layout 'col-major) F) (values "#t\n") "" "")
((eq? (contiguous X) X) (values "#t\n") "" "")
((define F* (list*->device-matrix rows #:dtype 'float32 #:layout 'col-major))
 (values "")
 ""
 "")
((strides F*) (values "'(1 150)\n") "" "")
((equal? (device-matrix->list* F*) (device-matrix->list* F))
 (values "#t\n")
 ""
 "")
((require raft/compat ffi/vector math/array math/matrix racket/file)
 (values "")
 ""
 "")
((shape (list*->device-array rows)) (values "'(150 4)\n") "" "")
((shape (list*->device-array (first rows))) (values "'(4)\n") "" "")
((define species
   (for/first
    ((column (in-dataframe-columns iris #:columns '("species"))))
    (series->list column)))
 (values "")
 ""
 "")
((define names (remove-duplicates species)) (values "") "" "")
((define labels
   (vector->device-vector
    (for/vector ((s (in-list species))) (index-of names s))
    #:dtype
    'int32))
 (values "")
 ""
 "")
(labels
 (values "#<device-vector int32[150] cuda:0 [0 0 0 ... 2 2 2]>\n")
 ""
 "")
((define M (list*->matrix rows)) (values "") "" "")
((define n (matrix-num-rows M)) (values "") "" "")
((define means (matrix-scale (matrix* (make-matrix 1 n 1) M) (/ 1.0 n)))
 (values "")
 ""
 "")
((define centered (matrix- M (matrix* (make-matrix n 1 1) means)))
 (values "")
 ""
 "")
((define covariance
   (matrix-scale
    (matrix* (matrix-transpose centered) centered)
    (/ 1.0 (sub1 n))))
 (values "")
 ""
 "")
((define C (matrix->device-matrix covariance #:dtype 'float32))
 (values "")
 ""
 "")
(C
 (values
  "#<device-matrix float32[4×4] row-major cuda:0\n [[   0.6856935 -0.042434003    1.2743155    0.5162707]\n  [-0.042434003   0.18997942  -0.32965636  -0.12163937]\n  [   1.2743155  -0.32965636     3.116278    1.2956094]\n  [   0.5162707  -0.12163937    1.2956094    0.5810063]]>\n")
 ""
 "")
((define weights (make-f64vector n 1.0)) (values "") "" "")
((f64vector-set! weights 0 2.0) (values "") "" "")
((define w (f64vector->device-vector weights #:dtype 'float32))
 (values "")
 ""
 "")
(w
 (values
  "#<device-vector float32[150] cuda:0 [2.0 1.0 1.0 ... 1.0 1.0 1.0]>\n")
 ""
 "")
((define widths (for/flvector ((row (in-list rows))) (last row)))
 (values "")
 ""
 "")
((define y (flvector->device-vector widths #:dtype 'float32))
 (values "")
 ""
 "")
(y
 (values
  "#<device-vector float32[150] cuda:0 [0.2 0.2 0.2 ... 2.0 2.3 1.8]>\n")
 ""
 "")
((take (device-vector->list y) 4)
 (values
  "'(0.20000000298023224\n  0.20000000298023224\n  0.20000000298023224\n  0.20000000298023224)\n")
 ""
 "")
((first (device-matrix->list* X))
 (values "'(5.099999904632568 3.5 1.399999976158142 0.20000000298023224)\n")
 ""
 "")
((first (device-matrix->list* (list*->device-matrix rows)))
 (values "'(5.1 3.5 1.4 0.2)\n")
 ""
 "")
((<
  (array-all-max (array-abs (array- (device-matrix->matrix C) covariance)))
  1e-6)
 (values "#t\n")
 ""
 "")
((array-scale (array-axis-sum (device-array->array X) 0) (/ 1.0 n))
 (values
  "(array\n #[5.843333326975505 3.057333335876465 3.757999988396963 1.1993333247800668])\n")
 ""
 "")
((define counts (make-vector (length names) 0)) (values "") "" "")
((for
  ((label (in-vector (device-vector->vector labels))))
  (vector-set! counts label (add1 (vector-ref counts label))))
 (values "")
 ""
 "")
(counts (values "'#(50 50 50)\n") "" "")
((define saved (make-temporary-file)) (values "") "" "")
((display-to-file (device-vector->bytes w) saved #:exists 'truncate)
 (values "")
 ""
 "")
((file-size saved) (values "600\n") "" "")
((take
  (device-vector->list
   (bytes->device-vector (file->bytes saved) #:dtype 'float32))
  3)
 (values "'(2.0 1.0 1.0)\n")
 ""
 "")
((delete-file saved) (values "") "" "")
((collect-garbage) (values "") "" "")
((define before (current-memory-use)) (values "") "" "")
((define scratch (device-matrix 1024 1024)) (values "") "" "")
((quotient (- (current-memory-use) before) (* 1024 1024)) (values "4\n") "" "")
((set! scratch #f) (values "") "" "")
((collect-garbage) (values "") "" "")
((< (- (current-memory-use) before) (* 1024 1024)) (values "#t\n") "" "")
