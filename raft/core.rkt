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
         (only-in "private/error.rkt"
                  call/raft
                  exn:fail:raft
                  exn:fail:raft-kind
                  exn:fail:raft?
                  struct:exn:fail:raft)
         (only-in "private/foreign/core.rkt" rr-device-count rr-version)
         (only-in "private/resources.rkt"
                  current-device-resources
                  device-resources
                  device-resources?
                  resources-device
                  resources-sync!
                  with-device-resources))

(provide (all-from-out "private/abi.rkt")
         (all-from-out "private/resources.rkt")
         device-count
         (struct-out exn:fail:raft) ;; noqa
         raft-version)

(define (device-count)
  (call/raft 'device-count rr-device-count))

(define (raft-version)
  (rr-version))
