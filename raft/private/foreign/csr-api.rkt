#lang racket/base

(require (only-in ffi/unsafe _fun _int _int64 _uint64)
         (only-in "array.rkt" _rr-view-pointer)
         (only-in "library.rkt" _rr-buffer define-raft))

(provide rr-csr-check)

(define-raft rr-csr-check
  (_fun _rr-buffer
        _uint64
        _rr-view-pointer
        _rr-buffer
        _uint64
        _rr-view-pointer
        _rr-buffer
        _uint64
        _rr-view-pointer
        _int64
        _int64
        -> (status : _int)
        -> (zero? status)))
