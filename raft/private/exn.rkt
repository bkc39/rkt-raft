#lang racket/base

(require (only-in racket/list dropf-right)
         (only-in racket/match match)
         (only-in racket/string non-empty-string?)
         (only-in "log.rkt" log-raft-debug))

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

(define (raise-message make who kind message)
  (raise (make (format "~a: ~a" who message) (current-continuation-marks) (kind->symbol kind))))

(define (trim-right line)
  (list->string (dropf-right (string->list line) char-whitespace?)))

(define (first-line who text)
  (match (filter non-empty-string? (map trim-right (regexp-split #rx"\r\n|[\r\n]" text)))
    ['() ""]
    [(cons line more)
     (unless (null? more)
       (log-raft-debug "~a: ~a" who text))
     line]))

(define (raise-native make who kind text)
  (raise-message make who kind (first-line who text)))

(define (raise-raft who kind form . args)
  (raise-message exn:fail:raft who kind (apply format form args)))
