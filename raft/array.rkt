#lang racket/base

(require (only-in racket/flonum for/flvector flvector-length in-flvector make-flvector)
         (only-in racket/list append*)
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
         (only-in "private/pack.rkt"
                  infer-dtype
                  matrix-shape
                  pack-matrix
                  pack-vector
                  unpack-matrix
                  unpack-vector)
         (only-in "private/resources.rkt" current-device-resources))

(provide contiguous
         device-array? ;; noqa
         device-matrix
         device-matrix->list*
         device-matrix?
         device-vector
         device-vector->flvector
         device-vector->list
         device-vector?
         dtype
         flvector->device-vector
         layout
         list*->device-matrix
         list->device-vector
         numel ;; noqa
         shape
         strides)

(define (device-matrix rows
                       cols
                       #:dtype [element-type 'float32]
                       #:layout [order 'row-major]
                       #:resources [resources (current-device-resources)])
  (allocate-array 'device-matrix resources element-type order (list rows cols)))

(define (device-vector n
                       #:dtype [element-type 'float32]
                       #:resources [resources (current-device-resources)])
  (allocate-array 'device-vector resources element-type 'row-major (list n)))

(define (device-matrix? v)
  (and (device-array? v) (= (array-rank v) 2)))

(define (device-vector? v)
  (and (device-array? v) (= (array-rank v) 1)))

(define (shape a)
  (device-array-shape a))

(define (dtype a)
  (device-array-dtype a))

(define (strides a)
  (device-array-strides a))

(define (layout a)
  (strides->layout (device-array-shape a) (device-array-strides a)))

(define (contiguous a #:layout [order 'row-major])
  (if (has-layout? a order)
      a
      (contiguous-array 'contiguous a order)))

(define (list->device-vector xs
                             #:dtype [element-type #f]
                             #:resources [resources (current-device-resources)])
  (define who 'list->device-vector)
  (define n (length xs))
  (define v (allocate-array who resources (or element-type (infer-dtype who xs)) 'row-major (list n)))
  (write-array! who v (pack-vector (device-array-dtype v) n xs)))

(define (device-vector->list v)
  (match-define (list n) (device-array-shape v))
  (unpack-vector (device-array-dtype v) n (read-all 'device-vector->list v)))

(define (list*->device-matrix rows
                              #:dtype [element-type #f]
                              #:layout [order 'row-major]
                              #:resources [resources (current-device-resources)])
  (define who 'list*->device-matrix)
  (define extents (matrix-shape who rows))
  (define m
    (allocate-array who resources (or element-type (infer-dtype who (append* rows))) order extents))
  (write-array!
   who
   m
   (pack-matrix (device-array-dtype m) (device-array-shape m) (device-array-strides m) rows)))

(define (device-matrix->list* m)
  (unpack-matrix (device-array-dtype m)
                 (device-array-shape m)
                 (device-array-strides m)
                 (read-all 'device-matrix->list* m)))

(define (flvector->device-vector xs
                                 #:dtype [element-type 'float64]
                                 #:resources [resources (current-device-resources)])
  (define who 'flvector->device-vector)
  (define n (flvector-length xs))
  (define v (allocate-array who resources element-type 'row-major (list n)))
  (write-array! who
                v
                (if (eq? (device-array-dtype v) 'float64)
                    xs
                    (pack-vector (device-array-dtype v) n (in-flvector xs)))))

(define (device-vector->flvector v)
  (define who 'device-vector->flvector)
  (match-define (list n) (device-array-shape v))
  (if (eq? (device-array-dtype v) 'float64)
      (read-array who v (make-flvector n))
      (for/flvector #:length n
                    ([x (in-list (unpack-vector (device-array-dtype v) n (read-all who v)))])
                    (real->double-flonum x))))
