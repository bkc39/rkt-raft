#lang racket/base

(require (only-in racket/list append-map)
         (only-in racket/set seteq set-member?)
         (only-in review/ext pop-scope push-scope recur track-binding)
         ;; whole-module: its syntax classes come with it
         syntax/parse/pre)

(provide review-syntax
         should-review?)

(define scoped-test-forms
  (seteq 'test-canary
         'test-gpu
         'test-host-probe
         'test-pools
         'test-probe
         'test-twin
         'test-without-gpu))

(define (named? head name)
  (eq? (syntax-e head) name))

(define (should-review? stx)
  (syntax-parse stx
    [(head:id (_ . _))
     #:when (named? #'head 'quote)
     #t]
    [(head:id _)
     #:when (named? #'head 'quasiquote)
     #t]
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

(define (unquote? head)
  (memq (syntax-e head) '(unquote unquote-splicing)))

(define (unquoted stx depth)
  (syntax-parse stx
    [(head:id e)
     #:when (and (unquote? #'head) (= depth 1))
     (list #'e)]
    [(head:id e)
     #:when (unquote? #'head)
     (unquoted #'e (sub1 depth))]
    [(head:id e)
     #:when (named? #'head 'quasiquote)
     (unquoted #'e (add1 depth))]
    [(a . d) (append (unquoted #'a depth) (unquoted #'d depth))]
    [#(e ...) (append-map (lambda (e) (unquoted e depth)) (syntax->list #'(e ...)))]
    [_ '()]))

(define (review-scoped-body leading body)
  (for-each recur leading)
  (push-scope)
  (for-each recur body)
  (pop-scope))

(define (review-syntax stx)
  (syntax-parse stx
    [(head:id (_ . _))
     #:when (named? #'head 'quote)
     (void)]
    [(head:id datum)
     #:when (named? #'head 'quasiquote)
     (for-each recur (unquoted #'datum 1))]
    [(head:id (name:id . _) _ ...)
     #:when (named? #'head 'define-syntax-parse-rule)
     (track-binding #'name)]
    [(head:id reason name body ...)
     #:when (named? #'head 'test-unless-skipped)
     (review-scoped-body (list #'reason #'name) (syntax->list #'(body ...)))]
    [(_ name body ...) (review-scoped-body (list #'name) (syntax->list #'(body ...)))]))
