#lang racket/base

(require (only-in racket/match match match* match-define)
         (only-in racket/math exact-truncate)
         (only-in "dtype.rkt" dtype-itemsize)
         (only-in "exn.rkt" raise-raft)
         (only-in "foreign/host.rkt" host-getter host-memory host-setter))

(provide element-converter
         infer-dtype
         infer-rows-dtype
         matrix-shape
         pack-matrix
         pack-row-major
         pack-vector
         unpack-matrix
         unpack-row-major
         unpack-vector)

(define (widen who kind x)
  (cond
    [(not (real? x)) (raise-raft who 'logic "cannot infer a dtype: ~e is not a real number" x)]
    [(and (exact-integer? x) (not (eq? kind 'float64))) 'int64]
    [else 'float64]))

(define (infer-dtype who xs)
  (or (for/fold ([kind #f]) ([x xs])
        (widen who kind x))
      'float64))

(define (infer-rows-dtype who rows)
  (or (for*/fold ([kind #f])
                 ([row rows]
                  [x row])
        (widen who kind x))
      'float64))

(define (extent row)
  (if (vector? row)
      (vector-length row)
      (length row)))

(define (matrix-shape who rows)
  (define cols
    (for/first ([row rows])
      (extent row)))
  (for ([row rows]
        [i (in-naturals)])
    (define n (extent row))
    (unless (= n cols)
      (raise-raft who 'logic "row ~a has ~a, but row 0 has ~a: ~e" i (elements n) cols row)))
  (list (extent rows) (or cols 0)))

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
  (for ([row rows]
        [i (in-range row-count)])
    (for ([x row]
          [j (in-range col-count)])
      (set host (+ (* i row-step) (* j col-step)) (convert x))))
  host)

(define (pack-row-major who dtype shape strides xs)
  (match* (shape strides)
    [((list n) _) (pack-vector who dtype n xs)]
    [((list rows cols) (list row-step col-step))
     #:when (not (and (= row-step cols) (= col-step 1)))
     (define host (host-for dtype (* rows cols)))
     (define set (host-setter dtype))
     (define convert (element-converter who dtype))
     (for ([x xs]
           [k (in-range (* rows cols))])
       (define-values (i j) (quotient/remainder k cols))
       (set host (+ (* i row-step) (* j col-step)) (convert x)))
     host]
    [((list rows cols) _) (pack-vector who dtype (* rows cols) xs)]))

(define (unpack-vector dtype n host #:into [into 'list])
  (define get (host-getter dtype))
  (case into
    [(vector)
     (for/vector #:length n
                 ([i (in-range n)])
       (get host i))]
    [else
     (for/list ([i (in-range n)])
       (get host i))]))

(define (unpack-matrix dtype shape strides host #:into [into 'list])
  (define get (host-getter dtype))
  (match-define (list rows cols) shape)
  (match-define (list row-step col-step) strides)
  (define (element i j)
    (get host (+ (* i row-step) (* j col-step))))
  (case into
    [(vector)
     (for/vector #:length rows
                 ([i (in-range rows)])
       (for/vector #:length cols
                   ([j (in-range cols)])
         (element i j)))]
    [else
     (for/list ([i (in-range rows)])
       (for/list ([j (in-range cols)])
         (element i j)))]))

(define (unpack-row-major dtype shape strides host)
  (define get (host-getter dtype))
  (match* (shape strides)
    [((list n) _)
     (for/vector #:length n
                 ([i (in-range n)])
       (get host i))]
    [((list rows cols) (list row-step col-step))
     (for*/vector #:length (* rows cols)
                  ([i (in-range rows)]
                   [j (in-range cols)])
       (get host (+ (* i row-step) (* j col-step))))]))
