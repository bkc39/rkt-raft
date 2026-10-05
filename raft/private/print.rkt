#lang racket/base

(require (only-in racket/flonum flsingle)
         (only-in racket/format ~a ~r)
         (only-in racket/list range)
         (only-in racket/match match)
         (only-in racket/math infinite? nan?)
         (only-in racket/string string-join))

(provide array-text
         float32->string
         summarised?)

(define threshold 1000)
(define edge-items 3)

(define (summarised? shape)
  (> (apply * shape) threshold))

(define (float32->string x)
  (if (or (zero? x) (nan? x) (infinite? x))
      (number->string x)
      (for/or ([digits (in-range 1 10)])
        (define decimal (string->number (~r x #:notation 'exponential #:precision (list '= digits))))
        (and (= (flsingle decimal) x) (number->string decimal)))))

(define (element->string dtype x)
  (if (eq? dtype 'float32)
      (float32->string x)
      (number->string x)))

(define (axis-indices n summarise?)
  (if (and summarise? (> n (* 2 edge-items)))
      (append (range edge-items) '(...) (range (- n edge-items) n))
      (range n)))

(define (cells-text cells width)
  (string-join (for/list ([cell (in-list cells)])
                 (if (eq? cell '...)
                     "..."
                     (~a cell #:min-width width #:align 'right)))
               " "))

(define (widest rows)
  (for*/fold ([width 0])
             ([row (in-list rows)]
              [cell (in-list row)]
              #:unless (eq? cell '...))
    (max width (string-length cell))))

(define (array-text dtype shape ref)
  (define summarise? (summarised? shape))
  (define (cell . indices)
    (if (memq '... indices)
        '...
        (element->string dtype (apply ref indices))))
  (match shape
    [(list n)
     (define cells
       (for/list ([i (in-list (axis-indices n summarise?))])
         (cell i)))
     (string-append "[" (cells-text cells (widest (list cells))) "]")]
    [(list rows cols)
     (define row-indices (axis-indices rows summarise?))
     (define col-indices (axis-indices cols summarise?))
     (define grid
       (for/list ([i (in-list row-indices)])
         (if (eq? i '...)
             '...
             (for/list ([j (in-list col-indices)])
               (cell i j)))))
     (define width (widest (filter list? grid)))
     (define lines
       (for/list ([row (in-list grid)])
         (if (eq? row '...)
             "..."
             (string-append "[" (cells-text row width) "]"))))
     (string-join lines "\n " #:before-first "[" #:after-last "]")]))
