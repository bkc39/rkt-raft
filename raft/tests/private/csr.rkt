#lang racket/base

(require (only-in "../../main.rkt" csr-data csr-indices csr-indptr device-vector->list))

(provide parts)

(define (parts m)
  (map device-vector->list (list (csr-indptr m) (csr-indices m) (csr-data m))))
