#lang racket/base

(require (only-in ffi/unsafe _fun _uint64 _void)
         (only-in ffi/unsafe/alloc allocator deallocator)
         (only-in "library.rkt" _rr-buffer _rr-resources define-raft))

(provide buffer-allocator
         buffer-drop-count
         resources-allocator
         resources-drop-count
         rr-buffer-free
         rr-resources-free)

(define-raft rr-resources-free
  (_fun _rr-resources -> _void)
  #:wrap (deallocator))

(define-raft rr-buffer-free
  (_fun _rr-buffer -> _void)
  #:wrap (deallocator))

(define-raft rr-resources-drop-count
  (_fun -> _uint64))

(define-raft rr-buffer-drop-count
  (_fun -> _uint64))

(define resources-allocator (allocator rr-resources-free))
(define buffer-allocator (allocator rr-buffer-free))

(define (resources-drop-count)
  (rr-resources-drop-count))

(define (buffer-drop-count)
  (rr-buffer-drop-count))
