#lang racket/base

(require (only-in racket/list append-map filter-map remove-duplicates splitf-at)
         (only-in racket/match match match-lambda)
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

(define (split-signature b)
  (match (binding-signature b)
    [(list* '_fun parts)
     (define-values (arguments after) (splitf-at parts (lambda (p) (not (eq? p '->)))))
     (match after
       [(list* '-> result _) (values (map strip-name arguments) (strip-name result) arguments)])]
    [_ (values #f #f #f)]))

(define (binding-violations b)
  (define-values (argument-types result parts) (split-signature b))
  (cond
    [(not argument-types)
     (list (format "~a: the signature is not a literal _fun" (binding-name b)))]
    [else
     (define returned (cons result (filter-map output-type parts)))
     (define wrap (wrap-of b))
     (append
      (if (memq '_pointer returned)
          (list (format "~a returns a bare _pointer" (binding-name b)))
          '())
      (if (memq '_pointer argument-types)
          (list (format "~a takes a bare _pointer" (binding-name b)))
          '())
      (for/list ([type (in-list returned)]
                 #:when (hash-has-key? handle-allocators type)
                 #:unless (eq? wrap (hash-ref handle-allocators type)))
        (format "~a returns ~a without #:wrap ~a"
                (binding-name b) type (hash-ref handle-allocators type))))]))

(define (release-problem by-name allocator release)
  (define b (hash-ref by-name release #f))
  (define-values (argument-types _result _parts)
    (if b (split-signature b) (values #f #f #f)))
  (cond
    [(not b) (format "~a releases through ~a, which is not a binding" allocator release)]
    [(not (eq? (wrap-of b) 'release-once))
     (format "~a is not wrapped by release-once" release)]
    [(not (match argument-types
            [(list type) (eq? (hash-ref handle-allocators type #f) allocator)]
            [_ #f]))
     (format "~a releases through ~a, which takes ~a" allocator release argument-types)]
    [else #f]))

(define (release-violations bindings pairs)
  (define by-name
    (for/hasheq ([b (in-list bindings)])
      (values (binding-name b) b)))
  (filter-map (match-lambda [(cons allocator release) (release-problem by-name allocator release)])
              pairs))

(define (collect wanted? datum)
  (match datum
    [(? wanted?) (list datum)]
    [(? list?) (append-map (lambda (d) (collect wanted? d)) datum)]
    [_ '()]))

(define (allocator-pairs modules)
  (map (match-lambda [(list _ name (list _ release)) (cons name release)])
       (collect (match-lambda
                  [(list 'define (? symbol?) (list 'allocator (? symbol?))) #t]
                  [_ #f])
                modules)))

(define (cpointer-types modules)
  (map (match-lambda [(list _ type) type])
       (collect (match-lambda
                  [(list 'define-cpointer-type _) #t]
                  [_ #f])
                modules)))

(test-case "every handle-returning binding registers its release"
  (define bindings (foreign-bindings))
  (check-true (> (length bindings) 10) "the census found the bindings")
  (check-equal? (append-map binding-violations bindings) '()))

(test-case "every allocator releases its own type through release-once"
  (define pairs (allocator-pairs (foreign-modules)))
  (check-equal? (sort (map car pairs) symbol<?)
                (sort (remove-duplicates (hash-values handle-allocators)) symbol<?))
  (check-equal? (release-violations (foreign-bindings) pairs) '()))

(test-case "every handle type has an allocator in the audit"
  (define types (cpointer-types (foreign-modules)))
  (check-true (pair? types))
  (for ([type (in-list types)])
    (check-true (hash-has-key? handle-allocators type) (format "~a" type))
    (define nullable (string->symbol (format "~a/null" type)))
    (check-true (hash-has-key? handle-allocators nullable) (format "~a" nullable))))

(define (violations-of form)
  (append-map binding-violations (bindings-in form)))

(test-case "the binding audit rejects what it is meant to"
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
  (check-equal? (violations-of '(define-raft n (_fun _rr-buffer _pointer _size -> _int)))
                '("n takes a bare _pointer"))
  (check-equal? (violations-of '(define-raft ok
                                  (_fun (out : (_ptr o _rr-buffer/null))
                                        -> (status : _int)
                                        -> (and (zero? status) out))
                                  #:wrap buffer-allocator))
                '()))

(test-case "the release audit rejects what it is meant to"
  (define releases
    (bindings-in '((define-raft free-r (_fun _rr-resources -> _void) #:wrap release-once)
                   (define-raft free-b (_fun _rr-buffer -> _void) #:wrap (deallocator)))))
  (check-equal? (release-violations releases '((resources-allocator . free-r))) '())
  (check-equal? (release-violations releases '((buffer-allocator . free-r)))
                '("buffer-allocator releases through free-r, which takes (_rr-resources)"))
  (check-equal? (release-violations releases '((buffer-allocator . free-b)))
                '("free-b is not wrapped by release-once"))
  (check-equal? (release-violations releases '((buffer-allocator . gone)))
                '("buffer-allocator releases through gone, which is not a binding")))
