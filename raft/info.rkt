#lang info

#|review: ignore|#

(define collection "raft")
(define version "0.1")
(define deps '("base" "math-lib"))
(define build-deps '("math-doc" "racket-doc" "rackunit-lib" "sandbox-lib" "scribble-lib"))
(define scribblings '(("scribblings/raft.scrbl" (multi-page))))
(define pkg-desc "Racket bindings to NVIDIA RAFT: CUDA device arrays and primitives")
(define pkg-authors '(bkc))
(define license 'Apache-2.0)
(define pre-install-collection "private/install-native.rkt")
(define test-omit-paths '("scribblings" "tests/python"))
