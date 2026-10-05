#lang racket/base

(require (only-in ffi/unsafe _enum _fun _int _int32 _ptr _symbol _uint32 define-cstruct ptr-ref)
         (only-in "library.rkt" _rr-resources define-raft))

(provide rr-dtype-table
         rr-memory-resource-kind
         rr-op-table
         rr-resources-ready)

(define-raft rr-resources-ready
  (_fun _rr-resources (out : (_ptr o _int32))
        -> (status : _int)
        -> (and (zero? status) (if (zero? out) 'pending 'ready))))

(define-raft rr-memory-resource-kind
  (_fun _int32 (out : (_ptr o (_enum '(cuda cuda-async other) _int32 #:unknown (lambda (_) 'other))))
        -> (status : _int)
        -> (and (zero? status) out)))

(define-cstruct _rr-dtype-info
  ([name _symbol]
   [code _int32]
   [itemsize _int32]))

(define-cstruct _rr-op-info
  ([module _symbol]
   [name _symbol]
   [dtypes _uint32]
   [layouts _uint32]))

(define-raft rr-dtype-table
  (_fun (count : (_ptr o _int32))
        -> (table : _rr-dtype-info-pointer)
        -> (for/list ([i (in-range count)])
             (define info (ptr-ref table _rr-dtype-info i))
             (list (rr-dtype-info-name info)
                   (rr-dtype-info-code info)
                   (rr-dtype-info-itemsize info)))))

(define-raft rr-op-table
  (_fun (count : (_ptr o _int32))
        -> (table : _rr-op-info-pointer)
        -> (for/list ([i (in-range count)])
             (define info (ptr-ref table _rr-op-info i))
             (list (rr-op-info-module info)
                   (rr-op-info-name info)
                   (rr-op-info-dtypes info)
                   (rr-op-info-layouts info)))))
