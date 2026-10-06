#lang racket/base

(require (for-label ffi/vector
                    json
                    math/array
                    math/matrix
                    raft
                    raft/compat
                    racket/base
                    racket/file
                    racket/flonum
                    racket/format
                    racket/list
                    racket/match
                    racket/port
                    racket/string
                    racket/vector)
         (only-in racket/sandbox
                  sandbox-error-output
                  sandbox-eval-limits
                  sandbox-memory-limit
                  sandbox-output
                  sandbox-path-permissions
                  sandbox-security-guard)
         (only-in scribble/core color-property style)
         ;; whole-module: both are re-exported to every chapter
         scribble/example
         scribble/manual)

(provide (all-from-out scribble/example)
         (all-from-out scribble/manual)
         (for-label (all-from-out ffi/vector
                                  json
                                  math/array
                                  math/matrix
                                  raft
                                  raft/compat
                                  racket/base
                                  racket/file
                                  racket/flonum
                                  racket/format
                                  racket/list
                                  racket/match
                                  racket/port
                                  racket/string
                                  racket/vector))
         make-raft-eval
         status)

(define (make-raft-eval)
  (parameterize ([sandbox-output 'string]
                 [sandbox-error-output 'string]
                 [sandbox-memory-limit #f]
                 [sandbox-eval-limits #f]
                 [sandbox-security-guard current-security-guard]
                 [sandbox-path-permissions '((exists "/"))])
    (make-base-eval '(require raft
                              racket/flonum
                              racket/format
                              racket/list
                              racket/match
                              racket/string))))

(define (status leg)
  (elem #:style (style #f (list (color-property "gray"))) leg))
