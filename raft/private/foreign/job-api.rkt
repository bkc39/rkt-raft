#lang racket/base

(require (only-in ffi/unsafe
                  _bytes
                  _bytes/nul-terminated
                  _double*
                  _fpointer
                  _fun
                  _int
                  _int32
                  _int64
                  _list
                  _ptr
                  _size
                  _uint64
                  _void)
         (only-in ffi/unsafe/alloc allocator)
         (only-in "library.rkt"
                  _rr-buffer
                  _rr-holder
                  _rr-job
                  _rr-job/null
                  _rr-resources
                  _rr-resources/null
                  define-raft)
         (only-in "memory.rkt" release-once resources-allocator))

(provide rr-executor-threads
         rr-exit-drain
         rr-job-fd
         rr-job-message
         rr-job-read
         rr-job-release
         rr-job-state
         rr-job-status
         rr-job-submit
         rr-jobs-in-flight
         rr-jobs-live
         rr-os-thread-id
         rr-os-thread-id/original
         rr-resources-create-host)

(define-raft rr-job-release
  (_fun _rr-job -> _void)
  #:wrap release-once)

(define job-allocator (allocator rr-job-release))

(define-raft rr-resources-create-host
  (_fun (out : (_ptr o _rr-resources/null)) -> (status : _int) -> (and (zero? status) out))
  #:wrap resources-allocator)

(define-raft rr-job-submit
  (_fun _rr-resources
        _fpointer
        (args : _bytes)
        (_size = (bytes-length args))
        (buffers : (_list i _rr-buffer))
        (_size = (length buffers))
        (holders : (_list i _rr-holder))
        (_size = (length holders))
        _double*
        (out : (_ptr o _rr-job/null))
        -> (status : _int)
        -> (and (zero? status) out))
  #:wrap job-allocator)

(define-raft rr-job-state (_fun _rr-job -> _int32))
(define-raft rr-job-fd (_fun _rr-job -> _int))

(define-raft rr-job-status
  (_fun _rr-job (kind : (_ptr o _int32)) -> (status : _int) -> (values status kind)))

(define-raft rr-job-message (_fun _rr-job -> _bytes/nul-terminated))

(define-raft rr-job-read
  (_fun _rr-job (into : _bytes) (_size = (bytes-length into)) -> (status : _int) -> (zero? status)))

(define-raft rr-jobs-in-flight (_fun -> _int64))
(define-raft rr-jobs-live (_fun -> _int64))
(define-raft rr-executor-threads (_fun -> _int64))

(define-raft rr-exit-drain
  (_fun #:blocking?
        #t
        (in-flight : (_ptr o _int64 atomic-interior))
        (still : (_ptr o _int64 atomic-interior))
        -> _void
        -> (values in-flight still)))

(define-raft rr-os-thread-id (_fun -> _uint64))

(define-raft rr-os-thread-id/original
  (_fun #:in-original-place? #t -> _uint64)
  #:c-id rr_os_thread_id)
