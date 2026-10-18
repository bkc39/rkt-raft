#lang racket/base

(require (for-syntax racket/base
                     (only-in compiler/cm-accomplice register-external-file)))

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
         ;; whole-module: its syntax classes come with it
         syntax/parse/define
         (only-in "logged-eval.rkt" close-logged-eval docs-mode make-logged-eval))

(provide (except-out (all-from-out scribble/example) close-eval)
         (rename-out [close-logged-eval close-eval]) ;; noqa
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

(define-runtime-path logs-dir "logs") ;; noqa

(define-for-syntax (chapter-log-source chapter) ;; noqa
  (define-values (dir _name _dir?)
    (split-path (variable-reference->module-source (#%variable-reference))))
  (build-path dir "logs" (string-append chapter ".rktd")))

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

(define (live-downstream-eval) ;; noqa
  (define ev (live-raft-eval))
  (ev '(require ffi/unsafe
                ffi/unsafe/define
                ffi/unsafe/define/conventions
                raft/unsafe))
  ev)

(define-syntax-parse-rule (chapter-eval chapter:str live:id) ;; noqa
  #:do [(define log (chapter-log-source (syntax-e #'chapter)))
        (when (file-exists? log)
          (register-external-file log))]
  (make-logged-eval (docs-mode) (build-path logs-dir (string-append chapter ".rktd")) live))

(define-syntax-parse-rule (make-raft-eval chapter:str)
  (chapter-eval chapter live-raft-eval))

(define-syntax-parse-rule (make-downstream-eval chapter:str)
  (chapter-eval chapter live-downstream-eval))

(define (listing language . lines)
  (nested #:style 'code-inset (para (italic language)) (apply verbatim lines)))
