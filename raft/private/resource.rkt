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

(define reentry-message "cannot re-enter its body after its resources were released")

(define (refuse-reentry who)
  (raise (exn:fail:raft (if who
                            (format "~a: ~a" who reentry-message)
                            reentry-message)
                        (current-continuation-marks)
                        'logic)))

;; The acquired value arrives already evaluated, outside the extent, so control
;; that jumps back into the body (a generator resume) cannot acquire again. The
;; release runs on every exit; a thread killed inside the extent never runs it,
;; so the resource's finalizer stays the backstop.
(define (call-with-release who acquired release proc) ;; noqa
  (define held acquired)
  (define entered? #f)
  (dynamic-wind (lambda ()
                  (when entered?
                    (refuse-reentry who))
                  (set! entered? #t))
                (lambda () (proc acquired))
                (lambda ()
                  (when held
                    (release held)
                    (set! held #f)))))

(define-syntax-parser with-release
  [(_ (~optional (~seq #:who who:expr) #:defaults ([who #'#f])) () body:expr ...+)
   #'(let ()
       body ...)]
  [(_ (~optional (~seq #:who who:expr) #:defaults ([who #'#f]))
      (b:release-binding more:release-binding ...)
      body:expr ...+)
   #'(call-with-release who
                        b.acquire
                        b.release
                        (lambda (b.name) (with-release #:who who (more ...) body ...)))])
