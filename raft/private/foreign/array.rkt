#lang racket/base

(require (only-in ffi/unsafe _fun _int _pointer _ptr _size)
         (only-in "library.rkt" _rr-buffer _rr-buffer/null _rr-resources define-raft)
         (only-in "memory.rkt" buffer-allocator))

(provide rr-buffer-alloc
         rr-copy-d2h
         rr-copy-h2d)

(define-raft rr-buffer-alloc
  (_fun _rr-resources _size (out : (_ptr o _rr-buffer/null))
        -> (status : _int)
        -> (and (zero? status) out))
  #:wrap buffer-allocator)

(define-raft rr-copy-h2d
  (_fun _rr-buffer _pointer _size -> (status : _int) -> (zero? status)))

(define-raft rr-copy-d2h
  (_fun _pointer _rr-buffer _size -> (status : _int) -> (zero? status)))
