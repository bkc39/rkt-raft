#lang racket/base

(require syntax/parse/define
         (only-in rackunit test-case)
         (only-in "../../private/error.rkt" call/raft exn:fail:raft?)
         (only-in "../../private/foreign/core.rkt" rr-device-count))

(provide gpu-available?
         gpu-skip-reason
         skip
         test-gpu)

(define gpu-skip-reason
  (with-handlers ([exn:fail:raft? exn-message])
    (and (zero? (call/raft 'gpu-available? rr-device-count))
         "the driver reports no CUDA device")))

(define (gpu-available?)
  (not gpu-skip-reason))

(define (skip why name)
  (printf "SKIP: ~a: ~a\n" why name))

(define-syntax-parse-rule (test-gpu name:expr body:expr ...+)
  (if gpu-skip-reason
      (skip (format "no GPU (~a)" gpu-skip-reason) name)
      (test-case name body ...)))
