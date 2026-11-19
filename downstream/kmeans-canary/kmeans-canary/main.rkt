#lang racket/base

(require (only-in racket/match match-define)
         (only-in raft
                  csr-data
                  csr-indices
                  csr-indptr
                  current-device-resources
                  device-csr-matrix
                  device-matrix
                  device-matrix->list*
                  device-matrix?
                  device-vector
                  dtype
                  list*->device-matrix
                  shape)
         (only-in raft/unsafe deposit deposit->device-csr-matrix deposit->list dtype->code)
         (only-in "private/native.rkt"
                  kc-assignment-graph-job
                  kc-cluster-graph-job
                  kc-cluster-members-job
                  kc-csr-copy-job
                  kc-fit-job
                  kc-make-blobs-job
                  kc-predict-job))

(provide assignment-graph
         blobs
         cluster-graph
         cluster-members
         csr-copy
         kmeans-fit
         kmeans-predict)

(define init-codes
  (hasheq 'k-means++ 0 'scalable-k-means++ 0 (string->symbol "k-means||") 0 'random 1))
(define array-init 2)

(define (blobs n-samples
               n-features
               #:centers [centers 3]
               #:cluster-std [cluster-std 1.0]
               #:center-box [center-box '(-10.0 10.0)]
               #:shuffle? [shuffle? #t]
               #:seed [seed 0]
               #:dtype [element-type 'float32]
               #:layout [order 'row-major]
               #:resources [resources (current-device-resources)])
  (define X
    (device-matrix n-samples n-features #:dtype element-type #:layout order #:resources resources))
  (define labels (device-vector n-samples #:dtype 'int32 #:resources resources))
  (match-define (list low high) center-box)
  (kc-make-blobs-job 'blobs
                     resources
                     X
                     labels
                     centers
                     (exact->inexact cluster-std)
                     (if shuffle? 1 0)
                     (exact->inexact low)
                     (exact->inexact high)
                     seed)
  (values X labels))

(define (initial-centroids X init n-clusters resources)
  (match-define (list _ n-features) (shape X))
  (if (device-matrix? init)
      (list*->device-matrix (device-matrix->list* init) #:dtype (dtype X) #:resources resources)
      (device-matrix n-clusters n-features #:dtype (dtype X) #:resources resources)))

(define (kmeans-fit X
                    #:n-clusters [n-clusters 8]
                    #:init (init 'scalable-k-means++)
                    #:max-iter [max-iter 300]
                    #:tol [tol 1e-4]
                    #:n-init [n-init 'auto]
                    #:oversampling-factor [oversampling-factor 2.0]
                    #:seed [seed 0]
                    #:sample-weight [sample-weight #f]
                    #:resources [resources (current-device-resources)])
  (define centroids (initial-centroids X init n-clusters resources))
  (define code
    (if (device-matrix? init)
        array-init
        (hash-ref init-codes init -1)))
  (define runs
    (cond
      [(not (eq? n-init 'auto)) n-init]
      [(eqv? code 0) 1]
      [else 10]))
  (define factor
    (if (eq? init 'k-means++)
        0.0
        (exact->inexact oversampling-factor)))
  (define-values (inertia n-iter)
    (kc-fit-job 'kmeans-fit
                resources
                X
                sample-weight
                centroids
                code
                max-iter
                (exact->inexact tol)
                runs
                factor
                seed))
  (values centroids inertia n-iter))

(define (kmeans-predict centroids
                        X
                        #:sample-weight [sample-weight #f]
                        #:normalize-weights? [normalize? #t]
                        #:resources [resources (current-device-resources)])
  (match-define (list n-samples _) (shape X))
  (define labels (device-vector n-samples #:dtype 'int32 #:resources resources))
  (define inertia
    (kc-predict-job 'kmeans-predict resources centroids X sample-weight (if normalize? 1 0) labels))
  (values labels inertia))

(define (cluster-members X labels cluster #:resources [resources (current-device-resources)])
  (define members (deposit #:resources resources))
  (kc-cluster-members-job 'cluster-members resources X labels cluster members)
  (apply values (deposit->list members)))

(define (cluster-graph labels
                       n-clusters
                       #:index-dtype [index-type 'int32]
                       #:resources [resources (current-device-resources)])
  (match-define (list n) (shape labels))
  (define graph (deposit #:resources resources))
  (kc-cluster-graph-job 'cluster-graph resources labels n-clusters (dtype->code index-type) graph)
  (deposit->device-csr-matrix graph #:shape (list n-clusters n)))

(define (assignment-graph labels
                          n-clusters
                          #:index-dtype [index-type 'int32]
                          #:resources [resources (current-device-resources)])
  (match-define (list n) (shape labels))
  (define (output count element-type)
    (device-vector count #:dtype element-type #:resources resources))
  (define indptr (output (add1 n) index-type))
  (define indices (output n index-type))
  (define data (output n 'float32))
  (kc-assignment-graph-job 'assignment-graph resources labels n-clusters indptr indices data)
  (device-csr-matrix indptr indices data #:shape (list n n-clusters)))

(define (csr-copy m #:resources [resources (current-device-resources)])
  (match-define (list _ cols) (shape m))
  (define copied (deposit #:resources resources))
  (kc-csr-copy-job 'csr-copy resources (csr-indptr m) (csr-indices m) (csr-data m) cols copied)
  (deposit->device-csr-matrix copied #:shape (shape m)))
