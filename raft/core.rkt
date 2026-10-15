#lang racket/base

(require (only-in "private/abi.rkt"
                  raft-abi
                  raft-abi-cccl
                  raft-abi-cuda-runtime
                  raft-abi-handle-size
                  raft-abi-raft
                  raft-abi-resource-types
                  raft-abi-rmm
                  raft-abi-version
                  raft-abi?)
         (only-in "private/foreign/core.rkt" rr-version))

(provide (all-from-out "private/abi.rkt")
         raft-version)

(define (raft-version)
  (rr-version))
