#lang racket/base

(require (only-in ffi/unsafe _fun _int32 _int64 _void ffi-lib)
         (only-in ffi/unsafe/define define-ffi-definer make-not-available)
         (only-in "../../private/foreign/library.rkt" _rr-resources)
         (only-in "gpu.rkt" gpu-skip test-unless-skipped)
         ;; whole-module: its syntax classes come with it
         syntax/parse/define)

(provide probe-current-is-async?
         probe-hold!
         probe-pool-used
         probe-release!
         test-probe)

(define probe-path (getenv "RAFT_SHIM_PROBE"))

(define probe-skip
  (and (not probe-path)
       "no probe library (RAFT_SHIM_PROBE is not set; run inside nix develop)"))

(define-ffi-definer define-probe (and probe-path (ffi-lib probe-path))
  #:default-make-fail make-not-available)

(define-probe probe-current-is-async?
  (_fun _int32 -> (answer : _int32) -> (= answer 1))
  #:c-id rr_probe_current_is_async)

(define-probe probe-pool-used
  (_fun _int32 -> _int64)
  #:c-id rr_probe_pool_used_bytes)

(define-probe probe-hold!
  (_fun _rr-resources -> (answer : _int32) -> (= answer 1))
  #:c-id rr_probe_hold)

(define-probe probe-release!
  (_fun -> _void)
  #:c-id rr_probe_release)

(define-syntax-parse-rule (test-probe name:expr body:expr ...+)
  (test-unless-skipped (or gpu-skip probe-skip) name body ...))
