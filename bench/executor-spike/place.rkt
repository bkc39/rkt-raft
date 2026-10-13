#lang racket/base
;; Spike #32 measurement h: racket place.rkt <exit-code> [exit-wait-seconds] [alloc]
;; A place submits a ~1 s fit; the main place exits 100 ms into it.
(require (only-in kmeans-canary blobs kmeans-fit)
         (only-in racket/match match-define)
         (only-in racket/place dynamic-place place-channel-get place-channel-put)
         (only-in raft/unsafe current-exit-wait)
         racket/runtime-path)

(provide worker)

(define-runtime-path self "place.rkt")

(define (long-fit X)
  (kmeans-fit X #:n-clusters 64 #:init 'random #:n-init 1 #:max-iter 100 #:tol 1e-12 #:seed 1))

(define (churn)
  (let loop ([n 0])
    (void (make-vector 100000 n))
    (loop (add1 n))))

(define (worker channel)
  (match-define (list bound alloc?) (place-channel-get channel))
  (when alloc?
    (thread churn))
  (define-values (X _) (blobs 2500000 32 #:centers 64 #:cluster-std 4.0 #:seed 1))
  (long-fit X)
  (place-channel-put channel 'warm)
  (parameterize ([current-exit-wait bound])
    (long-fit X))
  (eprintf "[place: fit returned]\n"))

(module+ main
  (define args (current-command-line-arguments))
  (define code (string->number (vector-ref args 0)))
  (define bound
    (if (> (vector-length args) 1)
        (string->number (vector-ref args 1))
        10))
  (define alloc? (> (vector-length args) 2))
  (define p (dynamic-place self 'worker))
  (when alloc?
    (thread churn))
  (place-channel-put p (list bound alloc?))
  (place-channel-get p)
  (sleep 0.1)
  (eprintf "[main: exit ~a 100 ms into the place's fit]\n" code)
  (exit code))
