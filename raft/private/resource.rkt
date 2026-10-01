#lang racket/base

(require syntax/parse/define
         (for-syntax racket/base))

(provide with-release)

;; The release runs on return, raise and escape; a thread killed inside the
;; extent never runs it, so the resource's finalizer stays the backstop.
(define-syntax-parser with-release
  [(_ () body:expr ...+)
   #'(let () body ...)]
  [(_ ([name:id acquire:expr release:expr] more ...) body:expr ...+)
   #'(let ([name #f])
       (dynamic-wind
        (lambda () (set! name acquire))
        (lambda () (with-release (more ...) body ...))
        (lambda ()
          (when name
            (release name)
            (set! name #f)))))])
