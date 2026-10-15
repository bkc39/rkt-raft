#lang racket/base

(provide raise-native
         raise-raft
         (struct-out exn:fail:raft))

(struct exn:fail:raft exn:fail (kind))

(define error-kinds #(generic out-of-memory cuda logic))

(define (kind->symbol kind)
  (cond
    [(symbol? kind) kind]
    [(and (exact-nonnegative-integer? kind) (< kind (vector-length error-kinds)))
     (vector-ref error-kinds kind)]
    [else 'generic]))

(define (raise-native make who kind message)
  (raise (make (format "~a: ~a" who message) (current-continuation-marks) (kind->symbol kind))))

(define (raise-raft who kind form . args)
  (raise-native exn:fail:raft who kind (apply format form args)))
