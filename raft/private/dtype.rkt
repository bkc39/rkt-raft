#lang racket/base

(require (only-in racket/match match-define)
         (only-in "foreign/internal.rkt" rr-dtype-table rr-op-table))

(provide code->dtype
         dtype->code
         dtype-itemsize
         dtypes
         op-table)

(define dtype-rows (rr-dtype-table))

(define dtypes (map car dtype-rows))

(define names-by-code
  (for/hasheqv ([row (in-list dtype-rows)])
    (match-define (list name code _) row)
    (values code name)))

(define itemsizes
  (for/hasheq ([row (in-list dtype-rows)])
    (match-define (list name _ itemsize) row)
    (values name itemsize)))

(define codes-by-name
  (for/hasheq ([row (in-list dtype-rows)])
    (match-define (list name code _) row)
    (values name code)))

(define (dtype->code dtype)
  (hash-ref codes-by-name dtype))

(define (code->dtype code)
  (hash-ref names-by-code code))

(define (dtype-itemsize dtype)
  (hash-ref itemsizes dtype))

(define dtype-bits
  (for/list ([row (in-list dtype-rows)])
    (match-define (list name code _) row)
    (cons name (arithmetic-shift 1 code))))

(define layout-bits '((row-major . 1) (col-major . 2)))

(define (members mask bits)
  (for/list ([entry (in-list bits)]
             #:unless (zero? (bitwise-and mask (cdr entry))))
    (car entry)))

(define op-table
  (for/hasheq ([row (in-list (rr-op-table))])
    (match-define (list module name dtype-mask layout-mask) row)
    (values name
            (hasheq 'module
                    module
                    'dtypes
                    (members dtype-mask dtype-bits)
                    'layouts
                    (members layout-mask layout-bits)))))
