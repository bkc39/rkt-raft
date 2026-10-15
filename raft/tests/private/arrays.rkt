#lang racket/base

(require (only-in "../../array.rkt" dtype numel)
         (only-in "../../private/array.rkt" read-array)
         (only-in "../../private/dtype.rkt" dtype-itemsize)
         (only-in "../../private/foreign/host.rkt" host-memory)
         (only-in "../../private/pack.rkt" unpack-vector))

(provide storage)

(define (storage a)
  (define n (numel a))
  (unpack-vector (dtype a) n (read-array 'storage a (host-memory (* n (dtype-itemsize (dtype a)))))))
