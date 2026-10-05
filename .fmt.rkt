#lang racket/base

;; format-fun and format-hash-pairs use fmt's internal document model
;; (fmt/common, fmt/core), which fmt documents as unstable: re-check them when
;; nix/racket-tools.nix moves to a new fmt.
(require (only-in fmt/common atom atom? commentable-inline-comment newl? node-content node? visible?)
         (only-in fmt/conventions
                  format-#%app
                  format-binding-pairs/indirect
                  format-define-like
                  format-uniform-body/helper)
         (only-in fmt/core define-pretty doc pretty pretty-node)
         (only-in pretty-expressive <+s> alt as-concat flatten v-concat)
         (only-in racket/list filter-not)
         (only-in racket/match match))

(provide the-formatter-map)

(define (plain? x)
  (and (visible? x) (not (commentable-inline-comment x))))

(define (arrow? x)
  (match x
    [(atom #f "->" 'symbol) #t]
    [_ #f]))

(define (arrow-groups xs)
  (for/fold ([groups (list '())]
             #:result (reverse (map reverse groups)))
            ([x (in-list xs)])
    (if (arrow? x)
        (cons (list x) groups)
        (cons (cons x (car groups)) (cdr groups)))))

(define (one-line docs)
  (flatten (as-concat docs)))

(define-pretty format-fun
  #:type node?
  #:let [xs (filter-not newl? (node-content doc))]
  (match (and (pair? xs) (andmap plain? xs) (arrow-groups (cdr xs)))
    [(list* args segments)
     #:when (and (pair? segments) (andmap (lambda (segment) (pair? (cdr segment))) segments))
     (define head (pretty (car xs)))
     (define arg-docs (map pretty args))
     (define segment-docs
       (for/list ([segment (in-list segments)])
         (define rest-docs (map pretty (cdr segment)))
         (<+s> (pretty (car segment)) (alt (one-line rest-docs) (v-concat rest-docs)))))
     (define (stacked arg-lines)
       (<+s> head (v-concat (append arg-lines segment-docs))))
     (pretty-node (alt (one-line (cons head (append arg-docs segment-docs)))
                       (stacked (if (null? args)
                                    '()
                                    (list (one-line arg-docs))))
                       (stacked arg-docs)))]
    [_ (format-#%app doc)]))

(define (key-value-pairs xs)
  (match xs
    ['() '()]
    [(list* key value more) (cons (list key value) (key-value-pairs more))]))

(define-pretty format-hash-pairs
  #:type node?
  #:let [xs (filter-not newl? (node-content doc))]
  (cond
    [(and (pair? xs) (pair? (cdr xs)) (even? (length (cdr xs))) (andmap plain? xs))
     (define head (pretty (car xs)))
     (define pair-docs
       (for/list ([pair (in-list (key-value-pairs (cdr xs)))])
         (<+s> (pretty (car pair)) (pretty (cadr pair)))))
     (pretty-node (alt (one-line (cons head pair-docs)) (<+s> head (v-concat pair-docs))))]
    [else (format-#%app doc)]))

(define ((format-body-form n) d)
  (define xs (filter-not newl? (node-content d)))
  (if (and (> (length xs) (add1 n)) (andmap atom? (list-tail xs (add1 n))))
      (format-#%app d)
      ((format-uniform-body/helper n) d)))

(define (keyword-atom? x)
  (match x
    [(atom _ _ 'hash-colon-keyword) #t]
    [_ #f]))

(define (format-with-release d)
  (define xs (filter-not newl? (node-content d)))
  ((format-body-form (if (and (pair? (cdr xs)) (keyword-atom? (cadr xs))) 3 1)) d))

(define (the-formatter-map name)
  (case name
    [("_fun") format-fun]
    [("hash" "hasheq" "hasheqv" "hashalw") format-hash-pairs]
    [("define-raft") (format-define-like)]
    [("define-cstruct") (format-uniform-body/helper 1 #:body-formatter format-binding-pairs/indirect)]
    [("define-pretty" "generator") (format-uniform-body/helper 1)]
    [("test-gpu" "test-pools" "test-probe" "test-twin" "test-without-gpu" "with-device-resources")
     (format-body-form 1)]
    [("with-release") format-with-release]
    [("test-unless-skipped") (format-body-form 2)]
    [else #f]))
