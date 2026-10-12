#lang racket/base

(require (only-in ffi/unsafe
                  _bytes/nul-terminated
                  _fun
                  _int
                  _int32
                  _int64
                  _pointer
                  _uint32
                  _uint64
                  _void
                  ffi-lib)
         (only-in ffi/unsafe/define define-ffi-definer make-not-available)
         ;; whole-module: its syntax classes come with it
         syntax/parse/define
         (only-in "../../private/foreign/library.rkt" _rr-resources)
         (only-in "../../unsafe.rkt" status-checker)
         (only-in "gpu.rkt" gpu-skip test-unless-skipped))

(provide call/probe
         probe-current-is-async?
         probe-deposit
         probe-flags
         probe-hold!
         probe-owner-drops
         probe-owner-stale
         probe-pool-used
         probe-release!
         test-pools
         test-probe)

(define probe-path (getenv "RAFT_SHIM_PROBE"))

(define probe-skip ;; noqa
  (and (not probe-path) "no probe library (RAFT_SHIM_PROBE is not set; run inside nix develop)"))

(define-ffi-definer define-probe
                    (and probe-path (ffi-lib probe-path))
                    #:default-make-fail make-not-available)

(define-probe probe-current-is-async?
              (_fun _int32 -> (answer : _int32) -> (= answer 1))
              #:c-id rr_probe_current_is_async)

(define-probe probe-pools-supported?
              (_fun _int32 -> (answer : _int32) -> (= answer 1))
              #:c-id rr_probe_pools_supported)

(define (pools-skip) ;; noqa
  (and (not (probe-pools-supported? 0)) "no memory-pool support on device 0"))

(define-probe probe-pool-used (_fun _int32 -> _int64) #:c-id rr_probe_pool_used_bytes)

(define-probe probe-hold!
              (_fun _rr-resources -> (answer : _int32) -> (= answer 1))
              #:c-id rr_probe_hold)

(define-probe probe-release! (_fun -> _void) #:c-id rr_probe_release)

(define-probe probe-last-error (_fun -> _bytes/nul-terminated) #:c-id rr_probe_last_error)
(define-probe probe-last-error-kind (_fun -> _int) #:c-id rr_probe_last_error_kind)

(define-probe probe-deposit
              (_fun #:blocking? #t _pointer _pointer _int32 _int32 _int64 _int64 _uint32 -> _int)
              #:c-id rr_probe_deposit)

(define-probe probe-owner-drops (_fun -> _uint64) #:c-id rr_probe_owner_drops)
(define-probe probe-owner-stale (_fun -> _uint64) #:c-id rr_probe_owner_stale)

(define call/probe (status-checker probe-last-error probe-last-error-kind))

(define flag-bits
  (hasheq 'col-major 1
          'fail-after 2
          'wait 4
          'twice 8
          'overlap 16
          'raw 32
          'misalign 64
          'host 128
          'rank3 256))

(define (probe-flags . names)
  (apply bitwise-ior 0 (map (lambda (name) (hash-ref flag-bits name)) names)))

(define-syntax-parse-rule (test-probe name:expr body:expr ...+)
  (test-unless-skipped (or gpu-skip probe-skip) name body ...))

(define-syntax-parse-rule (test-pools name:expr body:expr ...+)
  (test-unless-skipped (or gpu-skip probe-skip (pools-skip)) name body ...))
