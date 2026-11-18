#lang racket/base

(require (only-in racket/list in-permutations)
         (only-in racket/match match-define)
         (only-in rackunit check-equal? check-true)
         (only-in "../../main.rkt"
                  csr-data
                  csr-indices
                  csr-indptr
                  current-device-resources
                  device-csr-matrix->list*
                  device-vector->list
                  dtype
                  list->device-vector
                  nnz
                  shape)
         (only-in "../../private/dtype.rkt" dtype->code)
         (only-in "../../unsafe.rkt"
                  deposit
                  deposit->device-csr-matrix
                  deposit->list
                  with-array-views
                  with-deposits)
         (only-in "../private/deposits.rkt" counters counts filled released-once settles-to)
         (only-in "../private/probe.rkt"
                  call/probe
                  probe-deposit-csr
                  probe-deposit-csr-job
                  test-probe)
         (only-in "../private/raft-error.rkt" check-raft-error))

(define (csr-filled indptr
                    indices
                    data
                    #:index-dtype [index-type 'int32]
                    #:dtype [element-type 'float64]
                    #:two-phase? [two-phase? #f])
  (define r (current-device-resources))
  (define d (deposit #:resources r))
  (with-deposits ([out d])
                 (with-array-views #:resources [h r] ()
                   (call/probe 'probe-deposit-csr
                               (lambda ()
                                 (probe-deposit-csr h
                                                    out
                                                    (dtype->code index-type)
                                                    (dtype->code element-type)
                                                    indptr
                                                    indices
                                                    (map exact->inexact data)
                                                    (if two-phase? 1 0))))))
  d)

(define (csr-job-filled indptr
                        indices
                        data
                        #:index-dtype [index-type 'int32]
                        #:dtype [element-type 'float64]
                        #:two-phase? [two-phase? #f])
  (define d (deposit))
  (probe-deposit-csr-job 'probe-deposit-csr
                         (current-device-resources)
                         d
                         (dtype->code index-type)
                         (dtype->code element-type)
                         (list->device-vector indptr #:dtype 'int64)
                         (list->device-vector indices #:dtype 'int64)
                         (list->device-vector (map exact->inexact data) #:dtype 'float64)
                         (if two-phase? 1 0))
  d)

(define cases
  '(((0 2 2 3) (3 0 1) (0.5 1.0 2.0) (3 4)) ((0 3 3 5) (2 0 2 1 1) (1.5 -2.25 0.0 4.0 -4.0) (3 3))
                                            ((0 0 0) () () (2 5))
                                            ((0) () () (0 7))))

(define (parts m)
  (map device-vector->list (list (csr-indptr m) (csr-indices m) (csr-data m))))

(define (check-adopts fill label)
  (for* ([index-type (in-list '(int32 int64))]
         [element-type (in-list '(float32 float64))]
         [two-phase? (in-list '(#f #t))]
         [c (in-list cases)])
    (match-define (list indptr indices data extents) c)
    (define where (format "~a ~a ~a ~a ~a" label index-type element-type two-phase? indptr))
    (define d
      (fill indptr
            indices
            data
            #:index-dtype index-type
            #:dtype element-type
            #:two-phase? two-phase?))
    (define m (deposit->device-csr-matrix d #:shape extents))
    (check-equal? (parts m) (list indptr indices (map exact->inexact data)) where)
    (check-equal? (list (shape m) (dtype m) (dtype (csr-indices m)) (dtype (csr-indptr m)) (nnz m))
                  (list extents element-type index-type index-type (length indices))
                  where)
    (check-true (andmap eq? (deposit->list d) (list (csr-indptr m) (csr-indices m) (csr-data m)))
                where)))

(test-probe "law 14: a probe deposit adopts as the CSR matrix it filled, for every dtype pair"
  (check-adopts csr-filled "call"))

(test-probe "law 14: the same holds through the probe's job twin"
  (check-adopts csr-job-filled "job"))

(test-probe "law 15: a malformed deposit is refused at adoption, and its arrays stay readable"
  (define d (csr-filled '(0 2 1 3) '(0 1 2) '(1.0 2.0 3.0)))
  (check-raft-error 'logic
                    "deposit->device-csr-matrix: indptr: entry 2 (1) is less than entry 1 (2)"
                    (lambda () (deposit->device-csr-matrix d #:shape '(3 4))))
  (check-equal? (map device-vector->list (deposit->list d)) '((0 2 1 3) (0 1 2) (1.0 2.0 3.0))))

(test-probe "law 15: a deposit of other than three regions, or of other rows, is refused"
  (check-raft-error 'logic
                    "deposit->device-csr-matrix: the deposit holds 2 regions; a CSR matrix needs 3"
                    (lambda () (deposit->device-csr-matrix (filled 'float32 3 #f) #:shape '(2 3))))
  (check-raft-error 'logic
                    "deposit->device-csr-matrix: the deposit holds 1 region; a CSR matrix needs 3"
                    (lambda ()
                      (deposit->device-csr-matrix (filled 'float32 3 #f #:count 1) #:shape '(2 3))))
  (define d (csr-filled '(0 1 3) '(0 1 2) '(1.0 2.0 3.0)))
  (check-raft-error 'logic
                    "deposit->device-csr-matrix: indptr: expected 4 elements, got 3"
                    (lambda () (deposit->device-csr-matrix d #:shape '(3 4))))
  (check-equal? (device-csr-matrix->list* (deposit->device-csr-matrix d #:shape '(2 3)))
                '((1.0 0.0 0.0) (0.0 2.0 3.0))))

(test-probe "law 15: deposit_csr refuses an empty indptr before it claims the record"
  (define d (deposit))
  (check-raft-error
   'logic
   "probe-deposit-csr: out: indptr: expected at least 1 element, got 0"
   (lambda ()
     (with-deposits
      ([out d])
      (with-array-views #:resources [h (current-device-resources)] ()
        (call/probe
         'probe-deposit-csr
         (lambda ()
           (probe-deposit-csr h out (dtype->code 'int32) (dtype->code 'float64) '() '() '() 0)))))))
  (check-equal? (deposit->list d) '()))

(define (held-csr)
  (define m
    (deposit->device-csr-matrix (csr-filled '(0 2 2 3) '(3 0 1) '(0.5 1.0 2.0)) #:shape '(3 4)))
  (make-hasheq (list (cons 'matrix m)
                     (cons 'indptr (csr-indptr m))
                     (cons 'indices (csr-indices m))
                     (cons 'data (csr-data m)))))

(define (dropped-in order)
  (lambda ()
    (define before (counters))
    (define h (held-csr))
    (hash-remove! h 'matrix)
    (check-equal? (settles-to before (counts 0 0 1 0 0)) (counts 0 0 1 0 0) "the matrix")
    (for ([part (in-list order)]
          [k (in-naturals 1)])
      (hash-remove! h part)
      (define expected
        (if (= k 3)
            (counts 1 1 1 3 0)
            (counts 0 0 1 k 0)))
      (check-equal? (settles-to before expected) expected (symbol->string part)))))

(test-probe "law 16: the owner is released once, after the matrix and its three parts, in any order"
  (for ([order (in-permutations '(indptr indices data))])
    (released-once (format "~a" order) (dropped-in order) (counts 1 1 1 3 0))))
