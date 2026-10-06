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
         (only-in racket/file file->lines)
         (only-in racket/list drop index-where take)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path
         (only-in racket/sandbox
                  sandbox-error-output
                  sandbox-eval-limits
                  sandbox-memory-limit
                  sandbox-output
                  sandbox-path-permissions
                  sandbox-security-guard)
         (only-in racket/string string-join string-prefix?)
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
         excerpt
         listing
         make-downstream-eval
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

(define (make-downstream-eval)
  (define ev (make-raft-eval))
  (ev '(require ffi/unsafe
                ffi/unsafe/define
                ffi/unsafe/define/conventions
                raft/unsafe))
  ev)

(define (listing language . lines)
  (nested #:style 'code-inset (para (italic language)) (apply verbatim lines)))

(define-runtime-path repository "../..")

(define (excerpt language file from to #:before [before 0])
  (define lines (file->lines (build-path repository file)))
  (define found (index-where lines (lambda (line) (string-prefix? line from))))
  (unless found
    (error 'excerpt "~a has no line starting ~s" file from))
  (define start (- found before))
  (define span (index-where (drop lines found) (lambda (line) (string=? line to))))
  (unless span
    (error 'excerpt "~a has no line ~s after ~s" file to from))
  (listing language (string-join (take (drop lines start) (+ before span 1)) "\n")))

(define (status leg)
  (elem #:style (style #f (list (color-property "gray"))) leg))
