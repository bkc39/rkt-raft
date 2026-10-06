#lang racket/base

(require (only-in racket/flonum flvector in-flvector)
         (only-in racket/list range)
         (only-in rackunit check-eq? check-equal? check-exn check-false check-pred check-true)
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
         (only-in "../private/array.rkt" array-buffer-handle bound-view release-array!)
         (only-in "../private/error.rkt" call/raft)
         (only-in "../private/foreign/array-api.rkt" rr-array-contiguous)
         (only-in "../private/foreign/array.rkt"
                  blank-view
                  describe-view!
                  view-data
                  view-device
                  view-shape
                  view-strides)
         (only-in "../private/foreign/memory.rkt" buffer-drop-count)
         (only-in "private/arrays.rkt" storage)
         (only-in "private/collect.rkt" collect-until drain-finalizers!)
         (only-in "private/gpu.rkt" test-gpu)
         (only-in "private/raft-error.rkt" check-raft-error))

(define (flvector->list xs)
  (for/list ([x (in-flvector xs)])
    x))

(define all-dtypes '(float32 float64 int32 int64))
(define both-layouts '(row-major col-major))
(define sample '((1 2 3) (4 5 6)))

(define (float-dtype? d)
  (memq d '(float32 float64)))

(define (expected d xs)
  (if (float-dtype? d)
      (for/list ([row (in-list xs)])
        (map exact->inexact row))
      xs))

(define (other l)
  (if (eq? l 'row-major) 'col-major 'row-major))

(define (in-storage-order l rows)
  (if (eq? l 'row-major)
      (apply append rows)
      (apply append (apply map list rows))))

(test-gpu "device-matrix allocates every dtype in both layouts"
  (for* ([d (in-list all-dtypes)]
         [l (in-list both-layouts)])
    (define m (device-matrix 2 3 #:dtype d #:layout l))
    (check-equal? (list (shape m) (dtype m) (layout m) (numel m)) (list '(2 3) d l 6))
    (check-equal? (strides m)
                  (if (eq? l 'row-major)
                      '(3 1)
                      '(1 2)))
    (check-true (and (device-array? m) (device-matrix? m)))
    (check-false (device-vector? m))))

(test-gpu "device-matrix and device-vector default to float32, device-matrix to row-major"
  (define m (device-matrix 4 2))
  (check-equal? (list (dtype m) (layout m) (strides m)) '(float32 row-major (2 1)))
  (define v (device-vector 5))
  (check-equal? (list (shape v) (dtype v) (strides v) (numel v)) '((5) float32 (1) 5))
  (check-true (and (device-array? v) (device-vector? v)))
  (check-false (device-matrix? v))
  (check-false (device-array? '(1 2))))

(test-gpu "a vector, and a matrix of one row or one column, is in both layouts, as in NumPy"
  (define v (device-vector 3 #:dtype 'int32))
  (check-eq? (layout v) 'row-major)
  (check-eq? (contiguous v #:layout 'col-major) v)
  (define one (device-matrix 1 1 #:layout 'col-major))
  (check-eq? (layout one) 'row-major)
  (check-eq? (contiguous one #:layout 'row-major) one)
  (check-eq? (contiguous one #:layout 'col-major) one)
  (define column (device-matrix 5 1 #:layout 'col-major))
  (check-equal? (list (strides column) (layout column)) '((1 5) row-major))
  (check-eq? (contiguous column) column)
  (define row (device-matrix 1 5))
  (check-eq? (contiguous row #:layout 'col-major) row))

(test-gpu "contiguous returns its argument when the layout already matches"
  (define m (device-matrix 3 2 #:layout 'col-major))
  (check-eq? (contiguous m #:layout 'col-major) m)
  (define r (device-matrix 3 2))
  (check-eq? (contiguous r) r))

(test-gpu "contiguous changes the layout and keeps the matrix, for every dtype"
  (for* ([d (in-list all-dtypes)]
         [l (in-list both-layouts)])
    (define m (list*->device-matrix sample #:dtype d #:layout l))
    (define c (contiguous m #:layout (other l)))
    (check-equal? (layout c) (other l))
    (check-equal? (dtype c) d)
    (check-equal? (device-matrix->list* c) (expected d sample) (format "~a ~a" d l))
    (check-equal? (storage c) (in-storage-order (other l) (expected d sample)))
    (check-equal? (storage (contiguous c #:layout l)) (storage m))))

(test-gpu "a matrix with no elements has all strides 0, as NumPy's has, and is in both layouts"
  (define m (device-matrix 0 3 #:dtype 'int64 #:layout 'col-major))
  (check-equal? (list (shape m) (strides m) (layout m)) '((0 3) (0 0) row-major))
  (check-eq? (contiguous m #:layout 'col-major) m)
  (check-equal? (device-matrix->list* m) '()))

(test-gpu "nested lists round-trip in every dtype and layout"
  (for* ([d (in-list all-dtypes)]
         [l (in-list both-layouts)])
    (define m (list*->device-matrix sample #:dtype d #:layout l))
    (check-equal? (list (shape m) (layout m)) (list '(2 3) l))
    (check-equal? (device-matrix->list* m) (expected d sample))
    (check-equal? (storage m) (in-storage-order l (expected d sample)))))

(test-gpu "lists round-trip in every dtype"
  (for ([d (in-list all-dtypes)])
    (define v (list->device-vector '(3 1 4 1 5) #:dtype d))
    (check-equal? (dtype v) d)
    (check-equal? (device-vector->list v) (car (expected d '((3 1 4 1 5)))))))

(test-gpu "empty lists make empty arrays"
  (check-equal? (device-vector->list (list->device-vector '())) '())
  (check-equal? (dtype (list->device-vector '())) 'float64)
  (define m (list*->device-matrix '()))
  (check-equal? (list (shape m) (device-matrix->list* m)) '((0 0) ())))

(test-gpu "the dtype is inferred as NumPy infers it"
  (check-equal? (dtype (list->device-vector '(1 2 3))) 'int64)
  (check-equal? (dtype (list->device-vector '(1 2.5))) 'float64)
  (check-equal? (device-vector->list (list->device-vector '(1/2 3))) '(0.5 3.0))
  (check-equal? (dtype (list*->device-matrix '((1 2) (3 4)))) 'int64)
  (check-equal? (dtype (list*->device-matrix '((1 2) (3 4.0)))) 'float64))

(test-gpu "values come back as flonums from float arrays and exact integers from integer arrays"
  (check-pred (lambda (xs) (andmap flonum? xs))
              (device-vector->list (list->device-vector '(1 2) #:dtype 'float32)))
  (check-pred (lambda (xs) (andmap exact-integer? xs))
              (device-vector->list (list->device-vector '(1.0 2.0) #:dtype 'int32)))
  (check-equal? (device-vector->list (list->device-vector '(0.1) #:dtype 'float32))
                '(0.10000000149011612)))

(test-gpu "integer dtypes truncate toward zero, as NumPy's casts do"
  (check-equal? (device-vector->list (list->device-vector '(1.7 -1.7 5/2) #:dtype 'int64)) '(1 -1 2)))

(test-gpu "a ragged row raises an error naming the row"
  (check-raft-error 'logic
                    "list*->device-matrix: row 2 has 1 element, but row 0 has 2: '(5)"
                    (lambda () (list*->device-matrix '((1 2) (3 4) (5))))))

(test-gpu "a value the dtype cannot hold raises, naming the caller"
  (check-raft-error 'logic
                    "list->device-vector: 3000000000 does not fit int32"
                    (lambda () (list->device-vector '(3000000000) #:dtype 'int32)))
  (check-raft-error 'logic
                    "flvector->device-vector: +inf.0 is not a finite number"
                    (lambda () (flvector->device-vector (flvector +inf.0) #:dtype 'int32)))
  (check-raft-error 'logic
                    "list*->device-matrix: 1+2i is not a real number"
                    (lambda () (list*->device-matrix '((1 1+2i)) #:dtype 'float64))))

(test-gpu "a complex number has no dtype"
  (check-raft-error 'logic
                    "list->device-vector: cannot infer a dtype: 1+2i is not a real number"
                    (lambda () (list->device-vector '(1 1+2i))))
  (check-raft-error 'logic
                    "list*->device-matrix: cannot infer a dtype: 0+1i is not a real number"
                    (lambda () (list*->device-matrix '((1 2) (0+1i 4))))))

(test-gpu "flvectors cross directly as float64 and are packed for other dtypes"
  (define xs (flvector 1.5 -2.25 0.0 3.0))
  (define v (flvector->device-vector xs))
  (check-equal? (dtype v) 'float64)
  (check-equal? (flvector->list (device-vector->flvector v)) '(1.5 -2.25 0.0 3.0))
  (define narrow (flvector->device-vector xs #:dtype 'float32))
  (check-equal? (device-vector->list narrow) '(1.5 -2.25 0.0 3.0))
  (define ints (flvector->device-vector xs #:dtype 'int32))
  (check-equal? (device-vector->list ints) '(1 -2 0 3))
  (check-equal? (flvector->list (device-vector->flvector ints)) '(1.0 -2.0 0.0 3.0))
  (check-equal? (flvector->list (device-vector->flvector (flvector->device-vector (flvector)))) '()))

(test-gpu "special values survive the float64 round trip bit for bit"
  (define specials (list -0.0 +inf.0 -inf.0 +nan.0 4.9406564584124654e-324))
  (check-equal? (device-vector->list (list->device-vector specials)) specials)
  (check-equal? (flvector->list (device-vector->flvector (flvector->device-vector (apply flvector
                                                                                         specials))))
                specials))

(test-gpu "the shim refuses an unknown dtype or layout and a negative extent, naming the caller"
  (check-raft-error
   'logic
   "device-matrix: unsupported dtype float16; expected float32, float64, int32 or int64"
   (lambda () (device-matrix 2 2 #:dtype 'float16)))
  (check-raft-error
   'logic
   "device-vector: unsupported dtype complex64; expected float32, float64, int32 or int64"
   (lambda () (device-vector 2 #:dtype 'complex64)))
  (check-raft-error 'logic
                    "device-matrix: unsupported layout diagonal; expected row-major or col-major"
                    (lambda () (device-matrix 2 2 #:layout 'diagonal)))
  (check-raft-error 'logic "device-matrix: negative extent -2" (lambda () (device-matrix -2 2)))
  (check-raft-error
   'logic
   "list*->device-matrix: unsupported layout fortran; expected row-major or col-major"
   (lambda () (list*->device-matrix sample #:layout 'fortran)))
  (check-raft-error 'logic
                    "contiguous: unsupported layout fortran; expected row-major or col-major"
                    (lambda () (contiguous (device-matrix 2 2) #:layout 'fortran)))
  (check-raft-error
   'logic
   "flvector->device-vector: unsupported dtype float16; expected float32, float64, int32 or int64"
   (lambda () (flvector->device-vector (flvector 1.0) #:dtype 'float16))))

(test-gpu "arrays print their header and their values"
  (check-equal? (format "~a" (list*->device-matrix sample #:dtype 'float32))
                (string-append "#<device-matrix float32[2×3] row-major cuda:0\n"
                               " [[1.0 2.0 3.0]\n"
                               "  [4.0 5.0 6.0]]>"))
  (check-equal? (format "~a" (list->device-vector '(0.1 0.25) #:dtype 'float32))
                "#<device-vector float32[2] cuda:0 [ 0.1 0.25]>")
  (check-equal?
   (format "~a" (contiguous (list*->device-matrix '((1 -20)) #:dtype 'int32) #:layout 'col-major))
   "#<device-matrix int32[1×2] row-major cuda:0 [[  1 -20]]>")
  (check-equal? (format "~a" (device-matrix 0 3 #:dtype 'int64))
                "#<device-matrix int64[0×3] row-major cuda:0 []>"))

(test-gpu "large arrays print their edges"
  (define m
    (list*->device-matrix (for/list ([i (in-range 40)])
                            (for/list ([j (in-range 30)])
                              (+ (* 100 i) j)))
                          #:layout 'col-major))
  (check-equal? (format "~a" m)
                (string-append "#<device-matrix int64[40×30] col-major cuda:0\n"
                               " [[   0    1    2 ...   27   28   29]\n"
                               "  [ 100  101  102 ...  127  128  129]\n"
                               "  [ 200  201  202 ...  227  228  229]\n"
                               "  ...\n"
                               "  [3700 3701 3702 ... 3727 3728 3729]\n"
                               "  [3800 3801 3802 ... 3827 3828 3829]\n"
                               "  [3900 3901 3902 ... 3927 3928 3929]]>"))
  (check-equal? (format "~a" (list->device-vector (range 2000)))
                "#<device-vector int64[2000] cuda:0 [   0    1    2 ... 1997 1998 1999]>"))

(test-gpu "a buffer registers phantom bytes at its allocation's size"
  (define bytes (* 4096 4096 4))
  (drain-finalizers!)
  (define before (current-memory-use))
  (define m (device-matrix 4096 4096))
  (define held (- (current-memory-use) before))
  (check-true (<= bytes held (+ bytes (* 1024 1024))) (format "~a bytes counted" held))
  (check-equal? (numel m) (* 4096 4096))
  (set! m #f)
  (drain-finalizers!)
  (check-true (< (- (current-memory-use) before) (* 1024 1024))
              "the phantom bytes left with the array"))

(test-gpu "an unreachable array's buffer is freed by its finalizer"
  (drain-finalizers!)
  (define before (buffer-drop-count))
  (for ([_ (in-range 10)])
    (list->device-vector '(1 2 3)))
  (check-true (collect-until (lambda () (>= (buffer-drop-count) (+ before 10))))))

(test-gpu "an array, and its contiguous copy, outlive the resources they were made with"
  (define-values (m c)
    (with-device-resources ([r (device-resources)])
      (define m (list*->device-matrix sample #:resources r))
      (values m (contiguous m #:layout 'col-major))))
  (check-equal? (device-matrix->list* m) sample)
  (set! m #f)
  (drain-finalizers!)
  (check-equal? (device-matrix->list* c) sample))

(test-gpu "released resources are refused by the constructors, naming the caller"
  (define released (with-device-resources ([r (device-resources)]) r))
  (check-raft-error 'logic
                    "device-matrix: the device resources on device 0 were released"
                    (lambda () (device-matrix 2 2 #:resources released)))
  (check-raft-error 'logic
                    "list->device-vector: the device resources on device 0 were released"
                    (lambda () (list->device-vector '(1) #:resources released))))

(test-gpu "a released buffer is refused with the public noun, and its phantom bytes are dropped"
  (define bytes (* 1024 1024 8))
  (define v (device-vector (* 1024 1024) #:dtype 'int64))
  (drain-finalizers!)
  (define held (current-memory-use))
  (release-array! v)
  (check-true (>= (- held (current-memory-use)) (- bytes (* 64 1024))))
  (check-raft-error 'logic
                    "device-array: used after its release"
                    (lambda () (device-vector->list v))))

(test-gpu "a released array prints without raising, and never replaces another error"
  (define v (list->device-vector '(1 2 3)))
  (release-array! v)
  (check-equal? (format "~a" v) "#<device-vector int64[3] cuda:0 <released>>")
  (check-exn (lambda (e)
               (and (exn:fail:contract? e)
                    (regexp-match? #rx"^foo: contract violation" (exn-message e))))
             (lambda () (raise-argument-error 'foo "string?" v))))

(test-gpu "contiguous? says whether an array is in a layout, and a single row, column or no elements is in both"
  (define m (device-matrix 2 3))
  (check-equal? (list (contiguous? m) (contiguous? m #:layout 'col-major)) '(#t #f))
  (check-equal? (contiguous? (contiguous m #:layout 'col-major) #:layout 'col-major) #t)
  (for ([both (list (device-matrix 5 1)
                    (device-matrix 1 5 #:layout 'col-major)
                    (device-matrix 0 3)
                    (device-vector 4))])
    (check-equal? (list (contiguous? both) (contiguous? both #:layout 'col-major)) '(#t #t))))

(test-gpu "a finite value that overflows a float type is refused, naming the caller"
  (check-raft-error 'logic
                    "list->device-vector: 1e+300 does not fit float32"
                    (lambda () (list->device-vector '(1e300) #:dtype 'float32)))
  (check-raft-error 'logic
                    #rx"^list\\*->device-matrix: 1000+(\\.\\.\\.)? does not fit float64$"
                    (lambda () (list*->device-matrix (list (list (expt 10 400))) #:dtype 'float64)))
  (check-equal? (device-vector->list (list->device-vector '(+inf.0 -inf.0) #:dtype 'float32))
                '(+inf.0 -inf.0))
  (check-equal? (device-vector->list (list->device-vector '(3.4028234663852886e38) #:dtype 'float32))
                '(3.4028234663852886e38)))

(test-gpu "an array's bound view points into its buffer"
  (define m (list*->device-matrix '((1 2) (3 4)) #:dtype 'int32))
  (define view (bound-view 'test m))
  (check-true (and (view-data view) #t))
  (check-equal? (list (view-device view) (view-shape view) (view-strides view)) '(0 (2 2) (2 1))))

(test-gpu "an empty vector prints its header"
  (check-equal? (format "~a" (device-vector 0 #:dtype 'int32)) "#<device-vector int32[0] cuda:0 []>"))

(define (forged-contiguous a dtype-code shape strides [offset 0])
  (define source (describe-view! (blank-view) dtype-code shape strides))
  (call/raft 'contiguous
             (lambda ()
               (rr-array-contiguous (array-buffer-handle a) offset source 'col-major (blank-view)))))

(test-gpu "the shim refuses forged views instead of reading past the buffer"
  (define m (device-matrix 2 3))
  (check-raft-error 'logic
                    "contiguous: unsupported dtype code 7"
                    (lambda () (forged-contiguous m 7 '(2 3) '(3 1))))
  (check-raft-error 'logic
                    "contiguous: 36 bytes at byte offset 0 do not fit a buffer of 24 bytes"
                    (lambda () (forged-contiguous m 0 '(3 3) '(3 1))))
  (check-raft-error 'logic
                    "contiguous: unsupported strides: neither row-major nor col-major"
                    (lambda () (forged-contiguous m 0 '(2 2) '(3 1))))
  (check-raft-error 'logic
                    "contiguous: unsupported rank 1; expected a matrix"
                    (lambda () (forged-contiguous m 0 '(6) '(1))))
  (check-raft-error 'logic
                    "contiguous: byte offset 2 is not a multiple of the element size 4"
                    (lambda () (forged-contiguous m 0 '(1 1) '(1 1) 2)))
  (check-raft-error 'logic
                    "contiguous: negative stride -1"
                    (lambda () (forged-contiguous m 0 '(2 3) '(-1 1)))))
