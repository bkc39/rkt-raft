#lang racket/base

(require (only-in ffi/unsafe
                  _bytes/nul-terminated
                  _double
                  _fun
                  _int
                  _int32
                  _int64
                  _pointer
                  _ptr
                  _uint64
                  cpointer?
                  ffi-lib
                  memcpy
                  ptr-equal?
                  ptr-ref
                  ptr-set!)
         (only-in ffi/unsafe/define define-ffi-definer make-not-available)
         (only-in ffi/unsafe/define/conventions convention:hyphen->underscore)
         (only-in racket/flonum make-flvector)
         (only-in racket/format ~r)
         (only-in racket/list count remove-duplicates)
         (only-in racket/string non-empty-string?)
         (only-in rackunit check-equal? check-exn check-true)
         ;; whole-module: its syntax classes come with it
         syntax/parse/define
         (only-in "../main.rkt"
                  contiguous
                  current-device-resources
                  device-matrix
                  device-resources
                  device-vector
                  device-vector->list
                  dtype
                  exn:fail:raft
                  exn:fail:raft-kind
                  flvector->device-vector
                  layout
                  list*->device-matrix
                  raft-abi
                  raft-abi-handle-size
                  raft-abi-version
                  shape
                  with-device-resources)
         (only-in "../unsafe.rkt"
                  raft-abi-pointer
                  resources->handle-pointer
                  status-checker
                  with-array-views)
         (only-in "private/gpu.rkt" gpu-skip test-unless-skipped)
         (only-in "private/raft-error.rkt" check-raft-error))

(define canary-path (let ([path (getenv "RAFT_KMEANS_CANARY")]) (and (non-empty-string? path) path)))

