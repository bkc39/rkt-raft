#lang racket/base

;; whole-module: define-runtime-path needs bindings only-in strips
(require racket/runtime-path)

(provide native-libs-dir)

(define-runtime-path native-libs-dir "native-libs")
