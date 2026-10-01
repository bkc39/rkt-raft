#lang racket/base

(require (only-in ffi/unsafe _enum _fun _int _int32 _ptr)
         (only-in "library.rkt" _rr-resources define-raft))

(provide rr-memory-resource-kind
         rr-resources-ready)

(define-raft rr-resources-ready
  (_fun _rr-resources (out : (_ptr o _int32))
        -> (status : _int)
        -> (and (zero? status) (if (zero? out) 'pending 'ready))))

(define-raft rr-memory-resource-kind
  (_fun _int32 (out : (_ptr o (_enum '(cuda cuda-async other) _int32 #:unknown (lambda (_) 'other))))
        -> (status : _int)
        -> (and (zero? status) out)))
