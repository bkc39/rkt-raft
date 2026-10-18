#lang racket/base

(require (only-in rackunit test-case)
         ;; whole-module: its syntax classes come with it
         syntax/parse/define)

(provide test-unless-skipped)

(define-syntax-parse-rule (test-unless-skipped reason:expr name:expr body:expr ...+)
  (let ([why reason])
    (if why
        (printf "SKIP: ~a: ~a\n" why name)
        (test-case name
          body ...))))
