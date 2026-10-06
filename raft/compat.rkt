#lang racket/base

(require (only-in math/array
                  array->vector
                  array-shape
                  flarray-data
                  mutable-array-data
                  mutable-array?
                  settable-array?
                  unsafe-flarray
                  vector->array)
         (only-in racket/flonum flvector? for/flvector make-flvector)
         (only-in racket/match match match-define)
         (only-in "array.rkt"
                  device-matrix->list*
                  device-vector->flvector
                  device-vector->list
                  flvector->device-vector
                  list*->device-matrix
                  list->device-vector)
         (only-in "private/array.rkt"
                  allocate-array
                  device-array-dtype
                  device-array-shape
                  device-array-strides
                  has-layout?
                  numel
                  read-all
                  read-array
                  write-array!)
         (only-in "private/dtype.rkt" dtype-itemsize dtypes)
         (only-in "private/exn.rkt" raise-raft)
         (only-in "private/foreign/host.rkt"
                  f32vector->host
                  f64vector->host
                  host->f32vector
                  host->f64vector
                  host-bytes)
         (only-in "private/pack.rkt"
                  infer-dtype
                  infer-rows-dtype
                  matrix-shape
                  pack-matrix
                  pack-row-major
                  repack
                  unpack-matrix
                  unpack-row-major
                  unpack-vector)
         (only-in "private/resources.rkt" current-device-resources))

(provide (all-from-out "array.rkt")
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
         device-vector->row-matrix
         device-vector->vector
         f32vector->device-vector
         f64vector->device-vector
         list*->device-array
         matrix->device-matrix
         matrix->device-vector
         vector*->device-array
         vector*->device-matrix
         vector->device-vector)

(define (send-flat who resources element-type order extents xs)
  (define a
    (allocate-array who
                    resources
                    (or element-type
                        (if (flvector? xs)
                            'float64
                            (infer-dtype who xs)))
                    order
                    extents))
  (define d (device-array-dtype a))
  (write-array! who
                a
                (if (and (flvector? xs) (eq? d 'float64) (has-layout? a 'row-major))
                    xs
                    (pack-row-major who d (device-array-shape a) (device-array-strides a) xs))))

(define (send-rows who resources element-type order rows)
  (define extents (matrix-shape who rows))
  (define m
    (allocate-array who resources (or element-type (infer-rows-dtype who rows)) order extents))
  (write-array!
   who
   m
   (pack-matrix who (device-array-dtype m) (device-array-shape m) (device-array-strides m) rows)))

