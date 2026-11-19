#lang racket/base

(require (for-syntax racket/base)
         ;; whole-module: it also provides syntax/parse at phase 1
         syntax/parse/define
         (only-in "exn.rkt" exn:fail:raft))

(provide call-with-release
         with-release)

(begin-for-syntax
  (define-syntax-class release-binding
    #:description "a [name acquire release] binding"
    (pattern [name:id acquire:expr release:expr])))

(define reentry-message "cannot re-enter its body after its resources were released")

(define (refuse-reentry who exn)
  (raise (exn (if who
                  (format "~a: ~a" who reentry-message)
                  reentry-message)
              (current-continuation-marks)
              'logic)))

;; The acquired value arrives already evaluated, outside the extent, so control
;; that jumps back into the body (a generator resume) cannot acquire again. The
;; release runs on every exit, claimed first and with breaks disabled, so a break
;; can neither skip it nor run it twice; a thread killed inside the extent never
;; runs it, so the resource's finalizer stays the backstop.
(define (call-with-release acquired release proc #:who [who #f] #:exn [exn exn:fail:raft])
  (define held acquired)
  (define entered? #f)
  (define breaks? (break-enabled))
  (begin0 (parameterize-break #f
                              (dynamic-wind (lambda ()
                                              (when entered?
                                                (refuse-reentry who exn))
                                              (set! entered? #t))
                                            (lambda () (parameterize-break breaks? (proc acquired)))
                                            (lambda ()
                                              (define claimed held)
                                              (set! held #f)
                                              (when claimed
                                                (release claimed)))))
    (parameterize-break breaks? (void))))

(define-syntax-parser with-release
  [(_ (~alt (~optional (~seq #:who who:expr) #:defaults ([who #'#f]))
            (~optional (~seq #:exn exn:expr) #:defaults ([exn #'exn:fail:raft]))) ...
      ()
      body:expr ...+)
   #'(let ()
       body ...)]
  [(_ (~alt (~optional (~seq #:who who:expr) #:defaults ([who #'#f]))
            (~optional (~seq #:exn exn:expr) #:defaults ([exn #'exn:fail:raft]))) ...
      (b:release-binding more:release-binding ...)
      body:expr ...+)
   #:with options #'(#:who who #:exn exn)
   #'(call-with-release b.acquire
                        b.release
                        (~@ . options)
                        (lambda (b.name)
                          (with-release (~@ . options)
                            (more ...)
                            body ...)))])
