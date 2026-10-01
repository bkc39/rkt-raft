#lang racket/base

(require (only-in racket/format ~a ~r)
         (only-in racket/match match-define)
         (only-in "private/foreign/core.rkt" rr-abi rr-abi-tag->list rr-version))

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
  (match-define (list abi-version
                      raft-major raft-minor raft-patch
                      rmm-major rmm-minor rmm-patch
                      cccl-major cccl-minor cccl-patch
                      cuda-runtime resource-types handle-size)
    (rr-abi-tag->list (rr-abi)))
  (hasheq 'abi-version abi-version
          'raft (rapids-release raft-major raft-minor raft-patch)
          'rmm (rapids-release rmm-major rmm-minor rmm-patch)
          'cccl (~a cccl-major "." cccl-minor "." cccl-patch)
          'cuda-runtime (cuda-release cuda-runtime)
          'handle-size handle-size
          'resource-types resource-types))
