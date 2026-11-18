#lang racket/base

(require (only-in racket/flonum flsingle)
         (only-in racket/list append* make-list)
         (only-in racket/match match match* match-define)
         (only-in racket/string string-replace)
         (only-in "array.rkt"
                  allocate-array
                  array-buffer-handle
                  array-device
                  device-array-dtype
                  device-array-offset
                  device-array-shape
                  read-all
                  read-array
                  settled-descriptor
                  write-array!)
         (only-in "dtype.rkt" dtype-itemsize)
         (only-in "error.rkt" call/raft exn:fail:raft?)
         (only-in "exn.rkt" raise-raft)
         (only-in "foreign/csr-api.rkt" rr-csr-check)
         (only-in "foreign/host.rkt" host-getter host-memory)
         (only-in "foreign/memory.rkt" released?)
         (only-in "pack.rkt"
                  element-converter
                  elements
                  matrix-shape
                  over-elements
                  pack-vector
                  unpack-vector)
         (only-in "print.rkt" csr-runs csr-text shape-text)
         (only-in "resources.rkt" current-device-resources))

(provide csr-data
         csr-indices
         csr-indptr
         device-csr-matrix
         device-csr-matrix->list*
         device-csr-matrix->triplets
         device-csr-matrix-data
         device-csr-matrix-shape
         device-csr-matrix?
         list*->device-csr-matrix
         nnz
         parts->device-csr-matrix ;; noqa
         triplets->device-csr-matrix)

(struct device-csr-matrix (indptr indices data shape)
  #:constructor-name parts->device-csr-matrix
  #:omit-define-syntaxes
  #:property prop:custom-write
  (lambda (m port _mode) (write-string (csr->string m) port)))

(define (checked-csr who indptr indices data extents)
  (match-define (list rows cols) extents)
  (define indptr-view (settled-descriptor who indptr))
  (define indices-view (settled-descriptor who indices))
  (define data-view (settled-descriptor who data))
  (call/raft who
             (lambda ()
               (rr-csr-check (array-buffer-handle indptr)
                             (device-array-offset indptr)
                             indptr-view
                             (array-buffer-handle indices)
                             (device-array-offset indices)
                             indices-view
                             (array-buffer-handle data)
                             (device-array-offset data)
                             data-view
                             rows
                             cols)))
  (parts->device-csr-matrix indptr indices data extents))

