#lang racket/base

(require (only-in racket/list filter-map)
         (only-in racket/match match match-define match-lambda)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path
         (only-in rackunit check-equal? check-pred check-true fail)
         (only-in "../../main.rkt" compare contiguous? dtype exn:fail:raft? gather select shape)
         (only-in "../private/arrays.rkt" part)
         (only-in "../private/gather.rkt"
                  contents
                  gather-state
                  pick
                  random-element
                  random-indices
                  random-mask
                  random-spec
                  spec-length
                  upload)
         (only-in "../private/python-env.rkt" decoded encoded run-twin test-twin))

(define-runtime-path twin "../python/gather.py")

(define rows-5 '((0.0 1.0) (2.0 3.0) (4.0 5.0) (6.0 7.0) (8.0 9.0)))
(define rows-4 '((0.0 1.0) (2.0 3.0) (4.0 5.0) (6.0 7.0)))
(define f-4x3 '((0.0 1.0 2.0) (3.0 4.0 5.0) (6.0 7.0 8.0) (9.0 10.0 11.0)))

(define fixed-cases
  `(("G1 float32 indices" (gather (float32 C (5 2) ,rows-5) (float32 0 1))
                          (refused "gather: indices: expected int32 or int64, got float32"))
    ("G2 a matrix as indices" (gather (float32 C (5 2) ,rows-5) (matrix int32 (0) (1)))
                              (departs "gather: indices: expected rank 1, got rank 2"))
    ("G4 an index past the rows" (gather (float32 C (5 2) ,rows-5) (int32 3 0 7))
                                 (refused "gather: indices: entry 2 is 7, outside [0, 5)"))
    ("G4' a negative index" (gather (float32 C (5 2) ,rows-5) (int32 -1 0))
                            (departs "gather: indices: entry 0 is -1, outside [0, 5)"))
    ("G4'' an int64 index beyond int32"
     (gather (float32 C (5 2) ,rows-5) (int64 3000000000))
     (refused "gather: indices: entry 0 is 3000000000, outside [0, 5)"))
    ("G4''' an index into no rows" (gather (float32 C (0 3) ()) (int32 0))
                                   (refused "gather: indices: entry 0 is 0, outside [0, 0)"))
    ("M1 a float64 mask" (select (float64 C (4 2) ,rows-4) (float64 1 0 1 0))
                         (departs "select: mask: expected int32 or int64, got float64"))
    ("M2 a matrix as mask" (select (float64 C (4 2) ,rows-4) (matrix int32 (1) (0) (1) (0)))
                           (refused "select: mask: expected rank 1, got rank 2"))
    ("M3 a mask one short" (select (float64 C (4 2) ,rows-4) (int32 1 0 1))
                           (departs "select: mask: expected 4 elements, got 3"))
    ("M3 a mask one long" (select (float64 C (4 2) ,rows-4) (int32 1 0 1 0 1))
                          (refused "select: mask: expected 4 elements, got 5"))
    ("C1 not equal" (compare (int32 C (2) (1 2)) != 0)
                    (departs "compare: unsupported comparison !=; expected =, <, <=, > or >="))
    ("C2 int32 below 3000000000" (compare (int32 C (3) (0 1 -1)) < 3000000000)
                                 (departs "compare: 3000000000 does not fit int32"))
    ("C3 int32 below NaN" (compare (int32 C (2) (1 2)) < +nan.0)
                          (departs "compare: +nan.0 is not a finite number"))
    ("C4 float32 below 1e300" (compare (float32 C (2) (1.0 2.0)) < 1e300)
                              (departs "compare: 1e+300 does not fit float32"))
    ("int32 at least 0.5" (compare (int32 C (3) (0 1 -1)) >= 0.5) (differs (1 1 0)))
    ("an empty vector by no indices" (gather (float64 C (0) ()) (int32)) agrees)
    ("a 0×3 matrix by no indices" (gather (float32 C (0 3) ()) (int64)) agrees)
    ("a 3×0 matrix" (gather (float64 C (3 0) (() () ())) (int32 2 0)) agrees)
    ("a 3×0 matrix by a mask" (select (int32 C (3 0) (() () ())) (int32 1 0 1)) agrees)
    ("no indices" (gather (int64 C (5) (1 2 3 4 5)) (int32)) agrees)
    ("an all-zero mask" (select (float32 C (4 2) ,rows-4) (int64 0 0 0 0)) agrees)
    ("a repeat" (gather (float32 C (5 2) ,rows-5) (int32 1 1 1)) agrees)
    ("the reverse permutation" (gather (int32 C (5) (10 20 30 40 50)) (int64 4 3 2 1 0)) agrees)
    ("NaN and -0.0 payloads" (gather (float32 C (4) (+nan.0 -0.0 0.0 1.5)) (int32 1 0 2 0)) agrees)
    ("int64 beyond int32" (gather (int64 C (3) (,(expt 2 62) ,(- (expt 2 62)) 1)) (int32 1 0)) agrees)
    ("an F-order 4×3 by index" (gather (float32 F (4 3) ,f-4x3) (int32 3 0 2)) agrees)
    ("an F-order 4×3 by mask" (select (float64 F (4 3) ,f-4x3) (int32 1 0 1 1)) agrees)
    ("an F-order 4×3 compared" (compare (float32 F (4 3) ,f-4x3) >= 5.0) agrees)
    ("an int64 mask holding 2^32" (select (float32 C (4 2) ,rows-4) (int64 ,(expt 2 32) 0 -1 0))
                                  agrees)
    ("NaN compares false" (compare (float64 C (3) (+nan.0 1.0 -0.0)) <= 0.0) agrees)))

(define (spec->array spec)
  (match-define (list element-type order extents data) spec)
  (list element-type (if (eq? order 'F) 'col-major 'row-major) extents data))

(define (generated-case state k)
  (define spec (random-spec state))
  (match-define (list element-type layout extents data) spec)
  (define n (spec-length spec))
  (define source (list element-type (if (eq? layout 'col-major) 'F 'C) extents data))
  (define form
    (match (pick state (vector 'gather 'select 'compare))
      ['gather (list 'gather source (random-indices state n))]
      ['select (list 'select source (random-mask state n))]
      ['compare
       (list 'compare
             source
             (pick state (vector '= '< '<= '> '>=))
             (random-element state element-type))]))
  (list (format "generated ~a" k) form 'agrees))

(define cases
  (append fixed-cases
          (let ([state (gather-state)])
            (for/list ([k (in-range 50)])
              (generated-case state k)))))

(define (operand-json key spec)
  (match spec
    [(list* 'matrix element-type rows)
     (hasheq key rows (dtype-key key) (symbol->string element-type))]
    [(cons element-type xs) (hasheq key xs (dtype-key key) (symbol->string element-type))]))

(define (dtype-key key)
  (string->symbol (format "~a_dtype" key)))

(define (form->json form)
  (match-define (list* kind (list element-type order extents data) more) form)
  (define base
    (hasheq 'kind (symbol->string kind)
            'dtype (symbol->string element-type)
            'order (symbol->string order)
            'shape extents
            'data (encoded data)))
  (define extra
    (match (cons kind more)
      [(list 'gather indices) (operand-json 'indices indices)]
      [(list 'select mask) (operand-json 'mask mask)]
      [(list 'compare op x) (hasheq 'op (symbol->string op) 'x (encoded x))]))
  (for/fold ([h base]) ([(k v) (in-hash extra)])
    (hash-set h k v)))

(define (ours form)
  (match-define (list* kind spec more) form)
  (define a (upload (spec->array spec)))
  (with-handlers ([exn:fail:raft? exn-message])
    (match (cons kind more)
      [(list 'gather indices) (gather a (part indices))]
      [(list 'select mask) (select a (part mask))]
      [(list 'compare op x) (compare a op x)])))

(define (described r)
  (if (hash-ref r 'error #f)
      (hash-ref r 'error)
      (list (decoded (hash-ref r 'values)) (hash-ref r 'shape) (hash-ref r 'dtype))))

(define (check-layout label form m r)
  (match-define (list* kind (list _ order _ _) _) form)
  (check-true (contiguous? m #:layout (if (eq? order 'F) 'col-major 'row-major)) label)
  (check-true (hash-ref r (if (and (eq? order 'F) (eq? kind 'compare)) 'f_contiguous 'c_contiguous))
              label))

(define (check-case name form expected r)
  (define m (ours form))
  (define valid? (hash-ref r 'valid))
  (define label (format "~a (ours: ~a; NumPy: ~a)" name (if (string? m) m "built") (described r)))
  (match expected
    [(list 'refused message) (check-equal? (list m valid?) (list message #f) label)]
    [(list 'departs message) (check-equal? (list m valid?) (list message #t) label)]
    [(list 'differs values)
     (check-true valid? label)
     (check-equal? (contents m) values label)
     (check-pred (lambda (v) (not (equal? v values))) (decoded (hash-ref r 'values)) label)]
    ['agrees
     (cond
       [(string? m) (fail label)]
       [else
        (check-true valid? label)
        (check-equal? (list (contents m) (shape m) (symbol->string (dtype m))) (described r) label)
        (check-layout label form m r)
        (check-equal? (described (hash-ref r 'cupy)) (described r) (format "~a: CuPy" name))])]))

(test-twin "law 18: every case is taken, kept or compared as NumPy does, or departs where pinned"
  (define results
    (hash-ref (run-twin twin
                        (hasheq 'cases (map (match-lambda
                                              [(list _ form _) (form->json form)])
                                            cases)))
              'results))
  (check-equal? (length results) (length cases))
  (for ([c (in-list cases)]
        [r (in-list results)])
    (match-define (list name form expected) c)
    (check-case name form expected r))
  (define departures
    (filter-map (lambda (c)
                  (match c
                    [(list name _ (cons (or 'departs 'differs) _)) name]
                    [_ #f]))
                cases))
  (printf "twin gather: ~a cases, ~a named departures: ~a\n"
          (length cases)
          (length departures)
          departures)
  (for ([c (in-list cases)]
        [r (in-list results)])
    (match c
      [(list _ _ 'agrees) (void)]
      [(list name _ _)
       (printf "twin gather: ~a: NumPy ~a; CuPy ~a\n"
               name
               (described r)
               (described (hash-ref r 'cupy)))])))
