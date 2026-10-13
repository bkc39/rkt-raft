#lang racket/base
;; Spike #32 measurement d: racket exit.rkt <fit|fit-cold|sleep|none> <exit-code> [exit-wait-seconds]
(require (only-in kmeans-canary blobs kmeans-fit)
         (only-in kmeans-canary/private/native kc-sleep-job)
         (only-in raft current-device-resources)
         (only-in raft/unsafe current-exit-wait))

(define args (current-command-line-arguments))
(define what (vector-ref args 0))
(define code (string->number (vector-ref args 1)))
(define bound
  (if (> (vector-length args) 2)
      (string->number (vector-ref args 2))
      (current-exit-wait)))

(define r (current-device-resources))

(define (long-fit X)
  (kmeans-fit X #:n-clusters 64 #:init 'random #:n-init 1 #:max-iter 100 #:tol 1e-12 #:seed 1))

(define (in-background thunk)
  (parameterize ([current-exit-wait bound])
    (thread thunk))
  (sleep 0.1)
  (eprintf "[racket: exit ~a at 100 ms]\n" code)
  (exit code))

(case what
  [("fit" "fit-cold")
   (define-values (X _) (blobs 2500000 32 #:centers 64 #:cluster-std 4.0 #:seed 1))
   (when (equal? what "fit")
     (long-fit X))
   (in-background (lambda ()
                    (long-fit X)
                    (eprintf "[racket: fit returned]\n")))]
  [("sleep")
   (in-background (lambda ()
                    (kc-sleep-job 'sleep r 1000)
                    (eprintf "[racket: sleep job returned]\n")))]
  [("none")
   (eprintf "[racket: exit ~a, no job ever submitted]\n" code)
   (exit code)])
