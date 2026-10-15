#lang racket/base

(require (only-in ffi/unsafe _fun _int _int32 _int64 _list _ptr _size _symbol _uint64)
         (only-in "array.rkt" _rr-view-pointer)
         (only-in "host.rkt" _host host-bytes)
         (only-in "library.rkt" _rr-buffer _rr-buffer/null _rr-resources define-raft)
         (only-in "memory.rkt" buffer-allocator))

(provide rr-array-contiguous
         rr-array-create
         rr-buffer-read
         rr-buffer-ready
         rr-buffer-write)

(define-raft rr-array-create
  (_fun _rr-resources
        _symbol
        (rank : _int32 = (length shape))
        (shape : (_list i _int64))
        _symbol
        _rr-view-pointer
        (out : (_ptr o _rr-buffer/null))
        -> (status : _int)
        -> (and (zero? status) out))
  #:wrap buffer-allocator)

(define-raft rr-array-contiguous
  (_fun _rr-buffer _uint64 _rr-view-pointer _symbol _rr-view-pointer (out : (_ptr o _rr-buffer/null))
        -> (status : _int)
        -> (and (zero? status) out))
  #:wrap buffer-allocator)

(define-raft rr-buffer-ready
  (_fun _rr-buffer (out : (_ptr o _int32))
        -> (status : _int)
        -> (and (zero? status) (if (zero? out) 'pending 'ready))))

(define-raft rr-buffer-read
  (_fun _rr-buffer _uint64 (host : _host) (_size = (host-bytes host))
        -> (status : _int)
        -> (zero? status)))

(define-raft rr-buffer-write
  (_fun _rr-buffer _uint64 (host : _host) (_size = (host-bytes host))
        -> (status : _int)
        -> (zero? status)))
