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
                  ptr-ref
                  ptr-set!)
         (only-in racket/flonum flvector-length flvector?))

(provide _host
         dtype-itemsize-matches?
         host-bytes
         host-getter
         host-memory
         host-setter)

(struct host-memory (pointer bytes) #:omit-define-syntaxes #:constructor-name pointer->host-memory)

(define (host-memory bytes) ;; noqa
  (pointer->host-memory (malloc (max bytes 1) 'atomic-interior) bytes))

(define (host-bytes host)
  (if (flvector? host)
      (* 8 (flvector-length host))
      (host-memory-bytes host)))

(define (host->pointer host)
  (if (flvector? host)
      (flvector->cpointer host)
      (host-memory-pointer host)))

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
