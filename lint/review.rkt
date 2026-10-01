#lang racket/base

(require (only-in racket/set seteq set-member?)
         (only-in review/ext pop-scope push-scope recur track-binding)
         ;; whole-module: its syntax classes come with it
         syntax/parse/pre)

(provide review-syntax
         should-review?)

(define scoped-test-forms (seteq 'test-gpu 'test-twin 'test-without-gpu))

(define (named? head name)
  (eq? (syntax-e head) name))

(define (should-review? stx)
  (syntax-parse stx
    [(head:id (_:id . _) _ ...)
     #:when (named? #'head 'define-syntax-parse-rule)
     #t]
    [(head:id _ _ _ ...)
     #:when (named? #'head 'test-unless-skipped)
     #t]
    [(head:id _ _ ...)
     #:when (set-member? scoped-test-forms (syntax-e #'head))
     #t]
    [_ #f]))

(define (review-scoped-body leading body)
  (for-each recur leading)
  (push-scope)
  (for-each recur body)
  (pop-scope))

(define (review-syntax stx)
  (syntax-parse stx
    [(head:id (name:id . _) _ ...)
     #:when (named? #'head 'define-syntax-parse-rule)
     (track-binding #'name)]
    [(head:id reason name body ...)
     #:when (named? #'head 'test-unless-skipped)
     (review-scoped-body (list #'reason #'name) (syntax->list #'(body ...)))]
    [(_ name body ...) (review-scoped-body (list #'name) (syntax->list #'(body ...)))]))
