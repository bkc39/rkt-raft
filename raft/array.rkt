#lang racket/base

(require (only-in "private/resources.rkt" current-device-resources))

(provide contiguous
         device-array?
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
         numel
         shape
         strides)

(define (unimplemented who)
  (error who "unimplemented"))

(define (device-matrix rows
                       cols
                       #:dtype [dtype 'float32]
                       #:layout [layout 'row-major]
                       #:resources [resources (current-device-resources)])
  (unimplemented 'device-matrix))

(define (device-vector n #:dtype [dtype 'float32] #:resources [resources (current-device-resources)])
  (unimplemented 'device-vector))

(define (device-array? v)
  (unimplemented 'device-array?))

(define (device-matrix? v)
  (unimplemented 'device-matrix?))

(define (device-vector? v)
  (unimplemented 'device-vector?))

(define (shape a)
  (unimplemented 'shape))

(define (dtype a)
  (unimplemented 'dtype))

(define (strides a)
  (unimplemented 'strides))

(define (layout a)
  (unimplemented 'layout))

(define (numel a)
  (unimplemented 'numel))

(define (contiguous a #:layout [layout 'row-major])
  (unimplemented 'contiguous))

(define (list->device-vector xs #:dtype [dtype #f] #:resources [resources (current-device-resources)])
  (unimplemented 'list->device-vector))

(define (device-vector->list v)
  (unimplemented 'device-vector->list))

(define (list*->device-matrix rows
                              #:dtype [dtype #f]
                              #:layout [layout 'row-major]
                              #:resources [resources (current-device-resources)])
  (unimplemented 'list*->device-matrix))

(define (device-matrix->list* m)
  (unimplemented 'device-matrix->list*))

(define (flvector->device-vector xs
                                 #:dtype [dtype 'float64]
                                 #:resources [resources (current-device-resources)])
  (unimplemented 'flvector->device-vector))

(define (device-vector->flvector v)
  (unimplemented 'device-vector->flvector))
