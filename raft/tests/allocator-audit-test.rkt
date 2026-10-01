#lang racket/base

(require (only-in racket/list append-map filter-map splitf-at)
         (only-in racket/match == match match-lambda)
         (only-in rackunit check-equal? check-true test-case)
         (only-in "private/bindings.rkt"
                  binding-name
                  binding-options
                  binding-signature
                  bindings-in
                  foreign-bindings
                  foreign-modules))

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
    [(list (or '_ptr '_list '_vector) (or 'o 'io) type _ ...) type]
    [(list '_box type) type]
    [_ #f]))

(define (wrap-of b)
  (match (memq '#:wrap (binding-options b))
    [(list* _ wrap _) wrap]
    [_ #f]))

(define (returned-violations b parts)
  (define-values (arguments after) (splitf-at parts (lambda (p) (not (eq? p '->)))))
  (define types
    (match after
      [(list* '-> result _) (cons (strip-name result) (filter-map output-type arguments))]))
  (define wrap (wrap-of b))
  (append
   (if (memq '_pointer types)
       (list (format "~a returns a bare _pointer" (binding-name b)))
       '())
   (for/list ([type (in-list types)]
              #:when (hash-has-key? handle-allocators type)
              #:unless (eq? wrap (hash-ref handle-allocators type)))
     (format "~a returns ~a without #:wrap ~a"
             (binding-name b) type (hash-ref handle-allocators type)))))

(define (violations b)
  (match (binding-signature b)
    [(list* '_fun parts) (returned-violations b parts)]
    [_ (list (format "~a: the signature is not a literal _fun" (binding-name b)))]))

(define (violations-of form)
  (append-map violations (bindings-in form)))

(define (collect pattern datum)
  (match datum
    [(? pattern) (list datum)]
    [(? list?) (append-map (lambda (d) (collect pattern d)) datum)]
    [_ '()]))

(define (operands-of head)
  (for/list ([form (in-list (collect (match-lambda [(list (== head) _) #t] [_ #f])
                                     (foreign-modules)))])
    (match form [(list _ operand) operand])))

(define (releases? b)
  (match (wrap-of b)
    [(list (or 'releaser 'deallocator) _ ...) #t]
    [_ #f]))

(test-case "every handle-returning binding registers its release"
  (define bindings (foreign-bindings))
  (check-true (> (length bindings) 10) "the census found the bindings")
  (check-equal? (append-map violations bindings) '()))

(test-case "every allocator's release is wrapped as a deallocator"
  (define by-name
    (for/hasheq ([b (in-list (foreign-bindings))])
      (values (binding-name b) b)))
  (define releases (operands-of 'allocator))
  (check-equal? (sort releases symbol<?) '(rr-buffer-free rr-resources-free))
  (for ([name (in-list releases)])
    (check-true (releases? (hash-ref by-name name)) (format "~a" name))))

(test-case "every handle type has an allocator in the audit"
  (define types (operands-of 'define-cpointer-type))
  (check-true (pair? types))
  (for ([type (in-list types)])
    (check-true (hash-has-key? handle-allocators type) (format "~a" type))
    (define nullable (string->symbol (format "~a/null" type)))
    (check-true (hash-has-key? handle-allocators nullable) (format "~a" nullable))))

(test-case "the audit rejects what it is meant to"
  (check-equal? (violations-of '(define-raft f (_fun -> _pointer)))
                '("f returns a bare _pointer"))
  (check-equal? (violations-of '(define-raft g (_fun (out : (_ptr o _pointer)) -> _int)))
                '("g returns a bare _pointer"))
  (check-equal? (violations-of '(define-raft h (_fun _size -> _rr-buffer/null)))
                '("h returns _rr-buffer/null without #:wrap buffer-allocator"))
  (check-equal? (violations-of '(define-raft i (_fun (out : (_ptr io _rr-buffer/null)) -> _int)))
                '("i returns _rr-buffer/null without #:wrap buffer-allocator"))
  (check-equal? (violations-of '(define-raft j (_fun (_box _rr-resources/null) -> _int)))
                '("j returns _rr-resources/null without #:wrap resources-allocator"))
  (check-equal? (violations-of '(define-raft k
                                  (_fun (out : (_ptr o _rr-resources/null))
                                        -> (status : _int)
                                        -> (and (zero? status) out))
                                  #:wrap buffer-allocator))
                '("k returns _rr-resources/null without #:wrap resources-allocator"))
  (check-equal? (violations-of '(define-raft m some-ctype))
                '("m: the signature is not a literal _fun"))
  (check-equal? (violations-of '(define-raft ok
                                  (_fun (out : (_ptr o _rr-buffer/null))
                                        -> (status : _int)
                                        -> (and (zero? status) out))
                                  #:wrap buffer-allocator))
                '()))
