#lang racket/base

(require (only-in racket/list append-map)
         (only-in racket/match match)
         (only-in racket/path path-has-extension?)
         (only-in racket/string string-replace)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path)

(provide (struct-out binding)
         bindings-in
         foreign-bindings
         foreign-dir
         foreign-modules)

(struct binding (name signature options c-id))

(define-runtime-path foreign-dir "../../private/foreign")

(define (read-module path)
  (parameterize ([read-accept-reader #t]
                 [read-accept-lang #t])
    (call-with-input-file path read)))

(define (c-id name options)
  (match (memq '#:c-id options)
    [(list* _ id _) (symbol->string id)]
    [_ (string-replace (symbol->string name) "-" "_")]))

(define (bindings-in datum)
  (match datum
    [(list* 'define-raft (? symbol? name) signature options)
     (list (binding name signature options (c-id name options)))]
    [(? list?) (append-map bindings-in datum)]
    [_ '()]))

(define (foreign-modules [dir foreign-dir])
  (define files
    (for/list ([f (in-directory dir)]
               #:when (path-has-extension? f #".rkt"))
      f))
  (map read-module (sort files path<?)))

(define (foreign-bindings [dir foreign-dir])
  (append-map bindings-in (foreign-modules dir)))
