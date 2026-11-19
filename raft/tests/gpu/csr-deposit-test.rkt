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
                  device-csr-matrix->triplets
                  device-vector->list
                  dtype
                  nnz
                  shape)
         (only-in "../../private/deposit.rkt" deposit-handle)
         (only-in "../../private/dtype.rkt" dtype->code)
         (only-in "../../unsafe.rkt"
                  deposit
                  deposit->device-csr-matrix
                  deposit->list
                  deposit-release!
                  device-array-release!
                  with-deposits)
         (only-in "../private/collect.rkt" drain-finalizers!)
         (only-in "../private/csr.rkt" parts)
         (only-in "../private/deposits.rkt"
                  counters
                  counts
                  csr-filled
                  fill-csr!
                  fill-csr-job!
                  filled
                  released-once
                  settles-to)
         (only-in "../private/probe.rkt" probe-flags probe-refuse-adoption! test-probe)
         (only-in "../private/raft-error.rkt" check-raft-error))

(define cases
  '(((0 2 2 3) (3 0 1) (0.5 1.0 2.0) (3 4)) ((0 3 3 5) (2 0 2 1 1) (1.5 -2.25 0.0 4.0 -4.0) (3 3))
                                            ((0 0 0) () () (2 5))
                                            ((0) () () (0 7))))

(define (check-adopts fill label)
  (for* ([index-type (in-list '(int32 int64))]
         [element-type (in-list '(float32 float64))]
         [two-phase? (in-list '(#f #t))]
         [c (in-list cases)])
    (match-define (list indptr indices data extents) c)
    (define where (format "~a ~a ~a ~a ~a" label index-type element-type two-phase? indptr))
    (define d
      (csr-filled indptr
                  indices
                  data
                  #:fill fill
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
  (check-adopts fill-csr! "call"))

(test-probe "law 14: the same holds through the probe's job twin"
  (check-adopts fill-csr-job! "job"))

(test-probe "law 15: a malformed deposit is refused at adoption, and its arrays stay readable"
  (define d (csr-filled '(0 2 1 3) '(0 1 2) '(1.0 2.0 3.0)))
  (check-raft-error 'logic
                    "deposit->device-csr-matrix: indptr: entry 2 (1) is less than entry 1 (2)"
                    (lambda () (deposit->device-csr-matrix d #:shape '(3 4))))
  (check-equal? (map device-vector->list (deposit->list d)) '((0 2 1 3) (0 1 2) (1.0 2.0 3.0))))

(define ((adopted-as-csr d [extents '(2 3)]))
  (deposit->device-csr-matrix d #:shape extents))

(define (refusing-region-1 d)
  (probe-refuse-adoption! (deposit-handle d) 1)
  d)

(define (closed-unfilled)
  (define d (deposit))
  (with-deposits ([out d]) out)
  d)

(test-probe "law 15: a deposit that is not a CSR matrix's three vectors is refused under the caller's name"
  (define short-indptr (csr-filled '(0 1 3) '(0 1 2) '(1.0 2.0 3.0)))
  (for ([row (in-list
              (list (list "the deposit holds 2 regions; a CSR matrix needs 3"
                          (adopted-as-csr (filled 'float32 3 #f)))
                    (list "the deposit holds 1 region; a CSR matrix needs 3"
                          (adopted-as-csr (filled 'float32 3 #f #:count 1)))
                    (list "the deposit holds 0 regions; a CSR matrix needs 3"
                          (adopted-as-csr (closed-unfilled)))
                    (list "the deposit is still open"
                          (lambda ()
                            (define d (deposit))
                            (with-deposits ([out d]) ((adopted-as-csr d)))))
                    (list "region 1: refused by the probe"
                          (adopted-as-csr
                           (refusing-region-1 (csr-filled '(0 2 2 3) '(3 0 1) '(0.5 1.0 2.0)))
                           '(3 4)))
                    (list "region 0: not aligned to its element size"
                          (adopted-as-csr (filled 'float32 3 4 #:flags (probe-flags 'raw 'misalign))))
                    (list "indptr: expected 4 elements, got 3"
                          (adopted-as-csr short-indptr '(3 4)))))])
    (match-define (list message thunk) row)
    (check-raft-error 'logic (format "deposit->device-csr-matrix: ~a" message) thunk))
  (check-equal? (device-csr-matrix->list* ((adopted-as-csr short-indptr)))
                '((1.0 0.0 0.0) (0.0 2.0 3.0))))

(test-probe "law 15: deposit_csr refuses an empty indptr before it claims the record, dropping its owner"
  (drain-finalizers!)
  (define before (counters))
  (define d (deposit))
  (check-raft-error 'logic
                    "probe-deposit-csr: out: indptr: expected at least 1 element, got 0"
                    (lambda ()
                      (fill-csr! (current-device-resources)
                                 d
                                 (dtype->code 'int32)
                                 (dtype->code 'float64)
                                 '()
                                 '()
                                 '()
                                 0)))
  (check-equal? (settles-to before (counts 0 1 0 0 0)) (counts 0 1 0 0 0))
  (check-equal? (deposit->list d) '()))

(test-probe "law 15: the two-phase recipe refuses an empty indptr in csr_buffers, before any owner"
  (drain-finalizers!)
  (define before (counters))
  (define d (deposit))
  (check-raft-error 'logic
                    "probe-deposit-csr: rows: negative extent -1"
                    (lambda ()
                      (fill-csr! (current-device-resources)
                                 d
                                 (dtype->code 'int32)
                                 (dtype->code 'float64)
                                 '()
                                 '()
                                 '()
                                 1)))
  (check-equal? (settles-to before (counts 0 0 0 0 0)) (counts 0 0 0 0 0))
  (check-equal? (deposit->list d) '()))

(define (held-csr two-phase?)
  (define m
    (deposit->device-csr-matrix
     (csr-filled '(0 2 2 3) '(3 0 1) '(0.5 1.0 2.0) #:two-phase? two-phase?)
     #:shape '(3 4)))
  (make-hasheq (list (cons 'matrix m)
                     (cons 'indptr (csr-indptr m))
                     (cons 'indices (csr-indices m))
                     (cons 'data (csr-data m)))))

(define (dropped-in order two-phase?)
  (lambda ()
    (define before (counters))
    (define h (held-csr two-phase?))
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
  (for* ([two-phase? (in-list '(#f #t))]
         [order (in-permutations '(indptr indices data))])
    (released-once (format "~a two-phase ~a" order two-phase?)
                   (dropped-in order two-phase?)
                   (counts 1 1 1 3 0))))

(define (csr-from-deposit)
  (define d (csr-filled '(0 2 2 3) '(3 0 1) '(0.5 1.0 2.0) #:dtype 'float32))
  (values d (deposit->device-csr-matrix d #:shape '(3 4))))

(test-probe "E12: a CSR outlives its released deposit, and its three parts free the owner"
  (released-once "a deposit's CSR"
                 (lambda ()
                   (define before (counters))
                   (define-values (d G) (csr-from-deposit))
                   (define triplets (device-csr-matrix->triplets G))
                   (deposit-release! d)
                   (check-equal? (device-csr-matrix->triplets G) triplets)
                   (for-each device-array-release! (list (csr-indptr G) (csr-indices G) (csr-data G)))
                   (define expected (counts 1 1 1 3 0))
                   (check-equal? (settles-to before expected) expected))
                 (counts 1 1 1 3 0))
  (define-values (_d G) (csr-from-deposit))
  (device-array-release! (csr-indices G))
  (check-raft-error 'logic
                    "device-array: used after its release"
                    (lambda () (device-csr-matrix->triplets G))))
