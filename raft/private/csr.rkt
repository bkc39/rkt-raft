#lang racket/base

(provide csr-data
         csr-indices
         csr-indptr
         device-csr-matrix
         device-csr-matrix->list*
         device-csr-matrix->triplets
         device-csr-matrix-data
         device-csr-matrix-shape
         device-csr-matrix?
         list*->device-csr-matrix
         nnz
         parts->device-csr-matrix ;; noqa
         triplets->device-csr-matrix)

(struct device-csr-matrix (indptr indices data shape)
  #:constructor-name parts->device-csr-matrix
  #:omit-define-syntaxes)

(define (unimplemented who)
  (error who "unimplemented"))

(define (device-csr-matrix indptr indices data #:shape extents)
  (unimplemented 'device-csr-matrix))

(define (csr-indptr m)
  (unimplemented 'csr-indptr))

(define (csr-indices m)
  (unimplemented 'csr-indices))

(define (csr-data m)
  (unimplemented 'csr-data))

(define (nnz m)
  (unimplemented 'nnz))

(define (list*->device-csr-matrix rows
                                  #:dtype [element-type 'float64]
                                  #:index-dtype [index-type 'int32]
                                  #:resources [resources #f])
  (unimplemented 'list*->device-csr-matrix))

(define (device-csr-matrix->list* m)
  (unimplemented 'device-csr-matrix->list*))

(define (triplets->device-csr-matrix rows
                                     cols
                                     vals
                                     #:shape extents
                                     #:dtype [element-type 'float64]
                                     #:index-dtype [index-type 'int32]
                                     #:resources [resources #f])
  (unimplemented 'triplets->device-csr-matrix))

(define (device-csr-matrix->triplets m)
  (unimplemented 'device-csr-matrix->triplets))
