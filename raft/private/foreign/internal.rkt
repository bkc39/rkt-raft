#lang racket/base

(require (only-in ffi/unsafe _enum _fun _int _int32 _ptr)
         (only-in "library.rkt" define-raft))

(provide rr-memory-resource-kind)

(define-raft rr-memory-resource-kind
  (_fun _int32 (out : (_ptr o (_enum '(cuda cuda-async other) _int32 #:unknown (lambda (_) 'other))))
        -> (status : _int)
        -> (and (zero? status) out)))