(define (device-csr-matrix indptr indices data #:shape extents) ;; noqa
  (checked-csr 'device-csr-matrix indptr indices data extents))

(define (csr-indptr m)
  (device-csr-matrix-indptr m))

(define (csr-indices m)
  (device-csr-matrix-indices m))

(define (csr-data m)
  (device-csr-matrix-data m))

(define (nnz m)
  (car (device-array-shape (device-csr-matrix-indices m))))

(define (upload who resources dtype xs)
  (define n (length xs))
  (define v (allocate-array who resources dtype 'row-major (list n)))
  (write-array! who v (pack-vector who dtype n xs)))

(define (prefix-sums counts)
  (for/fold ([sums '(0)]
             #:result (reverse sums))
            ([n (in-list counts)])
    (cons (+ n (car sums)) sums)))

(define (build-csr who resources element-type index-type extents counts cols vals)
  (define indptr (upload who resources index-type (prefix-sums counts)))
  (define indices (upload who resources index-type cols))
  (define data (upload who resources element-type vals))
  (checked-csr who indptr indices data extents))

(define (list*->device-csr-matrix rows
                                  #:dtype [element-type 'float64]
                                  #:index-dtype [index-type 'int32]
                                  #:resources [resources (current-device-resources)])
  (define who 'list*->device-csr-matrix)
  (define extents (matrix-shape who rows))
  (define convert (element-converter who element-type))
  (define entries
    (over-elements (for/list ([row rows])
                     (filter (lambda (entry) (not (= (cdr entry) 0)))
                             (over-elements (for/list ([x row]
                                                       [j (in-naturals)])
                                              (cons j (convert x))))))))
  (build-csr who
             resources
             element-type
             index-type
             extents
             (map length entries)
             (map car (append* entries))
             (map cdr (append* entries))))

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

(define (triplets->device-csr-matrix rows
                                     cols
                                     vals
                                     #:shape extents
                                     #:dtype [element-type 'float64]
                                     #:index-dtype [index-type 'int32]
                                     #:resources [resources (current-device-resources)])
  (define who 'triplets->device-csr-matrix)
  (match-define (list row-count col-count) extents)
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
  (define entries
    (summed (adder element-type)
            (sort triplets
                  (lambda (a b)
                    (or (< (vector-ref a 0) (vector-ref b 0))
                        (and (= (vector-ref a 0) (vector-ref b 0))
                             (< (vector-ref a 1) (vector-ref b 1))))))))
  (define counts (make-vector row-count 0))
  (for ([entry (in-list entries)])
    (define r (vector-ref entry 0))
    (vector-set! counts r (add1 (vector-ref counts r))))
  (build-csr who
             resources
             element-type
             index-type
             extents
             (vector->list counts)
             (map (lambda (entry) (vector-ref entry 1)) entries)
             (map (lambda (entry) (vector-ref entry 2)) entries)))

(define (read-vector who v)
  (match-define (list n) (device-array-shape v))
  (unpack-vector (device-array-dtype v) n (read-all who v)))

(define (storage who m)
  (values (read-vector who (device-csr-matrix-indptr m))
          (read-vector who (device-csr-matrix-indices m))
          (read-vector who (device-csr-matrix-data m))))

(define (expanded-rows indptr)
  (append* (for/list ([start (in-list indptr)]
                      [end (in-list (cdr indptr))]
                      [r (in-naturals)])
             (make-list (- end start) r))))

(define (device-csr-matrix->triplets m)
  (define-values (indptr indices data) (storage 'device-csr-matrix->triplets m))
  (values (expanded-rows indptr) indices data))

(define (device-csr-matrix->list* m)
  (define-values (indptr indices data) (storage 'device-csr-matrix->list* m))
  (match-define (list rows cols) (device-csr-matrix-shape m))
  (define add (adder (device-array-dtype (device-csr-matrix-data m))))
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
  (define dtype (device-array-dtype v))
  ((host-getter dtype) (read-array who v (host-memory (dtype-itemsize dtype)) k) 0))

(define (row-of who indptr k from rows)
  (let search ([lo from]
               [hi (sub1 rows)])
    (cond
      [(>= lo hi) lo]
      [else
       (define mid (quotient (+ lo hi 1) 2))
       (if (<= (element-at who indptr mid) k)
           (search mid hi)
           (search lo (sub1 mid)))])))

(define (block who v start count)
  (define dtype (device-array-dtype v))
  (define host (read-array who v (host-memory (* count (dtype-itemsize dtype))) start))
  (unpack-vector dtype count host))

(define (run-entries who m rows run from)
  (match-define (cons start count) run)
  (for/fold ([entries '()]
             [row from]
             #:result (values (reverse entries) row))
            ([k (in-naturals start)]
             [c (in-list (block who (device-csr-matrix-indices m) start count))]
             [x (in-list (block who (device-csr-matrix-data m) start count))])
    (define r (row-of who (device-csr-matrix-indptr m) k row rows))
    (values (cons (list r c x) entries) r)))

(define (shown-entries who m)
  (match-define (list rows _) (device-csr-matrix-shape m))
  (match (csr-runs (nnz m))
    [(list run)
     (define-values (entries _) (run-entries who m rows run 0))
     entries]
    [(list head tail)
     (define-values (first-entries row) (run-entries who m rows head 0))
     (define-values (last-entries _) (run-entries who m rows tail row))
     (append first-entries '(...) last-entries)]))

(define (entries-text m)
  (define parts
    (list (device-csr-matrix-indptr m) (device-csr-matrix-indices m) (device-csr-matrix-data m)))
  (cond
    [(ormap (lambda (part) (released? (array-buffer-handle part))) parts) " <released>"]
    [(zero? (nnz m)) ""]
    [else
     (with-handlers ([exn:fail:raft? (lambda (e)
                                       (format " <values unavailable: ~a>" (exn-message e)))])
       (define text
         (csr-text (device-array-dtype (device-csr-matrix-data m))
                   (shown-entries 'device-csr-matrix m)))
       (string-append "\n " (string-replace text "\n" "\n ")))]))

(define (csr->string m)
  (define indptr (device-csr-matrix-indptr m))
  (format "#<device-csr-matrix ~a ~a nnz=~a index=~a cuda:~a~a>"
          (device-array-dtype (device-csr-matrix-data m))
          (shape-text (device-csr-matrix-shape m))
          (nnz m)
          (device-array-dtype indptr)
          (array-device indptr)
          (entries-text m)))
