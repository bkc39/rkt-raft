#lang racket/base

(require (only-in racket/match match-define)
         (only-in "foreign/internal.rkt" rr-dtype-table rr-op-table))

(provide code->dtype
         dtype->code
         dtype-itemsize
         dtypes
         op-table)

(struct dtype-entry (name code itemsize))

(define entries
  (for/list ([row (in-list (rr-dtype-table))])
    (match-define (list name code itemsize) row)
    (dtype-entry name code itemsize)))

(define dtypes (map dtype-entry-name entries))

(define by-name
  (for/hasheq ([entry (in-list entries)])
    (values (dtype-entry-name entry) entry)))

(define by-code
  (for/hasheqv ([entry (in-list entries)])
    (values (dtype-entry-code entry) entry)))

(define (code->dtype code)
  (dtype-entry-name (hash-ref by-code code)))

(define (dtype->code dtype)
  (dtype-entry-code (hash-ref by-name dtype)))

(define (dtype-itemsize dtype)
  (dtype-entry-itemsize (hash-ref by-name dtype)))

(define layout-bits (hasheq 'row-major 1 'col-major 2))

(define (members mask bit names)
  (for/list ([name (in-list names)]
             #:unless (zero? (bitwise-and mask (bit name))))
    name))

(define (dtype-bit name)
  (arithmetic-shift 1 (dtype->code name)))

(define (layout-bit name)
  (hash-ref layout-bits name))

(define op-table
  (for/hasheq ([row (in-list (rr-op-table))])
    (match-define (list module name dtype-mask layout-mask) row)
    (values name
            (hasheq 'module module
                    'dtypes (members dtype-mask dtype-bit dtypes)
                    'layouts (members layout-mask layout-bit '(row-major col-major))))))
