#lang racket/base

(require (only-in racket/list append-map)
         (only-in racket/match match)
         (only-in racket/path path-has-extension?)
         (only-in racket/string string-replace)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path)

(provide binding-forms
         binding-c-id
         binding-name
         binding-options
         binding-signature
         foreign-dir)

(define-runtime-path foreign-dir "../../private/foreign")

(define (define-raft-forms v)
  (match v
    [(list* 'define-raft (? symbol?) _ _) (list v)]
    [(? list?) (append-map define-raft-forms v)]
    [_ '()]))

(define (read-module path)
  (parameterize ([read-accept-reader #t]
                 [read-accept-lang #t])
    (call-with-input-file path read)))

(define (binding-forms [dir foreign-dir])
  (define files
    (sort (for/list ([f (in-directory dir)]
                     #:when (path-has-extension? f #".rkt"))
            f)
          path<?))
  (append-map (lambda (f) (define-raft-forms (read-module f))) files))

(define (binding-name form)
  (cadr form))

(define (binding-signature form)
  (caddr form))

(define (binding-options form)
  (cdddr form))

(define (binding-c-id form)
  (match (memq '#:c-id (binding-options form))
    [(list* _ id _) (symbol->string id)]
    [_ (string-replace (symbol->string (binding-name form)) "-" "_")]))
