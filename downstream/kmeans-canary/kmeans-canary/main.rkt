#lang racket/base

(require (only-in racket/match match-define)
         (only-in raft
                  current-device-resources
                  device-matrix
                  device-matrix->list*
                  device-matrix?
                  device-vector
                  dtype
                  list*->device-matrix
                  shape)
         (only-in raft/unsafe resources->handle-pointer with-array-views)
         (only-in "private/native.rkt" call/kc kc-fit kc-make-blobs kc-predict))

(provide blobs
         kmeans-fit
         kmeans-predict)

(define init-codes (hasheq 'k-means++ 0 'scalable-k-means++ 0 'random 1))
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
  (define handle (resources->handle-pointer resources))
  (match-define (list low high) center-box)
  (with-array-views ([x X] [y labels])
    (call/kc 'blobs
             (lambda ()
               (kc-make-blobs handle
                              x
                              y
                              centers
                              (exact->inexact cluster-std)
                              (if shuffle? 1 0)
                              (exact->inexact low)
                              (exact->inexact high)
                              seed))))
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
  (define handle (resources->handle-pointer resources))
  (define-values (inertia n-iter)
    (with-array-views ([x X] [w sample-weight] [c centroids])
      (call/kc 'kmeans-fit
               (lambda ()
                 (kc-fit handle x w c code max-iter (exact->inexact tol) runs factor seed)))))
  (values centroids inertia n-iter))

(define (kmeans-predict centroids
                        X
                        #:sample-weight [sample-weight #f]
                        #:normalize-weights? [normalize? #t]
                        #:resources [resources (current-device-resources)])
  (match-define (list n-samples _) (shape X))
  (define labels (device-vector n-samples #:dtype 'int32 #:resources resources))
  (define handle (resources->handle-pointer resources))
  (define inertia
    (with-array-views ([c centroids] [x X] [w sample-weight] [y labels])
      (call/kc 'kmeans-predict (lambda () (kc-predict handle c x w (if normalize? 1 0) y)))))
  (values labels inertia))
