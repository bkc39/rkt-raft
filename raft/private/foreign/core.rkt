#lang racket/base

(require (only-in ffi/unsafe
                  _bytes/nul-terminated
                  _enum
                  _fun
                  _int
                  _int32
                  _int64
                  _ptr
                  _string/utf-8
                  define-cstruct)
         (only-in "library.rkt" _rr-resources _rr-resources/null define-raft)
         (only-in "memory.rkt" resources-allocator))

(provide rr-abi
         rr-abi-tag->list
         rr-device-count
         rr-last-error
         rr-last-error-kind
         rr-resources-create
         rr-resources-ready
         rr-resources-sync
         rr-version)

(define-cstruct _rr-abi-tag
  ([abi-version _int32]
   [raft-major _int32]
   [raft-minor _int32]
   [raft-patch _int32]
   [rmm-major _int32]
   [rmm-minor _int32]
   [rmm-patch _int32]
   [cccl-major _int32]
   [cccl-minor _int32]
   [cccl-patch _int32]
   [cuda-runtime _int32]
   [resource-types _int32]
   [handle-size _int64]))

(define-raft rr-last-error
  (_fun -> _bytes/nul-terminated))

(define-raft rr-last-error-kind
  (_fun -> (_enum '(generic out-of-memory cuda logic) _int
                  #:unknown (lambda (_) 'generic))))

(define-raft rr-version
  (_fun -> _string/utf-8))

(define-raft rr-abi
  (_fun -> _rr-abi-tag-pointer))

(define-raft rr-device-count
  (_fun (out : (_ptr o _int32)) -> (status : _int) -> (and (zero? status) out)))

(define-raft rr-resources-create
  (_fun _int32 (out : (_ptr o _rr-resources/null))
        -> (status : _int)
        -> (and (zero? status) out))
  #:wrap resources-allocator)

(define-raft rr-resources-sync
  (_fun _rr-resources -> (status : _int) -> (zero? status)))

(define-raft rr-resources-ready
  (_fun _rr-resources (out : (_ptr o _int32))
        -> (status : _int)
        -> (and (zero? status) (if (zero? out) 'pending 'ready))))
