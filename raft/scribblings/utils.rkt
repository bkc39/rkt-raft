#lang racket/base

(require (for-label raft
                    racket/base
                    racket/format
                    racket/match
                    racket/string)
         (only-in racket/sandbox
                  sandbox-error-output
                  sandbox-eval-limits
                  sandbox-memory-limit
                  sandbox-output
                  sandbox-path-permissions
                  sandbox-security-guard)
         ;; whole-module: both are re-exported to every chapter
         scribble/example
         scribble/manual)

(provide (all-from-out scribble/example)
         (all-from-out scribble/manual)
         (for-label (all-from-out raft racket/base racket/format racket/match racket/string))
         make-raft-eval)

(define (make-raft-eval)
  (parameterize ([sandbox-output 'string]
                 [sandbox-error-output 'string]
                 [sandbox-memory-limit #f]
                 [sandbox-eval-limits #f]
                 [sandbox-security-guard current-security-guard]
                 [sandbox-path-permissions '((exists "/"))])
    (make-base-eval '(require raft
                              racket/format
                              racket/match
                              racket/string))))
