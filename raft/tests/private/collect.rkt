#lang racket/base

(require (only-in racket/list make-list)
         (only-in "../../private/foreign/job-api.rkt" rr-releases-pending)
         (only-in "../../private/foreign/memory.rkt" buffer-drop-count))

(provide collect-until
         drain-finalizers!
         drops-after
         releases-settled?
         settled-count)

(define (releases-settled?)
  (for/or ([pause (in-list (cons 0 (make-list 500 0.01)))])
    (sleep pause)
    (zero? (rr-releases-pending))))

(define (settled-count read)
  (releases-settled?)
  (read))

(define (collect-until done?)
  (for/or ([_ (in-range 50)])
    (collect-garbage 'major)
    (sync (system-idle-evt))
    (releases-settled?)
    (done?)))

(define (drain-finalizers!)
  (for ([_ (in-range 3)])
    (collect-garbage 'major)
    (sync (system-idle-evt)))
  (void (releases-settled?)))

(define (drops-after make)
  (drain-finalizers!)
  (define before (settled-count buffer-drop-count))
  (define kept (make))
  (drain-finalizers!)
  (values (- (settled-count buffer-drop-count) before) kept))
