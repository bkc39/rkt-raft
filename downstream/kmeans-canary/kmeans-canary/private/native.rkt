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
         (only-in raft/unsafe define-job raft-abi-pointer status-checker))

(provide call/kc
         canary-path
         kc-check-abi
         kc-cluster-members-job
         kc-current-is-async
         kc-device-memory
         kc-fit-job
         kc-make-blobs-job
         kc-noop
         kc-noop-job
         kc-owner-drop-count
         kc-owner-stale-count
         kc-pool-bytes
         kc-pool-reset-high
         kc-predict-job
         kc-sleep-job)

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

(define-kc kc-noop (_fun _int32 (out : (_ptr o _int32)) -> (status : _int) -> (values status out)))

(define-job kc-make-blobs-job
            canary-library
            "kc_make_blobs_job"
            (handle view view _int32 _double _int32 _double _double _uint64))
(define-job
 kc-fit-job
 canary-library
 "kc_fit_job"
 (handle view view view _int32 _int32 _double _int32 _double _uint64 (out _double) (out _int32)))
(define-job kc-predict-job
            canary-library
            "kc_predict_job"
            (handle view view view _int32 view (out _double)))
(define-job kc-noop-job canary-library "kc_noop_job" (_int32 (out _int32)))
(define-job kc-sleep-job canary-library "kc_sleep_job" (_int32))

(define-job kc-cluster-members-job
            canary-library
            "kc_cluster_members_job"
            (handle view view _int32 deposit))

(define-kc kc-owner-drop-count (_fun -> _uint64))
(define-kc kc-owner-stale-count (_fun -> _uint64))

(define-kc kc-current-is-async
  (_fun _int32 (out : (_ptr o _int32)) -> (status : _int) -> (values status (= out 1))))

(define-kc kc-pool-bytes
  (_fun _int32 (used : (_ptr o _int64)) (high : (_ptr o _int64)) (reserved : (_ptr o _int64))
        -> (status : _int)
        -> (values status used high reserved)))

(define-kc kc-pool-reset-high (_fun _int32 -> _int))

(define-kc kc-device-memory
  (_fun _int32 (free-bytes : (_ptr o _int64)) (total : (_ptr o _int64))
        -> (status : _int)
        -> (values status free-bytes total)))

(call/kc 'kmeans-canary (lambda () (kc-check-abi (raft-abi-pointer))))
