((list->device-vector '(1.5 -2.25 0.0))
 (values "#<device-vector float64[3] cuda:0 [  1.5 -2.25   0.0]>\n")
 ""
 "")
((list->device-vector '(3 1 4) #:dtype 'int32)
 (values "#<device-vector int32[3] cuda:0 [3 1 4]>\n")
 ""
 "")
((list*->device-matrix '((1 2 3) (4 5 6)))
 (values
  "#<device-matrix int64[2×3] row-major cuda:0\n [[1 2 3]\n  [4 5 6]]>\n")
 ""
 "")
((define m
   (list*->device-matrix
    '((1 2 3) (4 5 6))
    #:dtype
    'float32
    #:layout
    'col-major))
 (values "")
 ""
 "")
(m
 (values
  "#<device-matrix float32[2×3] col-major cuda:0\n [[1.0 2.0 3.0]\n  [4.0 5.0 6.0]]>\n")
 ""
 "")
((define out (device-matrix 1000 128 #:dtype 'float64)) (values "") "" "")
((list (shape out) (dtype out) (layout out))
 (values "'((1000 128) float64 row-major)\n")
 ""
 "")
((define labels (device-vector 1000 #:dtype 'int32)) (values "") "" "")
((list (shape labels) (dtype labels)) (values "'((1000) int32)\n") "" "")
((list (shape m) (dtype m) (layout m) (strides m) (numel m))
 (values "'((2 3) float32 col-major (1 2) 6)\n")
 ""
 "")
((list (contiguous? m) (contiguous? m #:layout 'col-major))
 (values "'(#f #t)\n")
 ""
 "")
((strides (contiguous m)) (values "'(3 1)\n") "" "")
((device-matrix->list* m) (values "'((1.0 2.0 3.0) (4.0 5.0 6.0))\n") "" "")
((device-vector->flvector (list->device-vector '(0.5 1.5)))
 (values "(flvector 0.5 1.5)\n")
 ""
 "")
((define r (device-resources)) (values "") "" "")
(r (values "#<device-resources device 0>\n") "" "")
((resources-device r) (values "0\n") "" "")
((eq? (current-device-resources) (current-device-resources))
 (values "#t\n")
 ""
 "")
((eq? r (current-device-resources)) (values "#f\n") "" "")
((with-device-resources
  ((scoped (device-resources #:device 0)))
  (resources-sync! scoped)
  (resources-device scoped))
 (values "0\n")
 ""
 "")
