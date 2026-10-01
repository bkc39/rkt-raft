#lang racket/base

(provide raise-raft
         (struct-out exn:fail:raft))

(struct exn:fail:raft exn:fail (kind))

(define (raise-raft who kind form . args)
  (raise (exn:fail:raft (format "~a: ~a" who (apply format form args))
                        (current-continuation-marks)
                        kind)))
