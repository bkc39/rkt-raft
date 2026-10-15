#lang racket/base

(require (only-in racket/list append-map filter-map remove-duplicates splitf-at)
         (only-in racket/match match match-define match-lambda)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path
         (only-in rackunit check-equal? check-true test-case)
         (only-in "private/bindings.rkt"
                  binding-name
                  binding-options
                  binding-signature
                  bindings-in
                  foreign-bindings
                  foreign-modules))

(define-runtime-path case-file "fixtures/audit-cases.rktd")

(define handle-allocators
  (hasheq '_rr-resources 'resources-allocator
          '_rr-resources/null 'resources-allocator
          '_rr-buffer 'buffer-allocator
          '_rr-buffer/null 'buffer-allocator))

(define borrowed-types '(_raft-handle _raft-handle/null))

(define (strip-name part)
  (match part
    [(list _ ': type) type]
    [type type]))

(define (output-type part)
  (match (strip-name part)
    [(list* (or '_ptr '_list '_vector) (or 'o 'io) type _) type]
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
     (match-define (list* '-> result _) after)
     (values (map strip-name arguments) (strip-name result) arguments)]
    [_ (values #f #f #f)]))

(define (binding-violations b)
  (define-values (argument-types result parts) (split-signature b))
  (cond
    [(not argument-types) (list (format "~a: the signature is not a literal _fun" (binding-name b)))]
    [else
     (define returned (cons result (filter-map output-type parts)))
     (define wrap (wrap-of b))
     (append (if (memq '_pointer returned)
                 (list (format "~a returns a bare _pointer" (binding-name b)))
                 '())
             (if (memq '_pointer argument-types)
                 (list (format "~a takes a bare _pointer" (binding-name b)))
                 '())
             (for/list ([type (in-list returned)]
                        #:when (hash-has-key? handle-allocators type)
                        #:unless (eq? wrap (hash-ref handle-allocators type)))
               (format "~a returns ~a without #:wrap ~a"
                       (binding-name b)
                       type
                       (hash-ref handle-allocators type)))
             (for/list ([type (in-list returned)]
                        #:when (and wrap (memq type borrowed-types)))
               (format "~a returns the borrowed ~a with #:wrap ~a" (binding-name b) type wrap)))]))

(define (release-problem by-name allocator release)
  (define b (hash-ref by-name release #f))
  (define-values (argument-types _result _parts)
    (if b
        (split-signature b)
        (values #f #f #f)))
  (cond
    [(not b) (format "~a releases through ~a, which is not a binding" allocator release)]
    [(not (eq? (wrap-of b) 'release-once)) (format "~a is not wrapped by release-once" release)]
    [(not (match argument-types
            [(list type) (eq? (hash-ref handle-allocators type #f) allocator)]
            [_ #f]))
     (format "~a releases through ~a, which takes ~a" allocator release argument-types)]
    [else #f]))

(define (release-violations bindings pairs)
  (define by-name
    (for/hasheq ([b (in-list bindings)])
      (values (binding-name b) b)))
  (filter-map (match-lambda
                [(cons allocator release) (release-problem by-name allocator release)])
              pairs))

(define (collect wanted? datum)
  (match datum
    [(? wanted?) (list datum)]
    [(? list?) (append-map (lambda (d) (collect wanted? d)) datum)]
    [_ '()]))

(define (allocator-pairs modules)
  (map (match-lambda
         [(list _ name (list _ release)) (cons name release)])
       (collect (match-lambda
                  [(list 'define (? symbol?) (list 'allocator (? symbol?))) #t]
                  [_ #f])
                modules)))

(define (cpointer-types modules)
  (map (match-lambda
         [(list* _ type _) type])
       (collect (match-lambda
                  [(list* 'define-cpointer-type _ _) #t]
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

(define (audited? type)
  (or (hash-has-key? handle-allocators type) (and (memq type borrowed-types) #t)))

(test-case "every handle type has an allocator in the audit, or is borrowed"
  (define types (cpointer-types (foreign-modules)))
  (check-true (pair? types))
  (for ([type (in-list types)])
    (check-true (audited? type) (format "~a" type))
    (define nullable (string->symbol (format "~a/null" type)))
    (check-true (audited? nullable) (format "~a" nullable))))

(define cases (call-with-input-file case-file read))

(test-case "the binding audit rejects what it is meant to"
  (for ([example (in-list (hash-ref cases 'bindings))])
    (match-define (list form expected) example)
    (check-equal? (append-map binding-violations (bindings-in form)) expected (format "~s" form))))

(test-case "the release audit rejects what it is meant to"
  (define releases (bindings-in (hash-ref cases 'release-bindings)))
  (for ([example (in-list (hash-ref cases 'releases))])
    (match-define (list pairs expected) example)
    (check-equal? (release-violations releases pairs) expected (format "~s" pairs))))
