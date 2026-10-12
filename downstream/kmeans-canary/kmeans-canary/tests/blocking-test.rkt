#lang racket/base

(require (only-in racket/list make-list)
         (only-in racket/match match-define)
         (only-in rackunit check-equal? check-pred check-true)
         (only-in raft contiguous exn:fail:raft-kind exn:fail:raft? list*->device-matrix shape)
         (only-in raft/tests/private/collect drain-finalizers!)
         (only-in raft/tests/private/gpu test-gpu)
         (only-in "../main.rkt" blobs kmeans-fit kmeans-predict))

(define (long-fit X)
  (kmeans-fit X #:n-clusters 64 #:init 'random #:n-init 1 #:max-iter 100 #:tol 1e-12 #:seed 1))

(define (milliseconds-since start)
  (- (current-inexact-milliseconds) start))

(define (timed-long-fit X)
  (define start (current-inexact-milliseconds))
  (long-fit X)
  (milliseconds-since start))

(define (start-ticker ticks)
  (thread (lambda ()
            (let loop ()
              (sleep 0.01)
              (set-box! ticks (add1 (unbox ticks)))
              (loop)))))

(test-gpu "other Racket threads run during a long kmeans-fit"
  (define-values (X _) (blobs 2500000 32 #:centers 64 #:cluster-std 4.0 #:seed 1))
  (long-fit X)
  (define ticks (box 0))
  (define ticker (start-ticker ticks))
  (define elapsed (timed-long-fit X))
  (kill-thread ticker)
  (check-true (> elapsed 300) (format "the fit took ~a ms" elapsed))
  (check-true (> (unbox ticks) (/ elapsed 20))
              (format "~a ticks of 10 ms in a ~a ms fit" (unbox ticks) elapsed)))

(test-gpu "a break during kmeans-fit is raised after the fit, leaving its arrays usable"
  (define-values (X truth) (blobs 2500000 32 #:centers 64 #:cluster-std 4.0 #:seed 1))
  (define unbroken (timed-long-fit X))
  (define start (current-inexact-milliseconds))
  (define broken-at (box #f))
  (define caller
    (thread (lambda ()
              (with-handlers ([exn:break? (lambda (_)
                                            (set-box! broken-at (milliseconds-since start)))])
                (long-fit X)))))
  (sleep 0.05)
  (break-thread caller)
  (thread-wait caller)
  (check-pred real? (unbox broken-at))
  (check-true
   (> (unbox broken-at) (/ unbroken 2))
   (format "the break arrived at ~a ms; an unbroken fit takes ~a ms" (unbox broken-at) unbroken))
  (drain-finalizers!)
  (define-values (centroids inertia _n-iter) (long-fit X))
  (define-values (labels score) (kmeans-predict centroids X))
  (check-equal? (list (shape centroids) (shape labels) (shape truth)) '((64 32) (2500000) (2500000)))
  (check-true (and (> inertia 0) (> score 0))))

(define (raised-errors attempts thunk)
  (define errors (box '()))
  (define caller
    (thread (lambda ()
              (for ([_ (in-range attempts)])
                (with-handlers ([exn:fail:raft? (lambda (e)
                                                  (set-box! errors
                                                            (cons (list (exn:fail:raft-kind e)
                                                                        (exn-message e))
                                                                  (unbox errors))))])
                  (thunk))))))
  (lambda ()
    (thread-wait caller)
    (unbox errors)))

(test-gpu "threads failing at once each raise their own call's error"
  (define-values (X _) (blobs 10 2 #:seed 1))
  (define col-major (contiguous X #:layout 'col-major))
  (define wide (list*->device-matrix '((0 0 0)) #:dtype 'float32))
  (define cases
    (list (list "kmeans-fit: X: 10 samples are fewer than the 11 clusters"
                (lambda () (kmeans-fit X #:n-clusters 11)))
          (list "kmeans-fit: X: expected row-major, got col-major 10x2"
                (lambda () (kmeans-fit col-major #:n-clusters 2)))
          (list "kmeans-predict: X: expected 3 columns, got 2" (lambda () (kmeans-predict wide X)))))
  (define results
    (for/list ([expected (in-list cases)])
      (match-define (list _ thunk) expected)
      (raised-errors 25 thunk)))
  (for ([expected (in-list cases)]
        [result (in-list results)])
    (match-define (list message _) expected)
    (check-equal? (result) (make-list 25 (list 'logic message)))))
