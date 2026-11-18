#lang racket/base

(require (only-in racket/match match match-define)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path
         (only-in rackunit check-equal? check-true)
         (only-in "../../main.rkt"
                  csr-data
                  csr-indices
                  csr-indptr
                  device-csr-matrix
                  device-csr-matrix->list*
                  device-csr-matrix->triplets
                  device-vector->list
                  dtype
                  exn:fail:raft?
                  list*->device-csr-matrix
                  list*->device-matrix
                  list->device-vector
                  triplets->device-csr-matrix)
         (only-in "../private/python-env.rkt" run-twin test-twin))

(define-runtime-path twin "../python/csr.py")

(define (encoded x)
  (cond
    [(list? x) (map encoded x)]
    [(and (flonum? x) (not (= x x))) "nan"]
    [else x]))

(define (decoded x)
  (cond
    [(list? x) (map decoded x)]
    [(equal? x "nan") +nan.0]
    [else x]))

(define (dense-spec rows element-type)
  (hasheq 'kind "dense"
          'dense (encoded rows)
          'shape (list (length rows)
                       (if (null? rows)
                           0
                           (length (car rows))))
          'dtype (symbol->string element-type)))

(define (triplets-spec rows cols vals extents element-type [index-type 'int32])
  (hasheq 'kind "triplets"
          'rows rows
          'cols cols
          'vals vals
          'shape extents
          'dtype (symbol->string element-type)
          'index_dtype (symbol->string index-type)))

(define (parts-spec indptr
                    indices
                    data
                    extents
                    #:dtype [element-type 'float32]
                    #:index-dtype [index-type 'int32]
                    #:indptr-dtype [indptr-type index-type])
  (hasheq 'kind "parts"
          'indptr indptr
          'indices indices
          'data data
          'shape extents
          'dtype (symbol->string element-type)
          'index_dtype (symbol->string index-type)
          'indptr_dtype (symbol->string indptr-type)))

(define (spec-dtype spec key)
  (string->symbol (hash-ref spec key)))

(define (part xs element-type)
  (if (and (pair? xs) (list? (car xs)))
      (list*->device-matrix xs #:dtype element-type)
      (list->device-vector xs #:dtype element-type)))

(define (ours spec)
  (define element-type (spec-dtype spec 'dtype))
  (match (hash-ref spec 'kind)
    ["dense" (list*->device-csr-matrix (decoded (hash-ref spec 'dense)) #:dtype element-type)]
    ["triplets"
     (triplets->device-csr-matrix (hash-ref spec 'rows)
                                  (hash-ref spec 'cols)
                                  (decoded (hash-ref spec 'vals))
                                  #:shape (hash-ref spec 'shape)
                                  #:dtype element-type
                                  #:index-dtype (spec-dtype spec 'index_dtype))]
    ["parts"
     (device-csr-matrix (part (hash-ref spec 'indptr) (spec-dtype spec 'indptr_dtype))
                        (part (hash-ref spec 'indices) (spec-dtype spec 'index_dtype))
                        (part (decoded (hash-ref spec 'data)) element-type)
                        #:shape (hash-ref spec 'shape))]))

(define G '((0 1.5 0 0) (0 0 0 0) (2 0 0 -3)))

(define fixed-cases
  `(("S1 a float32 indptr"
     ,(parts-spec '(0.0 2.0 2.0 3.0) '(3 0 1) '(0.5 1.0 2.0) '(3 4) #:indptr-dtype 'float32)
     scipy-accepts)
    ("S2 int64 indices beside an int32 indptr" ,(parts-spec '(0 2 2 3)
                                                            '(3 0 1)
                                                            '(0.5 1.0 2.0)
                                                            '(3 4)
                                                            #:index-dtype 'int64
                                                            #:indptr-dtype 'int32)
                                               scipy-accepts)
    ("S3 int32 data" ,(parts-spec '(0 2 2 3) '(3 0 1) '(1 2 3) '(3 4) #:dtype 'int32)
                     scipy-accepts
                     cupy-refuses)
    ("S4 a matrix as indptr" ,(parts-spec '((0) (2) (2) (3)) '(3 0 1) '(0.5 1.0 2.0) '(3 4)))
    ("S5 a negative extent" ,(parts-spec '(0 2 2 3) '(3 0 1) '(0.5 1.0 2.0) '(3 -1)))
    ("S6 rows beyond int32" ,(parts-spec '(0 2 2 3) '(3 0 1) '(0.5 1.0 2.0) '(3000000000 4)))
    ("S7 columns beyond int32" ,(parts-spec '(0 1) '(5) '(1.0) '(1 3000000000)) scipy-accepts)
    ("S8 a short indptr" ,(parts-spec '(0 2 3) '(3 0 1) '(0.5 1.0 2.0) '(3 4)))
    ("S9 short data" ,(parts-spec '(0 2 2 5) '(0 1 2 3 0) '(0.5 1.0 2.0 4.0) '(3 4)))
    ("K1 indptr starts at 1" ,(parts-spec '(1 2 3 3) '(0 1 2) '(0.5 1.0 2.0) '(3 4)))
    ("K2 indptr ends before the last index"
     ,(parts-spec '(0 2 2 4) '(0 1 2 3 0) '(0.5 1.0 2.0 4.0 8.0) '(3 4))
     scipy-accepts)
    ("K3 indptr decreases" ,(parts-spec '(0 3 2 3) '(0 1 2) '(0.5 1.0 2.0) '(3 4)))
    ("K4 an index past the columns" ,(parts-spec '(0 2 2 3) '(3 0 7) '(0.5 1.0 2.0) '(3 4)))
    ("K4 a negative index" ,(parts-spec '(0 2 2 3) '(-1 0 1) '(0.5 1.0 2.0) '(3 4)))
    ("law 7: no rows" ,(dense-spec '() 'float64))
    ("law 7: three empty rows" ,(dense-spec '(() () ()) 'float64))
    ("law 7: 0×4" ,(parts-spec '(0) '() '() '(0 4) #:dtype 'float64))
    ("law 7: empty first, middle and last rows"
     ,(dense-spec '((0 0 0) (1 0 2) (0 0 0) (0 3 0) (0 0 0)) 'float64))
    ("law 7: 1×3000000000, no entries" ,(triplets-spec '() '() '() '(1 3000000000) 'float64 'int64))
    ("duplicates summing to 2.5" ,(triplets-spec '(0 0 1) '(1 1 0) '(1.0 1.5 4.0) '(2 2) 'float32))
    ("duplicates summing to 0.0" ,(triplets-spec '(0 0 1) '(1 1 0) '(1.5 -1.5 4.0) '(2 2) 'float64))
    ("a kNN row in neighbour order" ,(parts-spec '(0 3) '(2 0 1) '(0.5 0.25 0.75) '(1 3)))
    ("law 6: a non-canonical CSR"
     ,(parts-spec '(0 3 3 5) '(2 0 2 1 1) '(1.5 -2.25 0.0 4.0 -4.0) '(3 3) #:dtype 'float64))
    ("float32 dyadic values" ,(dense-spec G 'float32))
    ("float32 underflow to 0 in dense rows" ,(dense-spec '((1e-50 0) (0 2.0)) 'float32))
    ("float32 underflow to 0 in a triplet" ,(triplets-spec '(0) '(0) '(1e-50) '(1 1) 'float32))
    ("int64 parts whose values fit int32"
     ,(parts-spec '(0 2 2 3) '(3 0 1) '(0.5 1.0 2.0) '(3 4) #:dtype 'float64 #:index-dtype 'int64)
     scipy-narrows)
    ("NaN kept, -0.0 dropped" ,(dense-spec '((+nan.0 -0.0) (0 2.0)) 'float64))))

(define entries (vector 0 0.0 -0.0 1.5 -2.25 3 +nan.0))

(define (generated n element-type)
  (define state (vector->pseudo-random-generator (vector 0 2 3 4 5 6)))
  (for/list ([k (in-range n)])
    (define rows (random 7 state))
    (define cols (random 7 state))
    (define D
      (for/list ([_ (in-range rows)])
        (for/list ([_ (in-range cols)])
          (vector-ref entries (random (vector-length entries) state)))))
    (list (format "generated ~a ~a" element-type k) (dense-spec D element-type))))

(define cases (append fixed-cases (generated 100 'float32) (generated 100 'float64)))

(define (attempt spec)
  (with-handlers ([exn:fail:raft? (lambda (e) (exn-message e))])
    (ours spec)))

(define (triplets m)
  (call-with-values (lambda () (device-csr-matrix->triplets m)) list))

(define (scipy-parts r)
  (list (hash-ref r 'indptr) (hash-ref r 'indices) (decoded (hash-ref r 'data))))

(define (check-agrees label m r tags)
  (check-equal? (list (device-vector->list (csr-indptr m))
                      (device-vector->list (csr-indices m))
                      (device-vector->list (csr-data m)))
                (scipy-parts r)
                label)
  (check-equal? (triplets m) (decoded (hash-ref r 'coo)) label)
  (match (hash-ref r 'dense)
    ['null (void)]
    [dense (check-equal? (device-csr-matrix->list* m) (decoded dense) label)])
  (define index-type (symbol->string (dtype (csr-indices m))))
  (if (memq 'scipy-narrows tags)
      (check-equal? (list index-type (hash-ref r 'index_dtype)) '("int64" "int32") label)
      (check-equal? index-type (hash-ref r 'index_dtype) label)))

(define (check-case name spec tags r)
  (define m (attempt spec))
  (define label
    (format "~a (ours: ~a; SciPy: ~a)" name (if (string? m) m "built") (hash-ref r 'error "built")))
  (cond
    [(memq 'scipy-accepts tags)
     (check-true (string? m) label)
     (check-true (hash-ref r 'valid) label)]
    [else
     (check-equal? (not (string? m)) (hash-ref r 'valid) label)
     (when (hash-ref r 'valid)
       (check-agrees label m r tags))])
  (when (hash-ref r 'valid)
    (define cupy (hash-ref r 'cupy))
    (if (memq 'cupy-refuses tags)
        (check-true (hash-has-key? cupy 'error) label)
        (check-equal? (list (hash-ref cupy 'indptr)
                            (hash-ref cupy 'indices)
                            (decoded (hash-ref cupy 'data))
                            (hash-ref cupy 'index_dtype))
                      (append (scipy-parts r) (list (hash-ref r 'index_dtype)))
                      (format "~a: CuPy against SciPy" name)))))

(test-twin "laws 6, 18 and 19: every case builds as SciPy and CuPy build it, or is refused as they refuse it"
  (define results (hash-ref (run-twin twin (hasheq 'cases (map cadr cases))) 'results))
  (check-equal? (length results) (length cases))
  (for ([c (in-list cases)]
        [r (in-list results)])
    (match-define (list* name spec tags) c)
    (check-case name spec tags r))
  (define departures
    (for/list ([c (in-list cases)]
               #:unless (null? (cddr c)))
      (car c)))
  (printf "twin csr: ~a cases, ~a named departures: ~a\n"
          (length cases)
          (length departures)
          departures))
