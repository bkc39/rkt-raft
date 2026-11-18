#lang racket/base

(require (only-in racket/list append* make-list)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path
         (only-in rackunit check-equal?)
         (only-in raft
                  csr-data
                  csr-indices
                  csr-indptr
                  current-device-resources
                  device-csr-matrix->list*
                  device-vector->list
                  dtype
                  list->device-vector
                  shape)
         (only-in raft/private/array release-array!)
         (only-in raft/tests/private/gpu test-gpu)
         (only-in raft/tests/private/python-env run-twin test-twin)
         (only-in raft/tests/private/raft-error check-raft-error)
         (only-in raft/unsafe deposit)
         (only-in "../main.rkt" cluster-graph csr-copy)
         (only-in "../private/native.rkt" kc-csr-copy-job))

(define-runtime-path twin "python/kmeans_twin.py")

(define labels-list '(2 0 1 0 2 2 0 1 2))
(define k 4)

(define (parts g)
  (map device-vector->list (list (csr-indptr g) (csr-indices g) (csr-data g))))

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
          (cons (+ (length row) (car sums)) sums))
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
    (for-each release-array! (list (csr-indptr g) (csr-indices g) (csr-data g)))
    (check-equal? (parts copied) expected (format "~a after the original's release" index-type))
    (check-equal? (device-csr-matrix->list* copied) (device-csr-matrix->list* (csr-copy copied)))))

(test-gpu "law 20: a float32 indptr is refused by the canary's own dispatch"
  (define g (graph-of 'int32))
  (check-raft-error 'logic
                    "csr-copy: indptr: expected int32 or int64, got float32"
                    (lambda ()
                      (kc-csr-copy-job 'csr-copy
                                       (current-device-resources)
                                       (list->device-vector '(0.0 2.0 3.0 7.0 9.0) #:dtype 'float32)
                                       (csr-indices g)
                                       (csr-data g)
                                       (length labels-list)
                                       (deposit)))))

(test-twin "law 20: cluster-graph agrees with SciPy's csr_matrix((ones, (labels, arange(n))))"
  (define results
    (hash-ref (run-twin twin (hasheq 'cases (list (hasheq 'op "graph" 'labels labels-list 'k k))))
              'results))
  (for ([index-type (in-list '(int32 int64))])
    (check-equal? (parts (graph-of index-type))
                  (map (lambda (key) (hash-ref (car results) key)) '(indptr indices data))
                  (symbol->string index-type))))
