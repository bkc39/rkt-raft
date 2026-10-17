#lang racket/base

(require (for-label (only-in ffi/unsafe
                             _bytes/nul-terminated
                             _double
                             _fun
                             _int
                             _int32
                             _int64
                             _pointer
                             _ptr
                             _uint64
                             cpointer?
                             ffi-lib
                             memcpy
                             ptr-equal?
                             ptr-ref
                             ptr-set!)
                    ffi/unsafe/define
                    ffi/unsafe/define/conventions
                    ffi/vector
                    json
                    math/array
                    math/matrix
                    raft
                    raft/compat
                    raft/unsafe
                    racket/base
                    racket/file
                    racket/flonum
                    racket/format
                    racket/list
                    racket/match
                    racket/port
                    racket/string
                    racket/vector)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path
         (only-in racket/sandbox
                  sandbox-error-output
                  sandbox-eval-limits
                  sandbox-memory-limit
                  sandbox-output
                  sandbox-path-permissions
                  sandbox-security-guard)
         ;; whole-module: both are re-exported to every chapter
         scribble/example
         scribble/manual
         (only-in "logged-eval.rkt" docs-mode make-logged-eval))

(provide (all-from-out scribble/example)
         (all-from-out scribble/manual)
         (for-label (all-from-out ffi/unsafe
                                  ffi/unsafe/define
                                  ffi/unsafe/define/conventions
                                  ffi/vector
                                  json
                                  math/array
                                  math/matrix
                                  raft
                                  raft/compat
                                  raft/unsafe
                                  racket/base
                                  racket/file
                                  racket/flonum
                                  racket/format
                                  racket/list
                                  racket/match
                                  racket/port
                                  racket/string
                                  racket/vector))
         listing
         make-downstream-eval
         make-raft-eval)

(define-runtime-path logs-dir "logs")

(define (chapter-log name)
  (build-path logs-dir (format "~a.rktd" name)))

(define (live-raft-eval)
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

(define (live-downstream-eval)
  (define ev (live-raft-eval))
  (ev '(require ffi/unsafe
                ffi/unsafe/define
                ffi/unsafe/define/conventions
                raft/unsafe))
  ev)

(define (make-raft-eval name)
  (make-logged-eval (docs-mode) (chapter-log name) live-raft-eval))

(define (make-downstream-eval name)
  (make-logged-eval (docs-mode) (chapter-log name) live-downstream-eval))

(define (listing language . lines)
  (nested #:style 'code-inset (para (italic language)) (apply verbatim lines)))
