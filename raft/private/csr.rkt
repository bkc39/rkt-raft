#lang racket/base

(require (only-in racket/flonum flsingle)
         (only-in racket/list append* filter-not make-list)
         (only-in racket/match match* match-define match-lambda struct*)
         (only-in "array.rkt"
                  array-buffer-handle
                  array-device
                  device-array-dtype
                  device-array-shape
                  settled-arguments*)
         (only-in "error.rkt" call/raft exn:fail:raft?)
         (only-in "exn.rkt" raise-raft)
         (only-in "foreign/csr-api.rkt" rr-csr-check rr-csr-check-shape)
         (only-in "foreign/host.rkt" host-getter host-memory host-setter)
         (only-in "foreign/memory.rkt" released?)
         (only-in "pack.rkt" element-converter elements matrix-shape over-elements)
         (only-in "print.rkt" csr-runs csr-text indented shape-text)
         (only-in "resources.rkt" define/resources)
         (only-in "vector.rkt" read-block read-vector upload-vector))

(provide (rename-out [device-csr-matrix-data csr-data]
                     [device-csr-matrix-indices csr-indices]
                     [device-csr-matrix-indptr csr-indptr])
         checked-csr
         device-csr-matrix
         device-csr-matrix->list*
         device-csr-matrix->triplets
         device-csr-matrix-shape
         device-csr-matrix?
         list*->device-csr-matrix
         nnz
         prefix-sums
         triplets->device-csr-matrix)

(module+ unchecked
  (provide unchecked-device-csr-matrix)) ;; noqa

(struct device-csr-matrix (indptr indices data shape)
  #:name csr-matrix
  #:constructor-name unchecked-device-csr-matrix
  #:property prop:custom-write
  (lambda (m port _mode) (write-string (csr->string m) port)))

