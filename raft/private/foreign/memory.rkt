#lang racket/base

(require (only-in ffi/unsafe _fun _uint64 _void cpointer-has-tag? set-cpointer-tag!)
         (only-in ffi/unsafe/alloc allocator deallocator)
         (only-in "library.rkt" _rr-buffer _rr-resources define-raft released-tag))

(provide buffer-allocator
         buffer-drop-count
         released?
         release-failure-count
         resources-allocator
         resources-drop-count
         rr-buffer-free
         rr-resources-free)

;; A released handle is retagged: releasing it again does nothing, and any
;; other use raises exn:fail:raft before reaching freed memory. A handle of the
;; wrong type fails its type's tag check here, before the finalizer is dropped.
(define (released? handle)
  (cpointer-has-tag? handle released-tag))

(define (release-once release-native)
  ((deallocator)
   (lambda (handle)
     (unless (released? handle)
       (release-native handle)
       (set-cpointer-tag! handle released-tag)))))

(define-raft rr-resources-free
  (_fun _rr-resources -> _void)
  #:wrap release-once)

(define-raft rr-buffer-free
  (_fun _rr-buffer -> _void)
  #:wrap release-once)

(define-raft resources-drop-count
  (_fun -> _uint64)
  #:c-id rr_resources_drop_count)

(define-raft buffer-drop-count
  (_fun -> _uint64)
  #:c-id rr_buffer_drop_count)

(define-raft release-failure-count
  (_fun -> _uint64)
  #:c-id rr_release_failure_count)

(define resources-allocator (allocator rr-resources-free))
(define buffer-allocator (allocator rr-buffer-free))
