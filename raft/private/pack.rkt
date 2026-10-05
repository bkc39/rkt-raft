#lang racket/base

(require (only-in racket/match match-define)
         (only-in racket/math exact-truncate)
         (only-in "dtype.rkt" dtype-itemsize)
         (only-in "exn.rkt" raise-raft)
         (only-in "foreign/host.rkt" host-getter host-memory host-setter))

(provide element-converter
         infer-dtype
         matrix-shape
         pack-matrix
         pack-vector
         unpack-matrix
         unpack-vector)

(define (infer-dtype who xs)
  (cond
    [(null? xs) 'float64]
    [(andmap exact-integer? xs) 'int64]
    [(andmap real? xs) 'float64]
    [else
     (raise-raft who
                 'logic
                 "cannot infer a dtype: ~e is not a real number"
                 (findf (lambda (x) (not (real? x))) xs))]))

(define (matrix-shape who rows)
  (define cols
    (if (null? rows)
        0
        (length (car rows))))
  (for ([row (in-list rows)]
        [i (in-naturals)])
    (define n (length row))
    (unless (= n cols)
      (raise-raft who 'logic "row ~a has ~a, but row 0 has ~a: ~e" i (elements n) cols row)))
  (list (length rows) cols))

(define (elements n)
  (format "~a element~a" n (if (= n 1) "" "s")))

(define integer-bits (hasheq 'int32 32 'int64 64))

(define (refuse who x problem)
  (raise-raft who 'logic "~e ~a" x problem))

(define ((float-converter who) x)
  (if (real? x)
      (real->double-flonum x)
      (refuse who x "is not a real number")))

(define (integer-converter who dtype)
  (define half (expt 2 (sub1 (hash-ref integer-bits dtype))))
  (lambda (x)
    (define n
      (cond
        [(exact-integer? x) x]
        [(and (real? x) (rational? x)) (exact-truncate x)]
        [(real? x) (refuse who x "is not a finite number")]
        [else (refuse who x "is not a real number")]))
    (if (<= (- half) n (sub1 half))
        n
        (refuse who x (format "does not fit ~a" dtype)))))

(define (element-converter who dtype)
  (case dtype
    [(float32 float64) (float-converter who)]
    [else (integer-converter who dtype)]))

(define (host-for dtype count)
  (host-memory (* count (dtype-itemsize dtype))))

(define (pack-vector who dtype n xs)
  (define host (host-for dtype n))
  (define set (host-setter dtype))
  (define convert (element-converter who dtype))
  (for ([x xs]
        [i (in-range n)])
    (set host i (convert x)))
  host)

(define (pack-matrix who dtype shape strides rows)
  (define host (host-for dtype (apply * shape)))
  (define set (host-setter dtype))
  (define convert (element-converter who dtype))
  (match-define (list row-count col-count) shape)
  (match-define (list row-step col-step) strides)
  (for* ([(row i) (in-parallel (in-list rows) (in-range row-count))]
         [(x j) (in-parallel (in-list row) (in-range col-count))])
    (set host (+ (* i row-step) (* j col-step)) (convert x)))
  host)

(define (unpack-vector dtype n host)
  (define get (host-getter dtype))
  (for/list ([i (in-range n)])
    (get host i)))

(define (unpack-matrix dtype shape strides host)
  (define get (host-getter dtype))
  (match-define (list rows cols) shape)
  (match-define (list row-step col-step) strides)
  (for/list ([i (in-range rows)])
    (for/list ([j (in-range cols)])
      (get host (+ (* i row-step) (* j col-step))))))
