#lang racket/base

(require (only-in racket/port with-output-to-string)
         (only-in racket/system system*)
         (only-in rackunit check-equal? check-regexp-match check-true)
         (only-in raft current-device-resources device-matrix shape)
         (only-in raft/tests/private/collect drain-finalizers!)
         (only-in raft/tests/private/probe test-pools)
         (only-in "../main.rkt" blobs kmeans-fit)
         (only-in "../pool.rkt" canary-current-is-async? canary-pool-bytes canary-pool-reset-high!)
         (only-in "../private/native.rkt" canary-path))

(define (pool-used)
  (define-values (used _high _reserved) (canary-pool-bytes))
  used)

(test-pools "the canary sees the async pool raft installed as the current resource"
  (current-device-resources)
  (check-true (canary-current-is-async?)))

(test-pools "an array raft allocates shows in the pool the canary sees"
  (define before (pool-used))
  (define m (device-matrix 512 512))
  (check-true (>= (- (pool-used) before) (* 512 512 4)))
  (check-equal? (list (and m #t)) '(#t)))

(test-pools "cuML allocates its workspace from the pool raft installed"
  (define-values (X truth) (blobs 5000 16 #:centers 6 #:seed 4))
  (drain-finalizers!)
  (define before (pool-used))
  (canary-pool-reset-high!)
  (define-values (centroids _inertia _n-iter) (kmeans-fit X #:n-clusters 6 #:seed 4))
  (define-values (used high _reserved) (canary-pool-bytes))
  (printf
   "pool: ~a bytes in use before the fit, ~a after it (plus the centroids), peak ~a during it\n"
   before
   used
   high)
  (check-true (> high (+ before (* 6 16 4))) "the fit's own allocations reached the pool")
  (check-equal? used (+ before (* 6 16 4)) "and were returned to it, leaving only the centroids")
  (check-equal? (map shape (list centroids truth)) '((6 16) (5000))))

(define (unique-registry-symbols library)
  (define readelf (find-executable-path "readelf"))
  (define listing
    (with-output-to-string (lambda () (system* readelf "--dyn-syms" "-W" (path->string library)))))
  (regexp-match* #rx"UNIQUE +DEFAULT +[0-9]+ +(_ZZN3rmm[^ \n]*get_ref_map[^ \n]*)"
                 listing
                 #:match-select cadr))

(test-pools "the canary and libcuml export RMM's registry as GNU unique symbols"
  (define cuml (build-path (getenv "RAFT_RAPIDS_PREFIX") "lib" "libcuml.so"))
  (for ([library (list (string->path canary-path) cuml)])
    (define symbols (unique-registry-symbols library))
    (check-true (pair? symbols) (format "~a" library))
    (for ([s (in-list symbols)])
      (check-regexp-match #rx"device_id_to_resource$" s))))
