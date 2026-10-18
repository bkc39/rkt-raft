#lang racket/base

(require (only-in racket/match match-define)
         ;; whole-module: its syntax classes come with it
         syntax/parse/define)

(provide call-with-environment-variables
         with-environment-variables)

(define (call-with-environment-variables bindings thunk)
  (parameterize ([current-environment-variables
                  (environment-variables-copy (current-environment-variables))])
    (for ([binding (in-list bindings)])
      (match-define (cons name value) binding)
      (environment-variables-set! (current-environment-variables)
                                  (string->bytes/utf-8 name)
                                  (and value (string->bytes/utf-8 value))))
    (thunk)))

(define-syntax-parse-rule (with-environment-variables ([name:expr value:expr] ...) body:expr ...+)
  (call-with-environment-variables (list (cons name value) ...)
                                   (lambda ()
                                     body ...)))
