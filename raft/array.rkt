#lang racket/base

(require (only-in racket/flonum for/flvector flvector-length in-flvector make-flvector)
         (only-in racket/match match-define)
         (only-in "private/array.rkt"
                  allocate-array
                  array-rank
                  contiguous-array
                  device-array-dtype
                  device-array-shape
                  device-array-strides
                  device-array?
                  has-layout?
                  numel
                  read-all
                  read-array
                  strides->layout
                  write-array!)
         (only-in "private/csr.rkt"
                  csr-data
                  csr-indices
                  csr-indptr
                  device-csr-matrix
                  device-csr-matrix->list*
                  device-csr-matrix->triplets
                  device-csr-matrix-shape
                  device-csr-matrix?
                  list*->device-csr-matrix
                  nnz
                  triplets->device-csr-matrix)
         (only-in "private/gather.rkt" compare gather select)
         (only-in "private/pack.rkt"
                  infer-dtype
                  infer-rows-dtype
                  matrix-shape
                  pack-matrix
                  pack-vector
                  unpack-matrix)
         (only-in "private/resources.rkt" define/resources)
         (only-in "private/vector.rkt" read-vector upload-vector))

(provide compare ;; noqa
         contiguous
         contiguous?
         csr-data ;; noqa
         csr-indices ;; noqa
         csr-indptr ;; noqa
         device-array? ;; noqa
         device-csr-matrix ;; noqa
         device-csr-matrix->list* ;; noqa
         device-csr-matrix->triplets ;; noqa
         device-csr-matrix? ;; noqa
         device-matrix
         device-matrix->list*
         device-matrix?
         device-vector
         device-vector->flvector
         device-vector->list
         device-vector?
         dtype
         flvector->device-vector
         gather ;; noqa
         layout
         list*->device-csr-matrix ;; noqa
         list*->device-matrix
         list->device-vector
         nnz ;; noqa
         numel ;; noqa
         select ;; noqa
         shape
         strides
         triplets->device-csr-matrix) ;; noqa

(define/resources (device-matrix rows
                                 cols
                                 #:dtype [element-type 'float32]
                                 #:layout [order 'row-major]
                                 #:resources resources
                                 #:who who)
  (allocate-array who resources element-type order (list rows cols)))

(define/resources (device-vector n #:dtype [element-type 'float32] #:resources resources #:who who)
  (allocate-array who resources element-type 'row-major (list n)))

(define (device-matrix? v)
  (and (device-array? v) (= (array-rank v) 2)))

(define (device-vector? v)
  (and (device-array? v) (= (array-rank v) 1)))

(define (shape a)
  (cond
    [(device-csr-matrix? a) (device-csr-matrix-shape a)]
    [else (device-array-shape a)]))

(define (dtype a)
  (cond
    [(device-csr-matrix? a) (device-array-dtype (csr-data a))]
    [else (device-array-dtype a)]))

(define (strides a)
  (device-array-strides a))

(define (layout a)
  (strides->layout (device-array-shape a) (device-array-strides a)))

(define (contiguous? a #:layout [order 'row-major])
  (has-layout? a order))

(define (contiguous a #:layout [order 'row-major])
  (if (has-layout? a order)
      a
      (contiguous-array 'contiguous a order)))

(define/resources (list->device-vector xs #:dtype [element-type #f] #:resources resources #:who who)
  (upload-vector who resources (or element-type (infer-dtype who xs)) xs))

(define (device-vector->list v)
  (read-vector 'device-vector->list v))

(define/resources (list*->device-matrix rows
                                        #:dtype [element-type #f]
                                        #:layout [order 'row-major]
                                        #:cols [cols #f]
                                        #:resources resources
                                        #:who who)
  (define extents (matrix-shape who rows cols))
  (define m
    (allocate-array who resources (or element-type (infer-rows-dtype who rows)) order extents))
  (write-array!
   who
   m
   (pack-matrix who (device-array-dtype m) (device-array-shape m) (device-array-strides m) rows)))

(define (device-matrix->list* m)
  (unpack-matrix (device-array-dtype m)
                 (device-array-shape m)
                 (device-array-strides m)
                 (read-all 'device-matrix->list* m)))

(define/resources (flvector->device-vector xs
                                           #:dtype [element-type 'float64]
                                           #:resources resources
                                           #:who who)
  (define n (flvector-length xs))
  (define v (allocate-array who resources element-type 'row-major (list n)))
  (write-array! who
                v
                (if (eq? (device-array-dtype v) 'float64)
                    xs
                    (pack-vector who (device-array-dtype v) n (in-flvector xs)))))

(define (device-vector->flvector v)
  (define who 'device-vector->flvector)
  (match-define (list n) (device-array-shape v))
  (if (eq? (device-array-dtype v) 'float64)
      (read-array who v (make-flvector n))
      (for/flvector #:length n ([x (in-list (read-vector who v))]) (real->double-flonum x))))
