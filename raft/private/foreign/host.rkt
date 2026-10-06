#lang racket/base

(require (only-in ffi/unsafe
                  _double
                  _float
                  _gcpointer
                  _int32
                  _int64
                  ctype-sizeof
                  flvector->cpointer
                  make-ctype
                  malloc
                  memcpy
                  ptr-ref
                  ptr-set!)
         (only-in ffi/vector
                  f32vector->cpointer
                  f32vector-length
                  f64vector->cpointer
                  f64vector-length
                  make-f32vector
                  make-f64vector)
         (only-in racket/flonum flvector-length flvector?))

(provide _host
         dtype-itemsize-matches?
         f32vector->host
         f64vector->host
         host->f32vector
         host->f64vector
         host-bytes
         host-getter
         host-memory
         host-setter)

(struct host-memory (pointer bytes) #:omit-define-syntaxes #:constructor-name pointer->host-memory)

(define (host-memory bytes) ;; noqa
  (pointer->host-memory (malloc (max bytes 1) 'atomic-interior) bytes))

(define (host-bytes host)
  (cond
    [(flvector? host) (* 8 (flvector-length host))]
    [(bytes? host) (bytes-length host)]
    [else (host-memory-bytes host)]))

(define (host->pointer host)
  (cond
    [(flvector? host) (flvector->cpointer host)]
    [(bytes? host) host]
    [else (host-memory-pointer host)]))

(define _host (make-ctype _gcpointer host->pointer #f))

(define element-types (hasheq 'float32 _float 'float64 _double 'int32 _int32 'int64 _int64))

(define (dtype-itemsize-matches? dtype itemsize)
  (= (ctype-sizeof (hash-ref element-types dtype)) itemsize))

(define (host-setter dtype)
  (define type (hash-ref element-types dtype))
  (lambda (host i v) (ptr-set! (host-memory-pointer host) type i v)))

(define (host-getter dtype)
  (define type (hash-ref element-types dtype))
  (lambda (host i) (ptr-ref (host-memory-pointer host) type i)))

(define (copied-into host source bytes)
  (unless (zero? bytes)
    (memcpy (host-memory-pointer host) source bytes))
  host)

(define (f32vector->host xs)
  (define bytes (* 4 (f32vector-length xs)))
  (copied-into (host-memory bytes) (f32vector->cpointer xs) bytes))

(define (f64vector->host xs)
  (define bytes (* 8 (f64vector-length xs)))
  (copied-into (host-memory bytes) (f64vector->cpointer xs) bytes))

(define (host->f32vector n host)
  (define xs (make-f32vector n))
  (unless (zero? n)
    (memcpy (f32vector->cpointer xs) (host-memory-pointer host) (* 4 n)))
  xs)

(define (host->f64vector n host)
  (define xs (make-f64vector n))
  (unless (zero? n)
    (memcpy (f64vector->cpointer xs) (host-memory-pointer host) (* 8 n)))
  xs)
