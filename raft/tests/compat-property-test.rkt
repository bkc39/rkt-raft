#lang racket/base

(require (only-in racket/list append*)
         (only-in racket/match match-define)
         (only-in rackunit check-equal?)
         (only-in "../main.rkt" dtype layout list*->device-matrix list->device-vector shape)
         (only-in "private/arrays.rkt" storage)
         (only-in "private/gpu.rkt" test-gpu)
         (only-in "private/representations.rkt"
                  converted
                  sink-back
                  sink-holds
                  sink-name
                  sink-rank
                  sink-rows
                  sinks
                  source-holds
                  source-name
                  source-rank
                  source-send
                  sources))

(define all-dtypes '(float32 float64 int32 int64))
(define both-layouts '(row-major col-major))
(define extents '(0 1 2 3 5))

(define generator (make-pseudo-random-generator))

(define (random-element dtype)
  (parameterize ([current-pseudo-random-generator generator])
    (case dtype
      [(int32 int64)
       (case (random 3)
         [(0) (- (random 4000000) 2000000)]
         [(1) (- (* (random) 4e8) 2e8)]
         [else (- (random 2000001) 1000000)])]
      [else
       (case (random 3)
         [(0) (- (* (random) 2e6) 1e6)]
         [(1) (/ (- (random 2001) 1000) (add1 (random 64)))]
         [else (- (random 20001) 10000)])])))

(define (random-rows dtype rows cols)
  (for/list ([_ (in-range rows)])
    (for/list ([_ (in-range cols)])
      (random-element dtype))))

(define (map-rows f rows)
  (for/list ([row (in-list rows)])
    (map f row)))

(define (in-storage-order order rows)
  (cond
    [(null? rows) '()]
    [(eq? order 'row-major) (append* rows)]
    [else (append* (apply map list rows))]))

(define (shape-sent src rows cols)
  (cond
    [(= (source-rank src) 1) (list cols)]
    [(and (zero? rows) (memq (source-name src) '(list* vector*))) '(0 0)]
    [(and (zero? rows) (memq (source-name src) '(list*-array vector*-array))) '(0)]
    [else (list rows cols)]))

(define (shapes rank)
  (if (= rank 1)
      (for/list ([n (in-list extents)])
        (list 1 n))
      (for*/list ([r (in-list extents)]
                  [c (in-list extents)])
        (list r c))))

(test-gpu "every source sends any shape, dtype and layout, packed by its strides"
  (for* ([src (in-list sources)]
         [d (in-list all-dtypes)]
         [order (in-list both-layouts)]
         [extent (in-list (shapes (source-rank src)))])
    (match-define (list rows cols) extent)
    (define data (map-rows (source-holds src) (random-rows d rows cols)))
    (define expected (map-rows (lambda (x) (converted d x)) data))
    (define a ((source-send src) data cols d order))
    (define label (format "~a ~a ~a ~a" (source-name src) d order extent))
    (define sent-shape (shape-sent src rows cols))
    (check-equal? (list (shape a) (dtype a)) (list sent-shape d) label)
    (define used-order (if (= (length sent-shape) 2) order 'row-major))
    (when (and (= (length sent-shape) 2) (> (apply min sent-shape) 1))
      (check-equal? (layout a) order label))
    (check-equal? (storage a) (in-storage-order used-order expected) label)))

(test-gpu "every sink brings back any shape and dtype, from either layout"
  (for* ([snk (in-list sinks)]
         [d (in-list all-dtypes)]
         [order (in-list both-layouts)]
         [extent (in-list (shapes (sink-rank snk)))])
    (match-define (list rows cols) extent)
    (define expected (map-rows (lambda (x) (converted d x)) (random-rows d rows cols)))
    (define label (format "~a ~a ~a ~a" (sink-name snk) d order extent))
    (define a
      (if (= (sink-rank snk) 1)
          (list->device-vector (car expected) #:dtype d)
          (list*->device-matrix expected #:dtype d #:layout order)))
    (define back ((sink-back snk) a))
    (define wanted
      (if (and (= (sink-rank snk) 2) (zero? rows))
          '()
          (map-rows (sink-holds snk) expected)))
    (check-equal? ((sink-rows snk) back d) wanted label)))
