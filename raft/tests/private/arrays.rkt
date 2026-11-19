#lang racket/base

(require (only-in racket/match match)
         (only-in "../../array.rkt"
                  device-matrix
                  dtype
                  list*->device-matrix
                  list->device-vector
                  numel)
         (only-in "../../private/array.rkt" read-array)
         (only-in "../../private/dtype.rkt" dtype-itemsize)
         (only-in "../../private/foreign/host.rkt" host-memory)
         (only-in "../../private/pack.rkt" unpack-vector))

(provide part
         storage)

(define (part spec)
  (match spec
    [(list 'blank element-type rows cols) (device-matrix rows cols #:dtype element-type)]
    [(list* 'matrix element-type rows) (list*->device-matrix rows #:dtype element-type)]
    [(cons element-type xs) (list->device-vector xs #:dtype element-type)]))

(define (storage a)
  (define n (numel a))
  (unpack-vector (dtype a) n (read-array 'storage a (host-memory (* n (dtype-itemsize (dtype a)))))))
