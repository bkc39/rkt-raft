#lang racket/base

(require (only-in ffi/unsafe/atomic call-as-atomic)
         (only-in "exn.rkt" exn:fail:raft exn:fail:raft-kind exn:fail:raft? struct:exn:fail:raft)
         (only-in "foreign/core.rkt" rr-last-error rr-last-error-kind))

(provide call/raft
         (struct-out exn:fail:raft)) ;; noqa

;; One atomic section for the call and the read: the last-error slot belongs
;; to the OS thread, which every Racket thread in the place shares.
(define (call/raft who thunk)
  (define-values (result message kind)
    (call-as-atomic
     (lambda ()
       (define result (thunk))
       (if result
           (values result #f #f)
           (values #f (bytes->string/utf-8 (rr-last-error) #\uFFFD) (rr-last-error-kind))))))
  (or result
      (raise (exn:fail:raft (format "~a: ~a" who message)
                            (current-continuation-marks)
                            kind))))
