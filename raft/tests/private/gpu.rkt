#lang racket/base

(require (only-in rackunit test-case)
         ;; whole-module: its syntax classes come with it
         syntax/parse/define
         (only-in "../../private/error.rkt" call/raft exn:fail:raft?)
         (only-in "../../private/foreign/core.rkt" rr-device-count))

(provide gpu-available?
         gpu-skip
         test-gpu
         test-unless-skipped
         test-without-gpu)

(define gpu-skip-reason
  (with-handlers ([exn:fail:raft? exn-message])
    (and (zero? (call/raft 'gpu-available? rr-device-count)) "the driver reports no CUDA device")))

(define gpu-skip (and gpu-skip-reason (format "no GPU (~a)" gpu-skip-reason)))

(define (gpu-available?)
  (not gpu-skip-reason))

(define-syntax-parse-rule (test-unless-skipped reason:expr name:expr body:expr ...+)
  (let ([why reason])
    (if why
        (printf "SKIP: ~a: ~a\n" why name)
        (test-case name
          body ...))))

(define-syntax-parse-rule (test-gpu name:expr body:expr ...+)
  (test-unless-skipped gpu-skip name body ...))

(define-syntax-parse-rule (test-without-gpu name:expr body:expr ...+)
  (test-unless-skipped (and (gpu-available?) "a GPU is present") name body ...))