(define (receive who a into)
  (define host (read-all who a))
  (match (device-array-shape a)
    [(list n) (unpack-vector (device-array-dtype a) n host #:into into)]
    [extents
     (unpack-matrix (device-array-dtype a) extents (device-array-strides a) host #:into into)]))

(define (raise-rank who rank)
  (raise-raft who
              'logic
              "rank ~a is not supported yet; rank 1 and 2 convert, and any rank arrives in leg 3"
              rank))

(define (list-like? v)
  (or (pair? v) (null? v)))

(define (nesting-depth xs nested?)
  (let loop ([x xs]
             [depth 0])
    (match x
      [_
       #:when (not (nested? x))
       depth]
      [(or (vector) '()) (add1 depth)]
      [(cons head _) (loop head (add1 depth))]
      [(? vector?) (loop (vector-ref x 0) (add1 depth))])))

(define (nested-rank who xs nested? noun)
  (define rank (nesting-depth xs nested?))
  (case rank
    [(1)
     (for ([x xs]
           [i (in-naturals)]
           #:when (nested? x))
       (raise-raft who 'logic "element ~a is a ~a, but element 0 is not: ~e" i noun x))]
    [(2)
     (for ([row xs]
           [i (in-naturals)]
           #:unless (nested? row))
       (raise-raft who 'logic "row ~a is not a ~a, but row 0 is: ~e" i noun row))]
    [else (raise-rank who rank)])
  rank)

(define (send-nested who resources element-type order xs nested? noun extent)
  (if (= 1 (nested-rank who xs nested? noun))
      (send-flat who resources element-type order (list (extent xs)) xs)
      (send-rows who resources element-type order xs)))

(define (vector->device-vector xs
                               #:dtype [element-type #f]
                               #:resources [resources (current-device-resources)])
  (send-flat 'vector->device-vector resources element-type 'row-major (list (vector-length xs)) xs))

(define (device-vector->vector v)
  (match-define (list n) (device-array-shape v))
  (unpack-vector (device-array-dtype v) n (read-all 'device-vector->vector v) #:into 'vector))

(define (vector*->device-matrix rows
                                #:dtype [element-type #f]
                                #:layout [order 'row-major]
                                #:resources [resources (current-device-resources)])
  (send-rows 'vector*->device-matrix resources element-type order rows))

(define (device-matrix->vector* m)
  (unpack-matrix (device-array-dtype m)
                 (device-array-shape m)
                 (device-array-strides m)
                 (read-all 'device-matrix->vector* m)
                 #:into 'vector))

(define (list*->device-array xs
                             #:dtype [element-type #f]
                             #:layout [order 'row-major]
                             #:resources [resources (current-device-resources)])
  (send-nested 'list*->device-array resources element-type order xs list-like? "list" length))

(define (vector*->device-array xs
                               #:dtype [element-type #f]
                               #:layout [order 'row-major]
                               #:resources [resources (current-device-resources)])
  (send-nested 'vector*->device-array resources element-type order xs vector? "vector" vector-length))

(define (device-array->list* a)
  (receive 'device-array->list* a 'list))

(define (device-array->vector* a)
  (receive 'device-array->vector* a 'vector))

(define (send-packed who resources element-type own-type host)
  (define n (quotient (host-bytes host) (dtype-itemsize own-type)))
  (define v (allocate-array who resources element-type 'row-major (list n)))
  (define d (device-array-dtype v))
  (write-array! who
                v
                (if (eq? d own-type)
                    host
                    (repack who own-type d n host))))

(define (f32vector->device-vector xs
                                  #:dtype [element-type 'float32]
                                  #:resources [resources (current-device-resources)])
  (send-packed 'f32vector->device-vector resources element-type 'float32 (f32vector->host xs)))

(define (f64vector->device-vector xs
                                  #:dtype [element-type 'float64]
                                  #:resources [resources (current-device-resources)])
  (send-packed 'f64vector->device-vector resources element-type 'float64 (f64vector->host xs)))

(define (receive-packed who v own-type)
  (match-define (list n) (device-array-shape v))
  (define d (device-array-dtype v))
  (define host (read-all who v))
  (if (eq? d own-type)
      host
      (repack who d own-type n host)))

(define (device-vector->f32vector v)
  (host->f32vector (numel v) (receive-packed 'device-vector->f32vector v 'float32)))

(define (device-vector->f64vector v)
  (host->f64vector (numel v) (receive-packed 'device-vector->f64vector v 'float64)))

(define (bytes->device-vector bs
                              #:dtype element-type
                              #:resources [resources (current-device-resources)])
  (define who 'bytes->device-vector)
  (define size
    (if (memq element-type dtypes)
        (dtype-itemsize element-type)
        1))
  (define-values (n extra) (quotient/remainder (bytes-length bs) size))
  (unless (zero? extra)
    (raise-raft who
                'logic
                "~a bytes do not hold a whole number of ~a-byte ~a elements"
                (bytes-length bs)
                size
                element-type))
  (write-array! who (allocate-array who resources element-type 'row-major (list n)) bs))

(define (device-vector->bytes v)
  (match-define (list n) (device-array-shape v))
  (read-array 'device-vector->bytes v (make-bytes (* n (dtype-itemsize (device-array-dtype v))))))

(define (flarray-flonums arr)
  (with-handlers ([exn:fail:contract? (lambda (_) #f)])
    (flarray-data arr)))

(define (array-elements arr)
  (cond
    [(mutable-array? arr) (mutable-array-data arr)]
    [(and (settable-array? arr) (flarray-flonums arr))]
    [else (array->vector arr)]))

(define (array-extents arr)
  (vector->list (array-shape arr)))

(define (array->device-array arr
                             #:dtype [element-type #f]
                             #:layout [order 'row-major]
                             #:resources [resources (current-device-resources)])
  (define who 'array->device-array)
  (define extents (array-extents arr))
  (unless (memv (length extents) '(1 2))
    (raise-rank who (length extents)))
  (send-flat who resources element-type order extents (array-elements arr)))

(define (matrix->device-matrix m
                               #:dtype [element-type #f]
                               #:layout [order 'row-major]
                               #:resources [resources (current-device-resources)])
  (match-define (list rows cols) (array-extents m))
  (send-flat 'matrix->device-matrix resources element-type order (list rows cols) (array-elements m)))

(define (matrix->device-vector m
                               #:dtype [element-type #f]
                               #:resources [resources (current-device-resources)])
  (define who 'matrix->device-vector)
  (define n
    (match (array-extents m)
      [(list 1 n) n]
      [(list n 1) n]
      [(list rows cols)
       (raise-raft who 'logic "a ~a×~a matrix is neither a row nor a column matrix" rows cols)]))
  (send-flat who resources element-type 'row-major (list n) (array-elements m)))

(define (row-major-flonums who a)
  (define n (numel a))
  (if (and (eq? (device-array-dtype a) 'float64) (has-layout? a 'row-major))
      (read-array who a (make-flvector n))
      (for/flvector #:length n ([x (in-vector (row-major-elements who a))]) x)))

(define (row-major-elements who a)
  (unpack-row-major (device-array-dtype a)
                    (device-array-shape a)
                    (device-array-strides a)
                    (read-all who a)))

(define (math-array who a extents)
  (define ds (apply vector-immutable extents))
  (if (memq (device-array-dtype a) '(float32 float64))
      (unsafe-flarray ds (row-major-flonums who a))
      (vector->array ds (row-major-elements who a))))

(define (device-array->array a)
  (math-array 'device-array->array a (device-array-shape a)))

(define (device-matrix->matrix m)
  (math-array 'device-matrix->matrix m (device-array-shape m)))

(define (device-vector->col-matrix v)
  (match-define (list n) (device-array-shape v))
  (math-array 'device-vector->col-matrix v (list n 1)))

(define (device-vector->row-matrix v)
  (match-define (list n) (device-array-shape v))
  (math-array 'device-vector->row-matrix v (list 1 n)))
