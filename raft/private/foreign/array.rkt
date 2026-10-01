#lang racket/base

(require (only-in ffi/unsafe _fun _int _ptr _size)
         (only-in ffi/vector _f64vector f64vector-length)
         (only-in "library.rkt" _rr-buffer _rr-buffer/null _rr-resources define-raft)
         (only-in "memory.rkt" buffer-allocator))

(provide rr-buffer-alloc
         rr-copy-d2h
         rr-copy-h2d)

(define-raft rr-buffer-alloc
  (_fun _rr-resources _size (out : (_ptr o _rr-buffer/null))
        -> (status : _int)
        -> (and (zero? status) out))
  #:wrap buffer-allocator)

;; The byte count comes from the host vector, so a copy cannot run past it; the
;; shim checks the device side. These calls stay non-blocking: the vector lives
;; in the GC heap, and a blocking call would let the collector move it.
(define-raft rr-copy-h2d
  (_fun _rr-buffer (host : _f64vector) (_size = (* 8 (f64vector-length host)))
        -> (status : _int)
        -> (zero? status)))

(define-raft rr-copy-d2h
  (_fun (host : _f64vector) _rr-buffer (_size = (* 8 (f64vector-length host)))
        -> (status : _int)
        -> (zero? status)))
