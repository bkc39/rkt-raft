#lang info

#|review: ignore|#

(define collection "raft")
(define version "0.2.1")
(define native-version "0.2")
(define deps
  `("base" "math-lib" ("raft-x86_64-linux" #:platform "x86_64-linux" #:version ,native-version)))
(define build-deps
  '("datasets" "math-doc"
               "pict-lib"
               "polars"
               "racket-doc"
               "rackunit-lib"
               "sandbox-lib"
               "scribble-lib"))
(define scribblings '(("scribblings/raft.scrbl" (multi-page))))
(define pkg-desc "Racket bindings to NVIDIA RAFT: CUDA device arrays and primitives")
(define pkg-authors '(bkc))
(define license 'Apache-2.0)
(define pre-install-collection "private/install-native.rkt")
(define test-omit-paths
  (append '("scribblings" "tests/python")
          (if (getenv "PLT_PKG_BUILD_SERVICE")
              (list "tests/gpu"
                    "tests/private"
                    "array.rkt"
                    "compat.rkt"
                    "core.rkt"
                    "main.rkt"
                    "unsafe.rkt"
                    "private/abi.rkt"
                    "private/array.rkt"
                    "private/deposit.rkt"
                    "private/dtype.rkt"
                    "private/error.rkt"
                    "private/exit.rkt"
                    "private/foreign/array-api.rkt"
                    "private/foreign/array.rkt"
                    "private/foreign/core.rkt"
                    "private/foreign/deposit-api.rkt"
                    "private/foreign/internal.rkt"
                    "private/foreign/job-api.rkt"
                    "private/foreign/library.rkt"
                    "private/foreign/memory.rkt"
                    "private/job.rkt"
                    "private/pack.rkt"
                    "private/resources.rkt")
              '())))
(define test-timeouts '(("tests/gpu/exit-test.rkt" 360)))
