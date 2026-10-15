#lang racket/base

(provide collect-until
         drain-finalizers!)

(define (collect-until done?)
  (for/or ([_ (in-range 50)])
    (collect-garbage 'major)
    (sync (system-idle-evt))
    (done?)))

(define (drain-finalizers!)
  (for ([_ (in-range 3)])
    (collect-garbage 'major)
    (sync (system-idle-evt))))
