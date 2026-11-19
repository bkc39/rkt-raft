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
    (pattern [name:id acquire:expr release:expr]))

  (define-splicing-syntax-class
   release-options
   #:description "the #:who and #:exn options"
   (pattern (~seq
             (~alt (~optional (~seq #:who who:expr) #:name "the #:who option" #:defaults ([who #'#f]))
                   (~optional (~seq #:exn exn:expr)
                              #:name "the #:exn option"
                              #:defaults ([exn #'exn:fail:raft]))) ...))))

(define reentry-message "cannot re-enter its body after its resources were released")

(define (refuse-reentry who exn)
  (raise (exn (if who
                  (format "~a: ~a" who reentry-message)
                  reentry-message)
              (current-continuation-marks)
              'logic)))

;; The acquired value arrives already evaluated, outside the extent, so control
;; that jumps back into the body (a generator resume) cannot acquire again. The
;; release runs on every exit; a thread killed inside the extent never runs it,
;; so the resource's finalizer stays the backstop.
(define (call-with-release acquired release proc #:who [who #f] #:exn [exn exn:fail:raft])
  (define held acquired)
  (define entered? #f)
  (dynamic-wind (lambda ()
                  (when entered?
                    (refuse-reentry who exn))
                  (set! entered? #t))
                (lambda () (proc acquired))
                (lambda ()
                  (define claimed held)
                  (set! held #f)
                  (when claimed
                    (release claimed)))))

(define-syntax-parser with-release
  [(_ o:release-options () body:expr ...+)
   #'(let ()
       body ...)]
  [(_ o:release-options (b:release-binding more:release-binding ...) body:expr ...+)
   #'(call-with-release b.acquire
                        b.release
                        #:who o.who
                        #:exn o.exn
                        (lambda (b.name)
                          (with-release #:who o.who #:exn
                            o.exn
                            (more ...)
                            body ...)))])
