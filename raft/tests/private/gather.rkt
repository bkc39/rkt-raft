#lang racket/base

(require (only-in racket/match match match-define)
         (only-in "../../main.rkt"
                  device-matrix
                  device-matrix->list*
                  device-matrix?
                  device-vector->list
                  list*->device-matrix
                  list->device-vector))

(provide contents
         gather-state
         kept
         nonzero-positions
         pick
         random-element
         random-indices
         random-mask
         random-spec
         random-threshold
         spec-length
         taken
         upload)

(define (gather-state)
  (define state (make-pseudo-random-generator))
  (parameterize ([current-pseudo-random-generator state])
    (random-seed 0))
  state)

(define (pick state choices)
  (vector-ref choices (random (vector-length choices) state)))

(define int32-edges (vector 0 1 -1 (sub1 (expt 2 31)) (- (expt 2 31))))
(define int64-edges (vector 0 1 -1 (sub1 (expt 2 31)) (- (expt 2 31)) (expt 2 62) (- (expt 2 62))))
(define float-edges (vector 0.0 -0.0 1.5 -2.25 +inf.0 -inf.0 +nan.0))

(define (random-int32 state)
  (- (random 4294967087 state) 2147483543))

(define (random-element state dtype)
  (define edge? (zero? (random 2 state)))
  (match dtype
    ['int32
     (if edge?
         (pick state int32-edges)
         (random-int32 state))]
    ['int64
     (if edge?
         (pick state int64-edges)
         (+ (* (random-int32 state) 4294967296) (random 4294967087 state)))]
    [_
     (if edge?
         (pick state float-edges)
         (/ (random -4096 4096 state) 64.0))]))

(define dtypes (vector 'float32 'float64 'int32 'int64))
(define layouts (vector 'row-major 'col-major))

(define (random-spec state [rank (pick state (vector 1 2))])
  (define dtype (pick state dtypes))
  (define rows (random 9 state))
  (define (element)
    (random-element state dtype))
  (match rank
    [1
     (list dtype
           'row-major
           (list rows)
           (for/list ([_ (in-range rows)])
             (element)))]
    [2
     (define cols (random 6 state))
     (list dtype
           (pick state layouts)
           (list rows cols)
           (for/list ([_ (in-range rows)])
             (for/list ([_ (in-range cols)])
               (element))))]))

(define (spec-length spec)
  (match-define (list _ _ (cons n _) _) spec)
  n)

(define (random-indices state n)
  (define k
    (if (zero? n)
        0
        (random 13 state)))
  (list (pick state (vector 'int32 'int64))
        (for/list ([_ (in-range k)])
          (random n state))))

(define (random-mask state n)
  (define dtype (pick state (vector 'int32 'int64)))
  (define choices
    (if (eq? dtype 'int64)
        (vector 0 1 -1 7 (expt 2 32))
        (vector 0 1 -1 7)))
  (list dtype
        (for/list ([_ (in-range n)])
          (pick state choices))))

(define (random-threshold state dtype)
  (match dtype
    [(or 'int32 'int64) (pick state (vector 0 1 -1 2.5 -2.5 7 (random-element state dtype)))]
    [_ (random-element state dtype)]))

(define (upload spec)
  (match spec
    [(list dtype _ (list _) xs) (list->device-vector xs #:dtype dtype)]
    [(list dtype order (list 0 cols) _) (device-matrix 0 cols #:dtype dtype #:layout order)]
    [(list dtype order _ rows) (list*->device-matrix rows #:dtype dtype #:layout order)]))

(define (contents a)
  (if (device-matrix? a)
      (device-matrix->list* a)
      (device-vector->list a)))

(define (taken items is)
  (map (lambda (i) (list-ref items i)) is))

(define (nonzero-positions mask)
  (for/list ([m (in-list mask)]
             [i (in-naturals)]
             #:unless (zero? m))
    i))

(define (kept items mask)
  (taken items (nonzero-positions mask)))
