#lang racket/base

(require (only-in ffi/unsafe _fun _int _int32 _ptr)
         (only-in "array.rkt" _rr-view-pointer)
         (only-in "library.rkt"
                  _rr-buffer/null
                  _rr-deposit/null
                  _rr-holder
                  _rr-holder/null
                  _rr-resources
                  define-raft)
         (only-in "memory.rkt" buffer-allocator holder-allocator))

(provide rr-holder-adopt
         rr-holder-close
         rr-holder-count
         rr-holder-create
         rr-holder-record)

(define-raft rr-holder-create
  (_fun _rr-resources (out : (_ptr o _rr-holder/null)) -> (status : _int) -> (and (zero? status) out))
  #:wrap holder-allocator)

(define-raft rr-holder-record
  (_fun _rr-holder (out : (_ptr o _rr-deposit/null)) -> (status : _int) -> (and (zero? status) out)))

(define-raft rr-holder-close (_fun _rr-holder -> (status : _int) -> (zero? status)))

(define-raft rr-holder-count
  (_fun _rr-holder (out : (_ptr o _int32)) -> (status : _int) -> (and (zero? status) out)))

(define-raft rr-holder-adopt
  (_fun _rr-holder _int32 _rr-view-pointer (out : (_ptr o _rr-buffer/null))
        -> (status : _int)
        -> (and (zero? status) out))
  #:wrap buffer-allocator)
