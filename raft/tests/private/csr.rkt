#lang racket/base

(require (only-in "../../main.rkt"
                  csr-data
                  csr-indices
                  csr-indptr
                  device-csr-matrix->triplets
                  device-vector->list))

(provide parts
         triplets)

(define (parts m)
  (map device-vector->list (list (csr-indptr m) (csr-indices m) (csr-data m))))

(define (triplets m)
  (call-with-values (lambda () (device-csr-matrix->triplets m)) list))
