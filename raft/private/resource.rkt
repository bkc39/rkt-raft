#lang racket/base

(require (for-syntax racket/base)
         ;; whole-module: it also provides syntax/parse at phase 1
         syntax/parse/define
         (only-in "exn.rkt" exn:fail:raft))

(provide with-release)

(begin-for-syntax
  (define-syntax-class release-binding
    #:description "a [name acquire release] binding"
    (pattern [name:id acquire:expr release:expr])))

(define (refuse-reentry) ;; noqa
  (raise (exn:fail:raft "with-release: cannot re-enter its body after its resources were released"
                        (current-continuation-marks)
                        'logic)))

;; The acquire runs once, outside the extent, so control that jumps back into
;; the body (a generator resume) cannot acquire again. The release runs on
;; every exit; a thread killed inside the extent never runs it, so the
;; resource's finalizer stays the backstop.
(define-syntax-parser with-release
  [(_ () body:expr ...+)
   #'(let ()
       body ...)]
  [(_ (b:release-binding more:release-binding ...) body:expr ...+)
   #'(let ([held b.acquire]
           [entered? #f])
       (dynamic-wind (lambda ()
                       (when entered?
                         (refuse-reentry))
                       (set! entered? #t))
                     (lambda () (let ([b.name held]) (with-release (more ...) body ...)))
                     (lambda ()
                       (when held
                         (b.release held)
                         (set! held #f)))))])
