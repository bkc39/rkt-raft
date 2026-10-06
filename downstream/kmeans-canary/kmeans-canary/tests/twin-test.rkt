#lang racket/base

(require (only-in racket/list first)
         (only-in racket/match match-define)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path
         (only-in rackunit check-equal? check-true)
         (only-in raft device-matrix->list* device-vector->list list*->device-matrix)
         (only-in raft/tests/private/python-env close? run-twin test-twin)
         (only-in "../main.rkt" blobs kmeans-fit kmeans-predict))

(define-runtime-path twin "python/kmeans_twin.py")

(define tolerance 1e-4)

(struct fitted (spec X truth centroids fit-inertia labels inertia))

(define (run-case spec)
  (match-define (list samples features k dtype init seed) spec)
  (define-values (X truth)
    (blobs samples features #:centers k #:cluster-std 0.6 #:seed (+ seed 100) #:dtype dtype))
  (define start
    (and (eq? init 'array)
         (list*->device-matrix (for/list ([row (in-list (device-matrix->list* X))]
                                          [_ (in-range k)])
                                 row)
                               #:dtype dtype)))
  (define-values (centroids fit-inertia _n-iter)
    (kmeans-fit X #:n-clusters k #:init (or start init) #:seed seed))
  (define-values (labels inertia) (kmeans-predict centroids X))
  (fitted spec X truth centroids fit-inertia labels inertia))

(define (twin-case f)
  (match-define (list _ _ k dtype init seed) (fitted-spec f))
  (hasheq 'X (device-matrix->list* (fitted-X f))
          'dtype (symbol->string dtype)
          'n_clusters k
          'init (if (eq? init 'array)
                    (for/list ([row (in-list (device-matrix->list* (fitted-X f)))]
                               [_ (in-range k)])
                      row)
                    (symbol->string init))
          'seed seed
          'n_init "auto"
          'max_iter 300
          'tol 1e-4
          'labels (device-vector->list (fitted-labels f))
          'truth (device-vector->list (fitted-truth f))))

(define specs
  '((300 2 3 float32 k-means++ 1) (500 5 4 float32 scalable-k-means++ 2)
                                  (400 3 5 float32 random 3)
                                  (300 4 3 float32 array 4)
                                  (300 2 3 float64 k-means++ 5)
                                  (500 8 6 float64 scalable-k-means++ 6)
                                  (1000 16 8 float32 k-means++ 7)
                                  (250 3 2 float64 random 8)))

(define (largest-difference ours theirs)
  (for*/fold ([worst 0.0])
             ([row (in-list (map list ours theirs))]
              [a+b (in-list (map cons (car row) (cadr row)))])
    (max worst (/ (abs (- (car a+b) (cdr a+b))) (max 1.0 (abs (cdr a+b)))))))

(test-twin "the canary agrees with cuml.cluster.KMeans on the same data, init and seed"
  (define fits (map run-case specs))
  (define results (hash-ref (run-twin twin (hasheq 'cases (map twin-case fits))) 'results))
  (for ([f (in-list fits)]
        [twin (in-list results)])
    (define spec (format "~a" (fitted-spec f)))
    (define ours (device-matrix->list* (fitted-centroids f)))
    (define theirs (hash-ref twin 'centroids))
    (define worst (largest-difference ours theirs))
    (printf "twin ~a: ARI ~a (truth ~a, sklearn ~a); inertia ~a against ~a; centroids within ~a\n"
            spec
            (hash-ref twin 'ari)
            (hash-ref twin 'ari_truth)
            (hash-ref twin 'ari_sklearn)
            (fitted-inertia f)
            (hash-ref twin 'inertia)
            worst)
    (check-equal? (hash-ref twin 'ari) 1.0 spec)
    (check-true (close? (fitted-inertia f) (hash-ref twin 'inertia) tolerance) spec)
    (check-true (close? (fitted-fit-inertia f) (hash-ref twin 'inertia) tolerance) spec)
    (check-true (<= worst tolerance) spec)
    (check-equal? (length (filter values theirs)) (length ours) spec))
  (check-equal? (hash-ref (first results) 'version) "26.08.00"))
