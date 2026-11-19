#lang racket/base

(require (only-in racket/file find-files)
         (only-in racket/list append* append-map make-list range)
         (only-in racket/match match match-define)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path
         (only-in racket/set subset?)
         (only-in rackunit check-equal? check-true test-case)
         (only-in raft
                  csr-data
                  csr-indices
                  csr-indptr
                  current-device-resources
                  device-csr-matrix->list*
                  dtype
                  list->device-vector
                  shape)
         (only-in raft/tests/private/csr parts triplets)
         (only-in raft/tests/private/gpu test-gpu)
         (only-in raft/tests/private/python-env run-twin test-twin)
         (only-in raft/tests/private/raft-error check-raft-error)
         (only-in raft/unsafe deposit device-array-release!)
         (only-in "../main.rkt" assignment-graph cluster-graph csr-copy)
         (only-in "../private/native.rkt" kc-csr-copy-job))

(define-runtime-path twin "python/kmeans_twin.py")
(define-runtime-path package "..")

(define labels-list '(2 0 1 0 2 2 0 1 2))
(define k 4)

(define (host-graph labels clusters)
  (define rows
    (for/list ([c (in-range clusters)])
      (for/list ([l (in-list labels)]
                 [i (in-naturals)]
                 #:when (= l c))
        i)))
  (list (for/fold ([sums '(0)]
                   #:result (reverse sums))
                  ([row (in-list rows)])
          (match-define (cons total _) sums)
          (cons (+ (length row) total) sums))
        (append* rows)
        (make-list (length labels) 1.0)))

(define (graph-of index-type)
  (cluster-graph (list->device-vector labels-list #:dtype 'int32) k #:index-dtype index-type))

(test-gpu "law 20: cluster-graph is the k×n membership matrix, rows ascending, in int32 and int64"
  (for ([index-type (in-list '(int32 int64))])
    (define g (graph-of index-type))
    (define label (symbol->string index-type))
    (check-equal? (parts g) (host-graph labels-list k) label)
    (check-equal? (list (shape g) (dtype g) (dtype (csr-indices g)) (dtype (csr-indptr g)))
                  (list (list k (length labels-list)) 'float32 index-type index-type)
                  label)))

(test-gpu "law 20: csr-copy has equal parts on buffers of its own"
  (for ([index-type (in-list '(int32 int64))])
    (define g (graph-of index-type))
    (define copied (csr-copy g))
    (define expected (parts g))
    (check-equal? (parts copied) expected)
    (check-equal? (shape copied) (shape g))
    (for-each device-array-release! (list (csr-indptr g) (csr-indices g) (csr-data g)))
    (check-equal? (parts copied) expected (format "~a after the original's release" index-type))
    (check-equal? (device-csr-matrix->list* copied) (device-csr-matrix->list* (csr-copy copied)))))

(define copy-refusals
  '(("indptr: expected int32 or int64, got float32" (0.0 2.0 3.0) float32 (0 1 1) (1.0 1.0 1.0) 2)
    ("indptr: ends at 6, expected 1, the length of indices" (0 6) int32 (1) (5.0) 2)))

(test-gpu "law 20: csr-copy refuses parts it cannot copy, under its own name"
  (for ([row (in-list copy-refusals)])
    (match-define (list message indptr indptr-type indices data cols) row)
    (check-raft-error 'logic
                      (format "csr-copy: ~a" message)
                      (lambda ()
                        (kc-csr-copy-job 'csr-copy
                                         (current-device-resources)
                                         (list->device-vector indptr #:dtype indptr-type)
                                         (list->device-vector indices #:dtype 'int32)
                                         (list->device-vector data #:dtype 'float32)
                                         cols
                                         (deposit))))))

(define graph-cases
  '(("labels: entry 2 is 2, outside [0, 2)" (0 1 2) 2 int32)
    ("labels: entry 1 is -1, outside [0, 2)" (0 -1 1) 2 int64)
    (((0 0) ((0) () ())) () 0 int32)
    ("rows: negative extent -1" () -1 int32)
    ("indptr: expected int32 or int64, got float32" (0 1) 2 float32)))

(test-gpu "law 20: cluster-graph refuses a label outside its clusters, negative clusters and float indices"
  (for ([c (in-list graph-cases)])
    (match-define (list expected labels clusters index-type) c)
    (define (graph)
      (cluster-graph (list->device-vector labels #:dtype 'int32) clusters #:index-dtype index-type))
    (match expected
      [(? string? message) (check-raft-error 'logic (format "cluster-graph: ~a" message) graph)]
      [_
       (define g (graph))
       (check-equal? (list (shape g) (parts g)) expected (format "~a" c))])))

(test-gpu "law 20: assignment-graph fills three caller-allocated views, one entry a row, as kNN does"
  (for ([index-type (in-list '(int32 int64))])
    (define g
      (assignment-graph (list->device-vector labels-list #:dtype 'int32) k #:index-dtype index-type))
    (match-define (list rows cols vals) (triplets (graph-of index-type)))
    (define label (symbol->string index-type))
    (define n (length labels-list))
    (check-equal? (parts g) (list (range (add1 n)) labels-list (make-list n 1.0)) label)
    (check-equal? (list (shape g) (dtype (csr-indptr g))) (list (list n k) index-type) label)
    (check-equal? (triplets g) (apply map list (sort (map list cols rows vals) < #:key car)) label))
  (check-raft-error 'logic
                    "assignment-graph: labels: entry 0 is 4, outside [0, 4)"
                    (lambda () (assignment-graph (list->device-vector '(4) #:dtype 'int32) k))))

(test-twin "law 20: cluster-graph agrees with SciPy's csr_matrix((ones, (labels, arange(n))))"
  (match-define (list result)
    (hash-ref (run-twin twin (hasheq 'cases (list (hasheq 'op "graph" 'labels labels-list 'k k))))
              'results))
  (for ([index-type (in-list '(int32 int64))])
    (check-equal? (parts (graph-of index-type))
                  (map (lambda (key) (hash-ref result key)) '(indptr indices data))
                  (symbol->string index-type))))

(define counters
  (hasheq 'raft/private/foreign/memory '(buffer-drop-count owner-release-count release-failure-count)
          'raft/private/job '(executor-threads jobs-in-flight jobs-live)))

(define (private? spec)
  (regexp-match? #rx"^raft/private/" (format "~a" spec)))

(define (private-requires spec)
  (match spec
    [(list* 'only-in (? private? module) names) (list (cons module names))]
    [(? private? module) (list (list module))]
    [(list* _ specs) (append-map private-requires specs)]
    [_ '()]))

(define (module-forms path)
  (match (with-input-from-file path
                               (lambda ()
                                 (parameterize ([read-accept-reader #t])
                                   (read))))
    [(list 'module _ _ (list* '#%module-begin forms)) forms]
    [_ '()]))

(define (requires form)
  (match form
    [(list* 'require specs) (append-map private-requires specs)]
    [_ '()]))

(define (allowed? spec)
  (match spec
    [(list* module (? pair? names)) (subset? names (hash-ref counters module '()))]
    [_ #f]))

(test-case "C2: no canary module requires raft/private beyond the test-only counters"
  (for* ([path (in-list (find-files (lambda (p) (regexp-match? #rx"[.]rkt$" p)) package))]
         [spec (in-list (append-map requires (module-forms path)))])
    (check-true (allowed? spec) (format "~a requires ~a" path spec))))
