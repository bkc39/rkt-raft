#hasheq((warm-fit
         .
         (module program racket/base
           (require kmeans-canary)
           (define (long-fit X)
             (kmeans-fit X #:n-clusters 64 #:init 'random #:n-init 1 #:max-iter 100 #:tol 1e-12 #:seed 1))
           (define-values (X _) (blobs 2500000 32 #:centers 64 #:cluster-std 4.0 #:seed 1))
           (long-fit X)
           (thread (lambda () (long-fit X)))
           (sleep 0.1)
           (exit 0)))
        (cold-fit
         .
         (module program racket/base
           (require kmeans-canary)
           (define-values (X _) (blobs 2500000 32 #:centers 64 #:cluster-std 4.0 #:seed 1))
           (thread (lambda ()
                     (kmeans-fit X #:n-clusters 64 #:init 'random #:n-init 1 #:max-iter 100 #:tol 1e-12 #:seed 1)))
           (sleep 0.1)
           (exit 0)))
        (unwaited-fit
         .
         (module program racket/base
           (require kmeans-canary raft)
           (define (long-fit X)
             (kmeans-fit X #:n-clusters 64 #:init 'random #:n-init 1 #:max-iter 100 #:tol 1e-12 #:seed 1))
           (define-values (X _) (blobs 2500000 32 #:centers 64 #:cluster-std 4.0 #:seed 1))
           (long-fit X)
           (parameterize ([current-exit-wait 0])
             (thread (lambda () (long-fit X))))
           (sleep 0.1)
           (exit 3)))
        (killed-fit
         .
         (module program racket/base
           (require kmeans-canary)
           (define (long-fit X)
             (kmeans-fit X #:n-clusters 64 #:init 'random #:n-init 1 #:max-iter 100 #:tol 1e-12 #:seed 1))
           (define-values (X _) (blobs 2500000 32 #:centers 64 #:cluster-std 4.0 #:seed 1))
           (long-fit X)
           (define caller (thread (lambda () (long-fit X))))
           (sleep 0.1)
           (kill-thread caller)
           (exit 0)))
        (place-fit
         .
         (module program racket/base
           (require racket/place raft)
           (define (start-worker)
             (place ch
               (define blobs (dynamic-require 'kmeans-canary 'blobs))
               (define kmeans-fit (dynamic-require 'kmeans-canary 'kmeans-fit))
               (define (long-fit X)
                 (kmeans-fit X #:n-clusters 64 #:init 'random #:n-init 1 #:max-iter 100 #:tol 1e-12 #:seed 1))
               (define-values (X _) (blobs 2500000 32 #:centers 64 #:cluster-std 4.0 #:seed 1))
               (long-fit X)
               (place-channel-put ch 'warm)
               (long-fit X)))
           (module+ main
             (define worker (start-worker))
             (void (place-channel-get worker))
             (sleep 0.1)
             (exit 0))))
        (sleep-job
         .
         (module program racket/base
           (require kmeans-canary/private/native raft)
           (parameterize ([current-exit-wait 0.2])
             (thread (lambda () (kc-sleep-job 'sleep (current-device-resources) 1000))))
           (sleep 0.1)
           (exit 3))))
