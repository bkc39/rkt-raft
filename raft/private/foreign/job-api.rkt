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
                  _pointer
                  _ptr
                  _size
                  _void
                  define-cpointer-type)
         (only-in "library.rkt" _rr-buffer _rr-resources define-raft))

(provide _rr-job
         rr-executor-threads
         rr-exit-arm
         rr-job-args
         rr-job-done
         rr-job-fd
         rr-job-message
         rr-job-release
         rr-job-status
         rr-job-submit
         rr-job-times
         rr-jobs-in-flight
         rr-jobs-live
         rr-now-ns)

(define-cpointer-type _rr-job)

(define refused 3)

(define-raft rr-job-submit
  (_fun _rr-resources
        _fpointer
        _bytes
        _size
        (pins : (_list i _rr-buffer))
        (_size = (length pins))
        _double*
        (out : (_ptr o _rr-job/null))
        -> (status : _int)
        -> (cond
             [(eqv? status refused) 'refused]
             [(zero? status) out]
             [else #f])))

(define-raft rr-job-fd (_fun _rr-job -> _int))
(define-raft rr-job-done (_fun _rr-job -> _int))

(define-raft rr-job-status
  (_fun _rr-job (kind : (_ptr o _int32)) -> (status : _int) -> (values status kind)))

(define-raft rr-job-message (_fun _rr-job -> _bytes/nul-terminated))
(define-raft rr-job-args (_fun _rr-job -> _pointer))

(define-raft rr-job-times
  (_fun _rr-job (s : (_ptr o _int64)) (b : (_ptr o _int64)) (f : (_ptr o _int64))
        -> _void
        -> (values s b f)))

(define-raft rr-job-release (_fun _rr-job -> _void))

(define-raft rr-jobs-in-flight (_fun -> _int64))
(define-raft rr-jobs-live (_fun -> _int64))
(define-raft rr-executor-threads (_fun -> _int64))
(define-raft rr-now-ns (_fun -> _int64))
(define-raft rr-exit-arm (_fun -> _void))
