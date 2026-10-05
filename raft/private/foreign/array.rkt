#lang racket/base

(require (only-in ffi/unsafe
                  _array/vector
                  _fun
                  _int
                  _int32
                  _int64
                  _pointer
                  _ptr
                  _size
                  ctype-sizeof
                  define-cstruct)
         (only-in racket/list make-list take)
         (only-in "host.rkt" _host host-bytes)
         (only-in "library.rkt" _rr-buffer _rr-buffer/null _rr-resources define-raft)
         (only-in "memory.rkt" buffer-allocator))

(provide blank-view
         describe-view!
         rr-buffer-alloc
         rr-copy-d2h
         rr-copy-h2d
         rr-view-size
         (rename-out [rr-view-device view-device] [rr-view-dtype view-dtype-code]) ;; noqa
         view-shape
         view-strides
         _rr-view-pointer) ;; noqa

(define max-rank 8)

(define-cstruct _rr-view
  ([data _pointer]
   [dtype _int32]
   [memory _int32]
   [device _int32]
   [rank _int32]
   [shape (_array/vector _int64 max-rank)]
   [strides (_array/vector _int64 max-rank)])
  #:malloc-mode 'atomic-interior)

(define rr-view-size (ctype-sizeof _rr-view))

(define (padded xs)
  (list->vector (append xs (make-list (- max-rank (length xs)) 0))))

(define (blank-view)
  (make-rr-view #f -1 -1 -1 0 (padded '()) (padded '())))

(define (describe-view! view dtype-code shape strides)
  (set-rr-view-dtype! view dtype-code)
  (set-rr-view-rank! view (length shape))
  (set-rr-view-shape! view (padded shape))
  (set-rr-view-strides! view (padded strides))
  view)

(define (view-list v view)
  (take (vector->list v) (rr-view-rank view)))

(define (view-shape view)
  (view-list (rr-view-shape view) view))

(define (view-strides view)
  (view-list (rr-view-strides view) view))

(define-raft rr-buffer-alloc
  (_fun _rr-resources _size (out : (_ptr o _rr-buffer/null))
        -> (status : _int)
        -> (and (zero? status) out))
  #:wrap buffer-allocator)

(define-raft rr-copy-h2d
  (_fun _rr-buffer (host : _host) (_size = (host-bytes host)) -> (status : _int) -> (zero? status)))

(define-raft rr-copy-d2h
  (_fun (host : _host) _rr-buffer (_size = (host-bytes host)) -> (status : _int) -> (zero? status)))
