#lang racket/base

(require (only-in ffi/unsafe
                  _bytes/nul-terminated
                  _double
                  _float
                  _fun
                  _int
                  _int16
                  _int32
                  _int64
                  _int8
                  _ptr
                  _uint16
                  _uint32
                  _uint64
                  _uint8
                  _void
                  ffi-lib)
         (only-in ffi/unsafe/define define-ffi-definer make-not-available)
         ;; whole-module: its syntax classes come with it
         syntax/parse/define
         (only-in "../../private/foreign/library.rkt" _rr-resources)
         (only-in "../../private/job.rkt" define-job)
         (only-in "../../unsafe.rkt" status-checker)
         (only-in "gate.rkt" gate-entered-fd gate-fd)
         (only-in "gpu.rkt" gpu-skip test-unless-skipped))

(provide call/probe
         gate-job
         probe-current-is-async?
         probe-echo-job
         probe-fail-job
         probe-gate-job
         probe-hold!
         probe-hold-views-job
         probe-late-static-job
         probe-library
         probe-mark-atexit!
         probe-open-after!
         probe-pool-used
         probe-release!
         probe-sleep-job
         probe-thread-id-job
         probe-token-job
         probe-tokens
         probe-tokens-clear!
         rr-probe-thread-id
         test-host-probe
         test-pools
         test-probe)

(define probe-path (getenv "RAFT_SHIM_PROBE"))

(define probe-library (and probe-path (ffi-lib probe-path)))

(define probe-skip ;; noqa
  (and (not probe-path) "no probe library (RAFT_SHIM_PROBE is not set; run inside nix develop)"))

(define-ffi-definer define-probe probe-library #:default-make-fail make-not-available)

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

(define call/probe (status-checker probe-last-error probe-last-error-kind))

(define-probe rr-probe-thread-id
              (_fun (out : (_ptr o _uint64)) -> (status : _int) -> (values status out))
              #:c-id rr_probe_thread_id)
(define-probe probe-token-count (_fun -> _int64) #:c-id rr_probe_token_count)
(define-probe probe-token-at (_fun _int64 -> _int32) #:c-id rr_probe_token_at)
(define-probe probe-tokens-clear! (_fun -> _void) #:c-id rr_probe_tokens_clear)
(define-probe probe-open-after! (_fun _int32 _int32 -> _void) #:c-id rr_probe_open_after)
(define-probe probe-mark-atexit! (_fun -> _void) #:c-id rr_probe_mark_atexit)

(define (probe-tokens)
  (for/list ([i (in-range (probe-token-count))])
    (probe-token-at i)))

(define-syntax-parse-rule (define-probe-job id:id c-id:str params:expr)
  (define id
    (if probe-library
        (let ()
          (define-job id probe-library c-id params)
          id)
        (lambda _ (error 'id "no probe library")))))

(define-probe-job probe-gate-job
                  "rr_probe_gate_job"
                  (_int32 _int32 _int32 _int32 _int32 (out _int32)))
(define-probe-job probe-echo-job
                  "rr_probe_echo_job"
                  (_int8 _int16
                         _int32
                         _int64
                         _uint8
                         _uint16
                         _uint32
                         _uint64
                         _float
                         _double
                         (out _int8)
                         (out _int16)
                         (out _int32)
                         (out _int64)
                         (out _uint8)
                         (out _uint16)
                         (out _uint32)
                         (out _uint64)
                         (out _float)
                         (out _double)))
(define-probe-job probe-fail-job "rr_probe_fail_job" (_int32 _int32 _int32))
(define-probe-job probe-token-job "rr_probe_token_job" (_int32))
(define-probe-job probe-sleep-job "rr_probe_sleep_job" (_int32))
(define-probe-job probe-late-static-job "rr_probe_late_static_job" (_int32 _int32 _int32))
(define-probe-job probe-thread-id-job "rr_probe_thread_id_job" ((out _uint64)))
(define-probe-job probe-hold-views-job
                  "rr_probe_hold_views_job"
                  (_int32 _int32 view view (out _int64)))

(define (gate-job who r g #:timeout-ms [timeout-ms 10000] #:say? [say? #f] #:fail-kind [fail-kind -1])
  (probe-gate-job who r (gate-entered-fd g) (gate-fd g) timeout-ms (if say? 1 0) fail-kind))

(define-syntax-parse-rule (test-host-probe name:expr body:expr ...+)
  (test-unless-skipped probe-skip name body ...))

(define-syntax-parse-rule (test-probe name:expr body:expr ...+)
  (test-unless-skipped (or gpu-skip probe-skip) name body ...))

(define-syntax-parse-rule (test-pools name:expr body:expr ...+)
  (test-unless-skipped (or gpu-skip probe-skip (pools-skip)) name body ...))
