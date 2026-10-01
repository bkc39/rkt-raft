#lang racket/base

(require (only-in ffi/unsafe
                  _enum
                  _fun
                  _int
                  _int32
                  _ptr
                  _uint64
                  _void
                  cpointer-has-tag?
                  set-cpointer-tag!)
         (only-in ffi/unsafe/alloc allocator deallocator)
         (only-in "library.rkt" _rr-buffer _rr-resources define-raft))

(provide buffer-allocator
         buffer-drop-count
         released?
         release-failure-count
         resources-allocator
         resources-drop-count
         rr-buffer-free
         rr-memory-resource-kind
         rr-resources-free)

;; A released handle is retagged: releasing it again does nothing, and any
;; other use fails its type's tag check before reaching freed memory. A handle
;; of the wrong type fails that check here too, before the finalizer is dropped.
(define (released? handle)
  (cpointer-has-tag? handle 'rr-released))

(define (release-once release-native)
  ((deallocator)
   (lambda (handle)
     (unless (released? handle)
       (release-native handle)
       (set-cpointer-tag! handle 'rr-released)))))

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

(define-raft rr-memory-resource-kind
  (_fun _int32 (out : (_ptr o (_enum '(cuda cuda-async other) _int32 #:unknown (lambda (_) 'other))))
        -> (status : _int)
        -> (and (zero? status) out)))

(define resources-allocator (allocator rr-resources-free))
(define buffer-allocator (allocator rr-buffer-free))