(define canary-skip ;; noqa
  (or gpu-skip
      (and (not canary-path)
           "no k-means canary (RAFT_KMEANS_CANARY is not set; run inside nix develop)")
      (and (not (collection-file-path "main.rkt" "kmeans-canary" #:fail (lambda (_) #f)))
           "no k-means canary (the kmeans-canary package is not installed; run inside nix develop)")))

(define-syntax-parse-rule (test-canary name:expr body:expr ...+) ;; noqa
  (test-unless-skipped canary-skip name body ...))

(define canary (and canary-path (ffi-lib canary-path)))

(define-ffi-definer define-kc
                    canary
                    #:make-c-id convention:hyphen->underscore
                    #:default-make-fail make-not-available)

(define-kc kc-last-error (_fun -> _bytes/nul-terminated))
(define-kc kc-last-error-kind (_fun -> _int))
(define-kc kc-check-abi (_fun _pointer -> _int))
(define-kc kc-make-blobs
  (_fun _pointer _pointer _pointer _int32 _double _int32 _double _double _uint64 -> _int))
(define-kc kc-fit
  (_fun _pointer
        _pointer
        _pointer
        _pointer
        _int32
        _int32
        _double
        _int32
        _double
        _uint64
        (inertia : (_ptr o _double))
        (n-iter : (_ptr o _int32))
        -> (status : _int)
        -> (values status inertia n-iter)))
(define-kc kc-predict
  (_fun _pointer _pointer _pointer _pointer _int32 _pointer (inertia : (_ptr o _double))
        -> (status : _int)
        -> (values status inertia)))

(define (canary-procedure name)
  (dynamic-require 'kmeans-canary name))

(define (no-values thunk)
  (call-with-values thunk list))

(struct exn:fail:canary exn:fail:raft ())

(define (fit-with check handle X centroids)
  (with-array-views ([x X] [c centroids])
    (check 'kmeans-fit (lambda () (kc-fit handle x #f c 0 300 1e-4 1 0.0 42)))))

(define (made-blobs check handle)
  (define X (device-matrix 300 2))
  (define truth (device-vector 300 #:dtype 'int32))
  (with-array-views ([x X] [y truth])
    (check 'blobs (lambda () (kc-make-blobs handle x y 3 0.5 1 -10.0 10.0 7))))
  X)

(test-canary "unsafe reference: checking native calls"
  (define check (status-checker kc-last-error kc-last-error-kind))
  (check-equal? (no-values (lambda ()
                             (check 'kmeans-canary (lambda () (kc-check-abi (raft-abi-pointer))))))
                '())
  (define ints (list*->device-matrix '((1 2) (3 4) (5 6)) #:dtype 'int32))
  (define handle (resources->handle-pointer (current-device-resources)))
  (check-raft-error 'logic
                    "kmeans-fit: X: expected float32 or float64, got int32"
                    (lambda () (fit-with check handle ints (device-matrix 2 2))))
  (define check/canary (status-checker kc-last-error kc-last-error-kind #:exn exn:fail:canary))
  (define X (made-blobs check/canary handle))
  (define-values (inertia n-iter) (fit-with check/canary handle X (device-matrix 3 2)))
  (check-equal? (list (> inertia 0) (>= n-iter 1)) '(#t #t))
  (check-exn (lambda (e)
               (and (exn:fail:canary? e)
                    (equal? (exn-message e) "kmeans-fit: centroids: expected 2 columns, got 5")))
             (lambda () (fit-with check/canary handle X (device-matrix 3 5)))))

(define (forged-tag type index value)
  (define tag (make-bytes 56))
  (memcpy tag (raft-abi-pointer) 56)
  (ptr-set! tag type index value)
  tag)

(test-canary "unsafe reference: the ABI tag"
  (define check (status-checker kc-last-error kc-last-error-kind))
  (check-true (cpointer? (raft-abi-pointer)))
  (check-equal? (ptr-ref (raft-abi-pointer) _int32 0) (raft-abi-version (raft-abi)))
  (check-equal? (ptr-ref (raft-abi-pointer) _int32 0) 1)
  (check-raft-error
   'logic
   "kmeans-canary: RAFT: built against 26.08.00, but libraftrkt has 26.10.00; build both against the same rapids package set"
   (lambda () (check 'kmeans-canary (lambda () (kc-check-abi (forged-tag _int32 2 10))))))
  (define bigger-handle (add1 (raft-abi-handle-size (raft-abi))))
  (check-raft-error
   'logic
   (format
    "kmeans-canary: raft::handle_t size: built against ~a, but libraftrkt has ~a; build both against the same rapids package set"
    (raft-abi-handle-size (raft-abi))
    bigger-handle)
   (lambda () (check 'kmeans-canary (lambda () (kc-check-abi (forged-tag _int64 6 bigger-handle)))))))

(test-canary "unsafe reference: the handle"
  (define check (status-checker kc-last-error kc-last-error-kind))
  (define handle (resources->handle-pointer (current-device-resources)))
  (check-true (ptr-equal? handle (resources->handle-pointer (current-device-resources))))
  (define other (device-resources))
  (check-equal? (ptr-equal? handle (resources->handle-pointer other)) #f)
  (define Y (device-matrix 6 2 #:resources other))
  (define classes (device-vector 6 #:dtype 'int32 #:resources other))
  (check-true (with-array-views #:resources [on-other other] ([y Y] [k classes])
                (check 'blobs (lambda () (kc-make-blobs on-other y k 2 0.1 0 -1.0 1.0 3)))
                (ptr-equal? on-other (resources->handle-pointer other))))
  (check-equal? (sort (remove-duplicates (device-vector->list classes)) <) '(0 1))
  (define finished (with-device-resources ([r (device-resources)]) r))
  (check-raft-error 'logic
                    "resources->handle-pointer: the device resources on device 0 were released"
                    (lambda () (resources->handle-pointer finished))))

(test-canary "unsafe reference: array views"
  (define check (status-checker kc-last-error kc-last-error-kind))
  (define handle (resources->handle-pointer (current-device-resources)))
  (define X (made-blobs check handle))
  (define fitted (device-matrix 3 2))
  (define-values (inertia _n-iter) (fit-with check handle X fitted))
  (define labels (device-vector 300 #:dtype 'int32))
  (define score
    (with-array-views #:resources
                      [default-handle (current-device-resources)]
                      ([c fitted] [x X] [w #f] [y labels])
      (check 'kmeans-predict (lambda () (kc-predict default-handle c x w 1 y)))))
  (check-true (< (abs (- score inertia)) (* 1e-3 inertia)))
  (check-equal? (length (remove-duplicates (device-vector->list labels))) 3)
  (define F (contiguous X #:layout 'col-major))
  (check-equal? (with-array-views ([f F])
                  (list (ptr-ref f _int32 'abs 8)
                        (ptr-ref f _int32 'abs 20)
                        (list (ptr-ref f _int64 'abs 24) (ptr-ref f _int64 'abs 32))
                        (list (ptr-ref f _int64 'abs 88) (ptr-ref f _int64 'abs 96))))
                '(0 2 (300 2) (1 300)))
  (check-raft-error 'logic
                    "kmeans-fit: X: expected row-major, got col-major 300x2"
                    (lambda () (fit-with check handle F (device-matrix 3 2))))
  (define stale (with-array-views ([x X]) x))
  (check-raft-error 'logic
                    "kmeans-predict: X: not a view bound to device memory"
                    (lambda ()
                      (with-array-views ([c fitted] [y labels])
                        (check 'kmeans-predict (lambda () (kc-predict handle c stale #f 1 y)))))))

(test-canary "building on raft guide: k-means from Racket"
  (define blobs (canary-procedure 'blobs))
  (define kmeans-fit (canary-procedure 'kmeans-fit))
  (define kmeans-predict (canary-procedure 'kmeans-predict))
  (define-values (X _truth) (blobs 300 2 #:centers 3 #:cluster-std 0.6 #:seed 7))
  (check-equal? (list (shape X) (dtype X) (layout X)) '((300 2) float32 row-major))
  (define-values (centroids inertia n-iter) (kmeans-fit X #:n-clusters 3 #:seed 42))
  (check-equal? (list (shape centroids) (dtype centroids)) '((3 2) float32))
  (check-equal? (list (~r inertia #:precision '(= 2)) n-iter) '("222.00" 2))
  (define-values (labels _score) (kmeans-predict centroids X))
  (check-equal? (for/list ([k (in-range 3)])
                  (count (lambda (label) (= label k)) (device-vector->list labels)))
                '(100 100 100))
  (check-raft-error 'logic
                    "kmeans-fit: X: expected row-major, got col-major 300x2"
                    (lambda () (kmeans-fit (contiguous X #:layout 'col-major) #:n-clusters 3)))
  (check-raft-error 'logic
                    "kmeans-fit: X: expected float32 or float64, got int32"
                    (lambda () (kmeans-fit (list*->device-matrix '((1 2) (3 4)) #:dtype 'int32))))
  (check-raft-error 'logic
                    "kmeans-fit: X: 300 samples are fewer than the 301 clusters"
                    (lambda () (kmeans-fit X #:n-clusters 301)))
  (define ones (flvector->device-vector (make-flvector 300 1.0) #:dtype 'float32))
  (define-values (_weighted-centroids weighted _weighted-iterations)
    (kmeans-fit X #:n-clusters 3 #:seed 42 #:sample-weight ones))
  (check-true (< (abs (- weighted inertia)) (* 1e-4 inertia))))

(test-canary "building on raft guide: lifetimes and streams"
  (define blobs (canary-procedure 'blobs))
  (define kmeans-fit (canary-procedure 'kmeans-fit))
  (define-values (X _truth) (blobs 300 2 #:centers 3 #:cluster-std 0.6 #:seed 7))
  (define-values (centroids _inertia _n-iter) (kmeans-fit X #:n-clusters 3 #:seed 42))
  (define kept (with-array-views ([c centroids]) c))
  (check-equal? (list (ptr-ref kept _pointer) (ptr-ref kept _int32 'abs 16)) '(#f -1))
  (define-values (X2 _truth2)
    (with-device-resources ([r (device-resources)])
      (blobs 50 2 #:centers 2 #:seed 1 #:resources r)))
  (define-values (c2 _inertia2 _n-iter2) (kmeans-fit X2 #:n-clusters 2))
  (check-equal? (shape c2) '(2 2))
  (define canary-current-is-async? (dynamic-require 'kmeans-canary/pool 'canary-current-is-async?))
  (define canary-pool-bytes (dynamic-require 'kmeans-canary/pool 'canary-pool-bytes))
  (define canary-pool-reset-high! (dynamic-require 'kmeans-canary/pool 'canary-pool-reset-high!))
  (check-true (canary-current-is-async?))
  (define-values (in-use _high-before _reserved-before) (canary-pool-bytes))
  (canary-pool-reset-high!)
  (kmeans-fit X #:n-clusters 3 #:seed 42)
  (define-values (after peak _reserved-after) (canary-pool-bytes))
  (check-equal? (list (> peak in-use) (> peak after)) '(#t #t))
  (check-equal? (raft-abi-version (raft-abi)) 1))
