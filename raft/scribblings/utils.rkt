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
    (make-base-eval '(require raft
                              racket/flonum
                              racket/format
                              racket/list
                              racket/match
                              racket/string))))

(define (make-downstream-eval)
  (define ev (make-raft-eval))
  (ev '(require ffi/unsafe ffi/unsafe/define ffi/unsafe/define/conventions raft/unsafe))
  ev)

(define (listing language . lines)
  (nested #:style 'code-inset (para (italic language)) (apply verbatim lines)))

(define (python . lines)
  (apply listing "Python" lines))

(define (status leg)
  (elem #:style (style #f (list (color-property "gray"))) leg))
