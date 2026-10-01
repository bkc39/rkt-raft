#lang racket/base

(require (only-in ffi/unsafe _fun _uint64 _void cpointer-has-tag? set-cpointer-tag!)
         (only-in ffi/unsafe/alloc allocator deallocator)
         (only-in "library.rkt"
                  _rr-buffer
                  _rr-resources
                  define-raft
                  rr-buffer-tag
                  rr-resources-tag))

(provide buffer-allocator
         buffer-drop-count
         release-failure-count
         resources-allocator
         resources-drop-count
         rr-buffer-free
         rr-resources-free)

;; A released handle is retagged: a second release does nothing, and any other
;; use fails the type's tag check in Racket before it reaches freed memory.
(define ((releaser tag) release-native)
  ((deallocator)
   (lambda (handle)
     (when (cpointer-has-tag? handle tag)
       (release-native handle)
       (set-cpointer-tag! handle 'rr-released)))))

(define-raft rr-resources-free
  (_fun _rr-resources -> _void)
  #:wrap (releaser rr-resources-tag))

(define-raft rr-buffer-free
  (_fun _rr-buffer -> _void)
  #:wrap (releaser rr-buffer-tag))

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
