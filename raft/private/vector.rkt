#lang racket/base

(require (only-in racket/match match-define)
         (only-in "array.rkt"
                  allocate-array
                  device-array-dtype
                  device-array-shape
                  read-all
                  read-array
                  write-array!)
         (only-in "dtype.rkt" dtype-itemsize)
         (only-in "foreign/host.rkt" host-memory)
         (only-in "pack.rkt" pack-vector unpack-vector))

(provide read-block
         read-vector
         upload-vector)

(define (upload-vector who resources dtype xs)
  (define n (length xs))
  (define v (allocate-array who resources dtype 'row-major (list n)))
  (write-array! who v (pack-vector who (device-array-dtype v) n xs)))

(define (read-vector who v)
  (match-define (list n) (device-array-shape v))
  (unpack-vector (device-array-dtype v) n (read-all who v)))

(define (read-block who v start count)
  (define dtype (device-array-dtype v))
  (unpack-vector dtype count (read-array who v (host-memory (* count (dtype-itemsize dtype))) start)))
