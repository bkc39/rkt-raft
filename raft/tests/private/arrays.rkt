#lang racket/base

(require (only-in racket/match match)
         (only-in rackunit check-equal?)
         (only-in "../../array.rkt"
                  contiguous?
                  device-matrix
                  dtype
                  layout
                  list*->device-matrix
                  list->device-vector
                  numel
                  shape
                  strides)
         (only-in "../../private/array.rkt" read-array)
         (only-in "../../private/dtype.rkt" dtype-itemsize)
         (only-in "../../private/foreign/host.rkt" host-memory)
         (only-in "../../private/pack.rkt" unpack-vector))

(provide check-zero-row-uploads
         part
         storage)

(define (part spec)
  (match spec
    [(list 'blank element-type rows cols) (device-matrix rows cols #:dtype element-type)]
    [(list* 'matrix element-type rows) (list*->device-matrix rows #:dtype element-type)]
    [(cons element-type xs) (list->device-vector xs #:dtype element-type)]))

(define (storage a)
  (define n (numel a))
  (unpack-vector (dtype a) n (read-array 'storage a (host-memory (* n (dtype-itemsize (dtype a)))))))

(define (facts m)
  (list (shape m)
        (strides m)
        (dtype m)
        (layout m)
        (contiguous? m)
        (contiguous? m #:layout 'col-major)))

(define (check-zero-row-uploads upload none ->rows)
  (for* ([k (in-list '(0 1 3))]
         [d (in-list '(#f float32 float64 int32 int64))]
         [l (in-list '(row-major col-major))])
    (define label (format "~a ~a ~a" k d l))
    (define m (upload none #:cols k #:dtype d #:layout l))
    (check-equal? (facts m) (facts (device-matrix 0 k #:dtype (or d 'float64) #:layout l)) label)
    (check-equal? (facts m) (list (list 0 k) '(0 0) (or d 'float64) 'row-major #t #t) label)
    (check-equal? (->rows m) '() label)))
