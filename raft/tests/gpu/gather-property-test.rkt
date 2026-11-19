#lang racket/base

(require (only-in racket/list append* make-list range)
         (only-in racket/match match match-define)
         (only-in racket/math nan?)
         (only-in rackunit check-equal? check-false check-true)
         ;; whole-module: it also provides syntax/parse at phase 1
         syntax/parse/define
         (only-in "../../main.rkt"
                  compare
                  contiguous?
                  dtype
                  gather
                  layout
                  list->device-vector
                  select
                  shape
                  strides)
         (only-in "../../private/array.rkt" canonical-strides device-array-buffer)
         (only-in "../../private/pack.rkt" element-converter)
         (only-in "../private/gather.rkt"
                  contents
                  gather-state
                  kept
                  nonzero-positions
                  pick
                  random-indices
                  random-mask
                  random-spec
                  random-threshold
                  spec-length
                  taken
                  upload)
         (only-in "../private/gpu.rkt" test-gpu))

(define (index-vector spec)
  (match-define (list element-type is) spec)
  (list->device-vector is #:dtype element-type))

(define (extent a)
  (match-define (cons n _) (shape a))
  n)

(define (summary a)
  (list (contents a) (dtype a) (shape a) (layout a)))

(define (elementwise f spec)
  (match spec
    [(list _ _ (list _) xs) (map f xs)]
    [(list _ _ _ rows) (map (lambda (row) (map f row)) rows)]))

(define (flat a)
  (match (shape a)
    [(list _) (contents a)]
    [_ (append* (contents a))]))

(define-syntax-parse-rule (test-law name:str (state:id) body:expr ...+)
  (test-gpu name
    (define state (gather-state))
    (for ([_ (in-range 200)])
      body ...)))

(test-law "law 1: gathering a vector takes its elements at the indices, in order" (state)
  (define spec (random-spec state 1))
  (match-define (list element-type _ _ xs) spec)
  (match-define (and index-spec (list _ is)) (random-indices state (length xs)))
  (define r (gather (upload spec) (index-vector index-spec)))
  (define label (format "~s by ~s" spec index-spec))
  (check-equal? (contents r) (taken xs is) label)
  (check-equal? (dtype r) element-type label)
  (check-equal? (shape r) (list (length is)) label))

(test-law "law 2: gathering a matrix takes its rows at the indices, in the matrix's layout" (state)
  (define spec (random-spec state 2))
  (match-define (list element-type _ (list n cols) rows) spec)
  (match-define (and index-spec (list _ is)) (random-indices state n))
  (define M (upload spec))
  (define r (gather M (index-vector index-spec)))
  (define label (format "~s by ~s" spec index-spec))
  (check-equal? (contents r) (taken rows is) label)
  (check-equal? (dtype r) element-type label)
  (check-equal? (shape r) (list (length is) cols) label)
  (check-true (contiguous? r #:layout (layout M)) label)
  (check-equal? (strides r) (canonical-strides (layout M) (shape r)) label))

(test-law "law 3: gathering every index in order copies the array, in both index dtypes" (state)
  (define spec (random-spec state))
  (define a (upload spec))
  (for ([index-type (in-list '(int32 int64))])
    (define r (gather a (list->device-vector (range (spec-length spec)) #:dtype index-type)))
    (check-equal? (summary r) (summary a) (format "~s by ~a" spec index-type))
    (check-false (eq? (device-array-buffer r) (device-array-buffer a)))))

(test-law "law 4: a gather of a gather is a gather by the gathered indices" (state)
  (define spec (random-spec state))
  (define a (upload spec))
  (match-define (and I-spec (list _ is)) (random-indices state (spec-length spec)))
  (define J-spec (random-indices state (length is)))
  (define I (index-vector I-spec))
  (define J (index-vector J-spec))
  (check-equal? (contents (gather (gather a I) J))
                (contents (gather a (gather I J)))
                (format "~s by ~s then ~s" spec I-spec J-spec)))

(test-law "law 5: select keeps the elements or rows where the mask is not zero, in order" (state)
  (define spec (random-spec state))
  (match-define (list _ _ (cons n _) items) spec)
  (match-define (and mask-spec (list _ m)) (random-mask state n))
  (define r (select (upload spec) (index-vector mask-spec)))
  (define label (format "~s by ~s" spec mask-spec))
  (check-equal? (contents r) (kept items m) label)
  (check-equal? (extent r) (length (nonzero-positions m)) label))

(test-law "law 6: an all-ones mask copies the array and an all-zero mask keeps nothing" (state)
  (define spec (random-spec state))
  (define n (spec-length spec))
  (define a (upload spec))
  (define (mask x)
    (list->device-vector (make-list n x) #:dtype (pick state (vector 'int32 'int64))))
  (define ones (select a (mask 1)))
  (check-equal? (summary ones) (summary a) (format "~s" spec))
  (check-false (eq? (device-array-buffer ones) (device-array-buffer a)))
  (define zeros (select a (mask 0)))
  (check-equal? (shape zeros) (cons 0 (cdr (shape a))) (format "~s" spec))
  (check-equal? (dtype zeros) (dtype a)))

(test-law "law 7: select is a gather of the mask's nonzero positions" (state)
  (define spec (random-spec state))
  (define a (upload spec))
  (match-define (and mask-spec (list _ m)) (random-mask state (spec-length spec)))
  (define positions (list->device-vector (nonzero-positions m) #:dtype 'int64))
  (check-equal? (summary (select a (index-vector mask-spec)))
                (summary (gather a positions))
                (format "~s by ~s" spec mask-spec)))

(define (column rows j)
  (map (lambda (row) (list-ref row j)) rows))

(test-law "law 8: a matrix's rows are taken as its columns' elements are, column by column" (state)
  (define spec (random-spec state 2))
  (match-define (list element-type _ (list n cols) rows) spec)
  (define M (upload spec))
  (define I (index-vector (random-indices state n)))
  (define mask (index-vector (random-mask state n)))
  (define by-index (contents (gather M I)))
  (define by-mask (contents (select M mask)))
  (for ([j (in-range cols)])
    (define v (list->device-vector (column rows j) #:dtype element-type))
    (check-equal? (column by-index j) (contents (gather v I)) (format "~s at ~a" spec j))
    (check-equal? (column by-mask j) (contents (select v mask)) (format "~s at ~a" spec j))))

(test-law "law 9: select is idempotent, and a mask and its zeros partition the rows" (state)
  (define spec (random-spec state))
  (define a (upload spec))
  (define mask (index-vector (random-mask state (spec-length spec))))
  (define s (select a mask))
  (define ones (list->device-vector (make-list (extent s) 1) #:dtype 'int32))
  (check-equal? (contents (select s ones)) (contents s) (format "~s" spec))
  (check-equal? (+ (extent (select a (compare mask '= 0))) (extent s))
                (spec-length spec)
                (format "~s" spec)))

(define comparisons (hasheq '= = '< < '<= <= '> > '>= >=))

(test-law "law 10: compare gives 1 where the element compares true to the converted scalar" (state)
  (define spec (random-spec state))
  (match-define (list element-type _ _ _) spec)
  (define op (pick state (vector '= '< '<= '> '>=)))
  (define x (random-threshold state element-type))
  (define x* ((element-converter 'compare element-type #:exact? #t) x))
  (define holds? (hash-ref comparisons op))
  (define a (upload spec))
  (define r (compare a op x))
  (define label (format "~s ~a ~s" spec op x))
  (check-equal? (contents r) (elementwise (lambda (e) (if (holds? e x*) 1 0)) spec) label)
  (check-equal? (list (dtype r) (shape r) (strides r)) (list 'int32 (shape a) (strides a)) label))

(test-law "law 11: < and >=, and > and <=, are complements except at NaN" (state)
  (define spec (random-spec state))
  (match-define (list element-type _ _ _) spec)
  (define x (random-threshold state element-type))
  (define x* ((element-converter 'compare element-type #:exact? #t) x))
  (define a (upload spec))
  (define expected (map (lambda (e) (if (or (nan? e) (nan? x*)) 0 1)) (flat a)))
  (for ([pair (in-list '((< >=) (> <=)))])
    (match-define (list op other) pair)
    (check-equal? (map + (flat (compare a op x)) (flat (compare a other x)))
                  expected
                  (format "~s ~a/~a ~s" spec op other x))))
