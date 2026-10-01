#lang racket/base

(require (for-syntax racket/base)
         ;; whole-module: it also provides syntax/parse at phase 1
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
   #'(let ([held #f])
       (dynamic-wind
        (lambda () (set! held b.acquire))
        (lambda () (let ([b.name held]) (with-release (more ...) body ...)))
        (lambda ()
          (when held
            (b.release held)
            (set! held #f)))))])
