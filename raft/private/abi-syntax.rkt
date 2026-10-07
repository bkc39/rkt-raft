#lang racket/base

(require (for-template racket/base
                       (only-in racket/match prop:match-expander))
         (only-in racket/string string-join)
         (only-in racket/struct-info extract-struct-info prop:struct-field-info prop:struct-info)
         ;; whole-module: its syntax classes need bindings only-in strips
         syntax/parse/pre)

(provide keyword-struct-binding)

(define (expected-keywords fields)
  (string-join (for/list ([field (in-list fields)])
                 (format "~a" (car field)))
               " "
               #:before-first "expected one of "))

(define-syntax-class (field-keyword fields)
  #:description "a field keyword"
  #:attributes (accessor)
  (pattern kw:keyword
    #:fail-unless (assq (syntax-e #'kw) fields) (expected-keywords fields)
    #:with accessor (cdr (assq (syntax-e #'kw) fields))))

(struct keyword-struct-binding (query predicate fields struct-name)
  #:property prop:match-expander
  (lambda (self stx)
    (define fields (keyword-struct-binding-fields self))
    (syntax-parse stx
      [(_ (~seq (~var field (field-keyword fields)) pattern:expr) ...)
       #:with predicate (keyword-struct-binding-predicate self)
       #'(? predicate (app field.accessor pattern) ...)]))
  #:property prop:procedure
  (lambda (self stx)
    (syntax-parse stx
      [(_ argument:expr ...)
       #:with query (keyword-struct-binding-query self)
       #'(query argument ...)]
      [_:id (keyword-struct-binding-query self)]))
  #:property prop:struct-info
  (lambda (self) (extract-struct-info (syntax-local-value (keyword-struct-binding-struct-name self))))
  #:property prop:struct-field-info
  (lambda (self)
    (reverse (for/list ([field (in-list (keyword-struct-binding-fields self))])
               (string->symbol (keyword->string (car field)))))))
