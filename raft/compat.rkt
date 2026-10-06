#lang racket/base

(require (only-in "array.rkt"
                  device-matrix->list*
                  device-vector->flvector
                  device-vector->list
                  flvector->device-vector
                  list*->device-matrix
                  list->device-vector)
         (only-in "private/resources.rkt" current-device-resources))

(provide array->device-array
         bytes->device-vector
         device-array->array
         device-array->list*
         device-array->vector*
         device-matrix->list* ;; noqa
         device-matrix->matrix
         device-matrix->vector*
         device-vector->bytes
         device-vector->col-matrix
         device-vector->f32vector
         device-vector->f64vector
         device-vector->flvector ;; noqa
         device-vector->list ;; noqa
         device-vector->row-matrix
         device-vector->vector
         f32vector->device-vector
         f64vector->device-vector
         flvector->device-vector ;; noqa
         list*->device-array
         list*->device-matrix ;; noqa
         list->device-vector ;; noqa
         matrix->device-matrix
         matrix->device-vector
         vector*->device-array
         vector*->device-matrix
         vector->device-vector)

(define (unimplemented who)
  (error who "unimplemented"))

(define (vector->device-vector xs
                               #:dtype [element-type #f]
                               #:resources [resources (current-device-resources)])
  (unimplemented 'vector->device-vector))

(define (device-vector->vector v)
  (unimplemented 'device-vector->vector))

(define (vector*->device-matrix rows
                                #:dtype [element-type #f]
                                #:layout [order 'row-major]
                                #:resources [resources (current-device-resources)])
  (unimplemented 'vector*->device-matrix))

(define (device-matrix->vector* m)
  (unimplemented 'device-matrix->vector*))

(define (list*->device-array xs
                             #:dtype [element-type #f]
                             #:layout [order 'row-major]
                             #:resources [resources (current-device-resources)])
  (unimplemented 'list*->device-array))

(define (vector*->device-array xs
                               #:dtype [element-type #f]
                               #:layout [order 'row-major]
                               #:resources [resources (current-device-resources)])
  (unimplemented 'vector*->device-array))

(define (device-array->list* a)
  (unimplemented 'device-array->list*))

(define (device-array->vector* a)
  (unimplemented 'device-array->vector*))

(define (f32vector->device-vector xs
                                  #:dtype [element-type 'float32]
                                  #:resources [resources (current-device-resources)])
  (unimplemented 'f32vector->device-vector))

(define (f64vector->device-vector xs
                                  #:dtype [element-type 'float64]
                                  #:resources [resources (current-device-resources)])
  (unimplemented 'f64vector->device-vector))

(define (device-vector->f32vector v)
  (unimplemented 'device-vector->f32vector))

(define (device-vector->f64vector v)
  (unimplemented 'device-vector->f64vector))

(define (bytes->device-vector bs
                              #:dtype element-type
                              #:resources [resources (current-device-resources)])
  (unimplemented 'bytes->device-vector))

(define (device-vector->bytes v)
  (unimplemented 'device-vector->bytes))

(define (matrix->device-matrix m
                               #:dtype [element-type #f]
                               #:layout [order 'row-major]
                               #:resources [resources (current-device-resources)])
  (unimplemented 'matrix->device-matrix))

(define (device-matrix->matrix m)
  (unimplemented 'device-matrix->matrix))

(define (matrix->device-vector m
                               #:dtype [element-type #f]
                               #:resources [resources (current-device-resources)])
  (unimplemented 'matrix->device-vector))

(define (device-vector->col-matrix v)
  (unimplemented 'device-vector->col-matrix))

(define (device-vector->row-matrix v)
  (unimplemented 'device-vector->row-matrix))

(define (array->device-array arr
                             #:dtype [element-type #f]
                             #:layout [order 'row-major]
                             #:resources [resources (current-device-resources)])
  (unimplemented 'array->device-array))

(define (device-array->array a)
  (unimplemented 'device-array->array))
