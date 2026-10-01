#lang racket/base

(require (only-in racket/format ~a ~r)
         (only-in "private/foreign/core.rkt"
                  rr-abi
                  rr-abi-tag-abi-version
                  rr-abi-tag-cccl-major
                  rr-abi-tag-cccl-minor
                  rr-abi-tag-cccl-patch
                  rr-abi-tag-cuda-runtime
                  rr-abi-tag-handle-size
                  rr-abi-tag-raft-major
                  rr-abi-tag-raft-minor
                  rr-abi-tag-raft-patch
                  rr-abi-tag-resource-types
                  rr-abi-tag-rmm-major
                  rr-abi-tag-rmm-minor
                  rr-abi-tag-rmm-patch
                  rr-version))

(provide raft-abi
         raft-version)

(define (raft-version)
  (rr-version))

(define (two-digits n)
  (~r n #:min-width 2 #:pad-string "0"))

(define (rapids-release major minor patch)
  (~a (two-digits major) "." (two-digits minor) "." (two-digits patch)))

(define (cuda-release code)
  (~a (quotient code 1000) "." (quotient (remainder code 1000) 10)))

(define (raft-abi)
  (define tag (rr-abi))
  (hasheq 'abi-version (rr-abi-tag-abi-version tag)
          'raft (rapids-release (rr-abi-tag-raft-major tag)
                                (rr-abi-tag-raft-minor tag)
                                (rr-abi-tag-raft-patch tag))
          'rmm (rapids-release (rr-abi-tag-rmm-major tag)
                               (rr-abi-tag-rmm-minor tag)
                               (rr-abi-tag-rmm-patch tag))
          'cccl (~a (rr-abi-tag-cccl-major tag) "."
                    (rr-abi-tag-cccl-minor tag) "."
                    (rr-abi-tag-cccl-patch tag))
          'cuda-runtime (cuda-release (rr-abi-tag-cuda-runtime tag))
          'handle-size (rr-abi-tag-handle-size tag)
          'resource-types (rr-abi-tag-resource-types tag)))
