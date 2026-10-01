#lang racket/base

(require (only-in racket/list append-map filter-map splitf-at)
         (only-in racket/match match)
         (only-in rackunit check-equal? check-true test-case)
         (only-in "private/bindings.rkt"
                  binding-forms
                  binding-name
                  binding-options
                  binding-signature
                  foreign-dir))

(define handle-allocators
  (hasheq '_rr-resources 'resources-allocator
          '_rr-resources/null 'resources-allocator
          '_rr-buffer 'buffer-allocator
          '_rr-buffer/null 'buffer-allocator))

(define (strip-name part)
  (match part
    [(list _ ': type) type]
    [type type]))

(define (output-type part)
  (match (strip-name part)
    [(list '_ptr 'o type) type]
    [_ #f]))

(define (returned-types signature)
  (match signature
    [(list* '_fun parts)
     (define-values (arguments after) (splitf-at parts (lambda (p) (not (eq? p '->)))))
     (cons (strip-name (cadr after)) (filter-map output-type arguments))]
    [_ '()]))

(define (wrap-of form)
  (match (memq '#:wrap (binding-options form))
    [(list* _ wrap _) wrap]
    [_ #f]))

(define (violations form)
  (define types (returned-types (binding-signature form)))
  (define wrap (wrap-of form))
  (append
   (if (memq '_pointer types)
       (list (format "~a returns a bare _pointer" (binding-name form)))
       '())
   (for/list ([type (in-list types)]
              #:when (hash-ref handle-allocators type #f)
              #:unless (eq? wrap (hash-ref handle-allocators type)))
     (format "~a returns ~a without #:wrap ~a"
             (binding-name form) type (hash-ref handle-allocators type)))))

(define (cpointer-types)
  (define library
    (parameterize ([read-accept-reader #t] [read-accept-lang #t])
      (call-with-input-file (build-path foreign-dir "library.rkt") read)))
  (let collect ([v library])
    (match v
      [(list 'define-cpointer-type type) (list type)]
      [(? list?) (append-map collect v)]
      [_ '()])))

(test-case "every handle-returning binding registers its release"
  (define forms (binding-forms))
  (check-true (> (length forms) 10) "the census found the bindings")
  (check-equal? (append-map violations forms) '()))

(test-case "every handle type has an allocator in the audit"
  (for ([type (in-list (cpointer-types))])
    (check-true (and (hash-ref handle-allocators type #f) #t) (format "~a" type))
    (define nullable (string->symbol (format "~a/null" type)))
    (check-true (and (hash-ref handle-allocators nullable #f) #t) (format "~a" nullable))))

(test-case "the audit rejects what it is meant to"
  (check-equal? (violations '(define-raft f (_fun -> _pointer)))
                '("f returns a bare _pointer"))
  (check-equal? (violations '(define-raft g (_fun (out : (_ptr o _pointer)) -> _int)))
                '("g returns a bare _pointer"))
  (check-equal? (violations '(define-raft h (_fun _size -> _rr-buffer/null)))
                '("h returns _rr-buffer/null without #:wrap buffer-allocator"))
  (check-equal? (violations '(define-raft k
                               (_fun (out : (_ptr o _rr-resources/null))
                                     -> (status : _int)
                                     -> (and (zero? status) out))
                               #:wrap buffer-allocator))
                '("k returns _rr-resources/null without #:wrap resources-allocator"))
  (check-equal? (violations '(define-raft ok
                               (_fun (out : (_ptr o _rr-buffer/null))
                                     -> (status : _int)
                                     -> (and (zero? status) out))
                               #:wrap buffer-allocator))
                '()))
