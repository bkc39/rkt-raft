#lang racket/base

(require (for-syntax racket/base
                     ;; whole-module: syntax-parse needs its syntax classes
                     syntax/parse)
         ;; whole-module: its syntax classes come with it
         syntax/parse/define)

(provide with-release)

(begin-for-syntax
  (define-syntax-class release-binding
    #:description "a [name acquire release] binding"
    (pattern [name:id acquire:expr release:expr])))

;; The release runs on return, raise and escape; a thread killed inside the
;; extent never runs it, so the resource's finalizer stays the backstop.
(define-syntax-parser with-release
  [(_ () body:expr ...+)
   #'(let () body ...)]
  [(_ (b:release-binding more:release-binding ...) body:expr ...+)
   #'(let ([b.name #f])
       (dynamic-wind
        (lambda () (set! b.name b.acquire))
        (lambda () (with-release (more ...) body ...))
        (lambda ()
          (when b.name
            (b.release b.name)
            (set! b.name #f)))))])