(define (int64-extents extents)
  (match-define (list rows cols) extents)
  (define host (host-memory 16))
  (define set (host-setter 'int64))
  (define get (host-getter 'int64))
  (set host 0 rows)
  (set host 1 cols)
  (list (get host 0) (get host 1)))

(define (checked-shape who index-type element-type extents)
  (define checked (int64-extents extents))
  (call/raft who (lambda () (apply rr-csr-check-shape index-type element-type checked)))
  checked)

(define (checked-csr who indptr indices data extents)
  (define checked (int64-extents extents))
  (define arguments (append (settled-arguments* who (list indptr indices data)) checked))
  (call/raft who (lambda () (apply rr-csr-check arguments)))
  (unchecked-device-csr-matrix indptr indices data checked))

(define (device-csr-matrix indptr indices data #:shape extents)
  (checked-csr 'device-csr-matrix indptr indices data extents))

(define (nnz m)
  (match-define (list n) (device-array-shape (device-csr-matrix-indices m)))
  n)

(define (prefix-sums counts)
  (for/fold ([sums '(0)]
             #:result (reverse sums))
            ([n (in-list counts)])
    (cons (+ n (car sums)) sums)))

(define (row-counts row-count entries)
  (define counts
    (for/fold ([counts (hasheqv)]) ([entry (in-list entries)])
      (match-define (vector r _ _) entry)
      (hash-update counts r add1 0)))
  (for/list ([r (in-range row-count)])
    (hash-ref counts r 0)))

(define (build-csr who resources element-type index-type extents entries)
  (match-define (list row-count _) extents)
  (define-values (cols vals)
    (for/fold ([cols '()]
               [vals '()]
               #:result (values (reverse cols) (reverse vals)))
              ([entry (in-list entries)])
      (match-define (vector _ c x) entry)
      (values (cons c cols) (cons x vals))))
  (define indptr
    (upload-vector who resources index-type (prefix-sums (row-counts row-count entries))))
  (define indices (upload-vector who resources index-type cols))
  (define data (upload-vector who resources element-type vals))
  (checked-csr who indptr indices data extents))

(define/resources (list*->device-csr-matrix rows
                                            #:dtype [element-type 'float64]
                                            #:index-dtype [index-type 'int32]
                                            #:cols [cols #f]
                                            #:resources resources
                                            #:who who)
  (define extents (checked-shape who index-type element-type (matrix-shape who rows cols)))
  (define convert (element-converter who element-type))
  (define entries
    (append* (over-elements (for/list ([row rows]
                                       [i (in-naturals)])
                              (filter-not (match-lambda
                                            [(vector _ _ x) (= x 0)])
                                          (over-elements (for/list ([x row]
                                                                    [j (in-naturals)])
                                                           (vector i j (convert x)))))))))
  (build-csr who resources element-type index-type extents entries))

(define (adder element-type)
  (case element-type
    [(float32) (lambda (a b) (flsingle (+ a b)))]
    [else +]))

(define (check-index who k name x extent)
  (cond
    [(not (exact-integer? x))
     (raise-raft who 'logic "triplet ~a has ~a ~a, not an exact integer" k name x)]
    [(not (< -1 x extent))
     (raise-raft who 'logic "triplet ~a has ~a ~a, outside [0, ~a)" k name x extent)]
    [else x]))

(define (check-length who name xs n)
  (define m (length xs))
  (unless (= m n)
    (raise-raft who 'logic "~a has ~a, but rows has ~a" name (elements m) n)))

(define (summed add entries)
  (for/fold ([out '()]
             #:result (reverse out))
            ([entry (in-list entries)])
    (match* (out entry)
      [((cons (vector r c sum) more) (vector r c x)) (cons (vector r c (add sum x)) more)]
      [(_ _) (cons entry out)])))

(define (entry<? a b)
  (match* (a b)
    [((vector r c _) (vector r* c* _)) (or (< r r*) (and (= r r*) (< c c*)))]))

(define/resources (triplets->device-csr-matrix rows
                                               cols
                                               vals
                                               #:shape extents
                                               #:dtype [element-type 'float64]
                                               #:index-dtype [index-type 'int32]
                                               #:resources resources
                                               #:who who)
  (define checked (checked-shape who index-type element-type extents))
  (match-define (list row-count col-count) checked)
  (define n (length rows))
  (check-length who "cols" cols n)
  (check-length who "vals" vals n)
  (define convert (element-converter who element-type))
  (define triplets
    (for/list ([r (in-list rows)]
               [c (in-list cols)]
               [x (in-list vals)]
               [k (in-naturals)])
      (vector (check-index who k "row" r row-count)
              (check-index who k "col" c col-count)
              (convert x))))
  (build-csr who
             resources
             element-type
             index-type
             checked
             (summed (adder element-type) (sort triplets entry<?))))

(define (storage who m)
  (match-define (struct* csr-matrix ([indptr indptr] [indices indices] [data data])) m)
  (values (read-vector who indptr) (read-vector who indices) (read-vector who data)))

(define (expanded-rows indptr)
  (append* (for/list ([start (in-list indptr)]
                      [end (in-list (cdr indptr))]
                      [r (in-naturals)])
             (make-list (- end start) r))))

(define (device-csr-matrix->triplets m)
  (define-values (indptr indices data) (storage 'device-csr-matrix->triplets m))
  (values (expanded-rows indptr) indices data))

(define (device-csr-matrix->list* m)
  (match-define (struct* csr-matrix ([data part] [shape (list rows cols)])) m)
  (define-values (indptr indices data) (storage 'device-csr-matrix->list* m))
  (define add (adder (device-array-dtype part)))
  (define dense
    (for/vector #:length rows
                ([_ (in-range rows)])
      (make-vector cols 0.0)))
  (for ([r (in-list (expanded-rows indptr))]
        [c (in-list indices)]
        [x (in-list data)])
    (define row (vector-ref dense r))
    (vector-set! row c (add (vector-ref row c) x)))
  (for/list ([row (in-vector dense)])
    (vector->list row)))

(define (element-at who v k)
  (car (read-block who v k 1)))

(define (row-of who indptr k from rows)
  (let search ([lo from]
               [hi (sub1 rows)])
    (define mid (quotient (+ lo hi 1) 2))
    (cond
      [(>= lo hi) lo]
      [(<= (element-at who indptr mid) k) (search mid hi)]
      [else (search lo (sub1 mid))])))

(define (run-entries who m rows run from)
  (match-define (struct* csr-matrix ([indptr indptr] [indices indices] [data data])) m)
  (match-define (cons start count) run)
  (for/fold ([entries '()]
             [row from]
             #:result (values (reverse entries) row))
            ([k (in-naturals start)]
             [c (in-list (read-block who indices start count))]
             [x (in-list (read-block who data start count))])
    (define r (row-of who indptr k row rows))
    (values (cons (list r c x) entries) r)))

(define (shown-runs who m)
  (match-define (struct* csr-matrix ([shape (list rows _)])) m)
  (for/fold ([runs '()]
             [row 0]
             #:result (reverse runs))
            ([run (in-list (csr-runs (nnz m)))])
    (define-values (entries last-row) (run-entries who m rows run row))
    (values (cons entries runs) last-row)))

(define (entries-text m)
  (match-define (struct* csr-matrix ([indptr indptr] [indices indices] [data data])) m)
  (cond
    [(ormap (lambda (part) (released? (array-buffer-handle part))) (list indptr indices data))
     " <released>"]
    [(zero? (nnz m)) ""]
    [else
     (with-handlers ([exn:fail:raft? (lambda (e)
                                       (format " <values unavailable: ~a>" (exn-message e)))])
       (indented (csr-text (device-array-dtype data) (shown-runs 'device-csr-matrix m))))]))

(define (csr->string m)
  (match-define (struct* csr-matrix ([indptr indptr] [data data] [shape extents])) m)
  (format "#<device-csr-matrix ~a ~a nnz=~a index=~a cuda:~a~a>"
          (device-array-dtype data)
          (shape-text extents)
          (nnz m)
          (device-array-dtype indptr)
          (array-device indptr)
          (entries-text m)))
