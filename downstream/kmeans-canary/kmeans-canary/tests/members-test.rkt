#lang racket/base

(require (only-in racket/list append-map range)
         (only-in rackunit check-equal? check-true)
         (only-in raft
                  current-device-resources
                  device-matrix->list*
                  device-resources
                  device-vector->list
                  dtype
                  layout
                  shape)
         (only-in raft/private/foreign/memory owner-release-count)
         (only-in raft/tests/private/collect drain-finalizers!)
         (only-in raft/tests/private/gpu test-gpu)
         (only-in raft/tests/private/raft-error check-raft-error)
         (only-in raft/unsafe deposit)
         (only-in "../main.rkt" blobs cluster-members kmeans-fit kmeans-predict)
         (only-in "../private/native.rkt" deposit-members! kc-owner-drop-count))

(define k 3)

(define (labelled element-type)
  (define-values (X _truth) (blobs 300 2 #:centers k #:cluster-std 0.5 #:seed 5 #:dtype element-type))
  (define-values (centroids _inertia _n-iter) (kmeans-fit X #:n-clusters k #:seed 1))
  (define-values (labels _score) (kmeans-predict centroids X))
  (values X labels centroids))

(define (host-members X labels c)
  (for/fold ([indices '()]
             [rows '()]
             #:result (values (reverse indices) (reverse rows)))
            ([l (in-list (device-vector->list labels))]
             [row (in-list (device-matrix->list* X))]
             [i (in-naturals)]
             #:when (= l c))
    (values (cons i indices) (cons row rows))))

(test-gpu "law 13: cluster-members gives each cluster's indices and rows, and nothing for k"
  (for ([element-type (in-list '(float32 float64))])
    (define-values (X labels _centroids) (labelled element-type))
    (for ([c (in-range (add1 k))])
      (define label (format "~a cluster ~a" element-type c))
      (define-values (indices rows) (cluster-members X labels c))
      (define-values (expected-indices expected-rows) (host-members X labels c))
      (check-equal? (dtype indices) 'int64 label)
      (check-equal? (dtype rows) element-type label)
      (check-equal? (layout rows) 'row-major label)
      (check-equal? (device-vector->list indices) expected-indices label)
      (check-equal? (device-matrix->list* rows) expected-rows label)
      (when (= c k)
        (check-equal? (list (shape indices) (shape rows)) '((0) (0 2)) label)))))

(test-gpu "law 14: the members of all clusters partition the samples"
  (define-values (X labels _centroids) (labelled 'float32))
  (define all
    (append-map (lambda (c)
                  (define-values (indices _rows) (cluster-members X labels c))
                  (device-vector->list indices))
                (range k)))
  (check-equal? (sort all <) (range 300)))

(test-gpu "law 15: kmeans-predict on a cluster's adopted rows labels every row with it"
  (define-values (X labels centroids) (labelled 'float64))
  (for ([c (in-range k)])
    (define-values (_indices rows) (cluster-members X labels c))
    (define-values (predicted _score) (kmeans-predict centroids rows))
    (check-true (andmap (lambda (l) (= l c)) (device-vector->list predicted))
                (format "cluster ~a" c))))

(test-gpu "law 16: a deposit on other resources is refused and its owner dropped by the canary"
  (define-values (X labels _centroids) (labelled 'float32))
  (define elsewhere (deposit #:resources (device-resources)))
  (drain-finalizers!)
  (define drops (kc-owner-drop-count))
  (define releases (owner-release-count))
  (check-raft-error 'logic
                    "cluster-members: out: on resources other than the call's"
                    (lambda ()
                      (deposit-members! elsewhere X labels 0 #:resources (current-device-resources))))
  (check-equal? (- (kc-owner-drop-count) drops) 1)
  (drain-finalizers!)
  (check-equal? (- (owner-release-count) releases) 0))
