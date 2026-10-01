#lang racket/base

(require racket/sandbox
         scribble/core
         scribble/example
         scribble/manual
         (for-label raft
                    racket/base
                    racket/format
                    racket/string))

(provide (all-from-out scribble/example)
         (all-from-out scribble/manual)
         (for-label (all-from-out raft racket/base racket/format racket/string))
         make-raft-eval
         python
         status)

(define (make-raft-eval)
  (parameterize ([sandbox-output 'string]
                 [sandbox-error-output 'string]
                 [sandbox-memory-limit #f]
                 [sandbox-eval-limits #f]
                 [sandbox-security-guard current-security-guard]
                 [sandbox-path-permissions '((exists "/"))])
    (make-base-eval '(require raft racket/format racket/string))))

(define (python . lines)
  (nested #:style 'code-inset
          (para (italic "Python"))
          (apply verbatim lines)))

(define (status leg)
  (elem #:style (style #f (list (color-property "gray"))) leg))
