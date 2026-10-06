#lang racket/base

(require (only-in ffi/unsafe
                  _bytes/nul-terminated
                  _double
                  _fun
                  _int
                  _int32
                  _int64
                  _pointer
                  _ptr
                  _uint64
                  ffi-lib)
         (only-in ffi/unsafe/define define-ffi-definer)
         (only-in ffi/unsafe/define/conventions convention:hyphen->underscore)
         (only-in raft exn:fail:raft)
         (only-in raft/unsafe raft-abi-pointer status-checker))

(provide call/kc
         canary-path
         kc-check-abi
         kc-current-is-async
         kc-fit
         kc-make-blobs
         kc-pool-bytes
         kc-pool-reset-high
         kc-predict)

(define canary-path (getenv "RAFT_KMEANS_CANARY"))

(define canary-library
  (if canary-path
      (ffi-lib canary-path)
      (raise
       (exn:fail:raft
        "kmeans-canary: the canary library is not built; set RAFT_KMEANS_CANARY to libkmeans_canary.so (nix develop sets it from packages.kmeans-canary)"
        (current-continuation-marks)
        'generic))))

(define-ffi-definer define-kc canary-library #:make-c-id convention:hyphen->underscore)

(define-kc kc-last-error (_fun -> _bytes/nul-terminated))
(define-kc kc-last-error-kind (_fun -> _int))

(define call/kc (status-checker kc-last-error kc-last-error-kind))

(define-kc kc-check-abi (_fun _pointer -> _int))

(define-kc kc-fit
  (_fun _pointer
        _pointer
        _pointer
        _pointer
        _int32
        _int32
        _double
        _int32
        _double
        _uint64
        (inertia : (_ptr o _double))
        (n-iter : (_ptr o _int32))
        -> (status : _int)
        -> (values status inertia n-iter)))

(define-kc kc-predict
  (_fun _pointer _pointer _pointer _pointer _int32 _pointer (inertia : (_ptr o _double))
        -> (status : _int)
        -> (values status inertia)))

(define-kc kc-make-blobs
  (_fun _pointer _pointer _pointer _int32 _double _int32 _double _double _uint64 -> _int))

(define-kc kc-current-is-async
  (_fun _int32 (out : (_ptr o _int32)) -> (status : _int) -> (values status (= out 1))))

(define-kc kc-pool-bytes
  (_fun _int32 (used : (_ptr o _int64)) (high : (_ptr o _int64)) (reserved : (_ptr o _int64))
        -> (status : _int)
        -> (values status used high reserved)))

(define-kc kc-pool-reset-high (_fun _int32 -> _int))

(call/kc 'kmeans-canary (lambda () (kc-check-abi (raft-abi-pointer))))
