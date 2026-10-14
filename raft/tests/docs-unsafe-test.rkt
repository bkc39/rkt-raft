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
         (only-in racket/list first remove-duplicates)
         (only-in racket/match match-define)
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
                  list*->device-matrix
                  raft-abi
                  raft-abi-handle-size
                  raft-abi-version
                  shape
                  with-device-resources)
         (only-in "../unsafe.rkt"
                  define-job
                  deposit
                  deposit->list
                  raft-abi-pointer
                  resources->handle-pointer
                  status-checker
                  with-array-views
                  with-deposits)
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
(define-kc kc-cluster-members (_fun _pointer _pointer _pointer _int32 _pointer -> _int))

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

(define (ticks-during thunk)
  (define ticks (box 0))
  (define ticker
    (thread (lambda ()
              (let loop ()
                (sleep 0.005)
                (set-box! ticks (add1 (unbox ticks)))
                (loop)))))
  (thunk)
  (kill-thread ticker)
  (unbox ticks))

(test-canary "unsafe reference: long calls"
  (define-job kc-make-blobs-job
              canary
              "kc_make_blobs_job"
              (handle view view _int32 _double _int32 _double _double _uint64))
  (define-job
   kc-fit-job
   canary
   "kc_fit_job"
   (handle view view view _int32 _int32 _double _int32 _double _uint64 (out _double) (out _int32)))
  (define-job kc-fit-job/short canary "kc_fit_job" (handle view view view _int32))
  (define check (status-checker kc-last-error kc-last-error-kind))
  (define handle (resources->handle-pointer (current-device-resources)))
  (define X (made-blobs check handle))
  (define fitted (device-matrix 3 2))
  (define-values (inertia n-iter)
    (kc-fit-job 'kmeans-fit (current-device-resources) X #f fitted 0 300 1e-4 1 0.0 42))
  (check-equal? (list (> inertia 0) (>= n-iter 1)) '(#t #t))
  (define ints (list*->device-matrix '((1 2) (3 4) (5 6)) #:dtype 'int32))
  (check-raft-error 'logic
                    "kmeans-fit: X: expected float32 or float64, got int32"
                    (lambda ()
                      (kc-fit-job 'kmeans-fit
                                  (current-device-resources)
                                  ints
                                  #f
                                  (device-matrix 2 2)
                                  0
                                  300
                                  1e-4
                                  1
                                  0.0
                                  42)))
  (define big (device-matrix 1000000 32))
  (kc-make-blobs-job 'blobs
                     (current-device-resources)
                     big
                     (device-vector 1000000 #:dtype 'int32)
                     64
                     1.0
                     1
                     -10.0
                     10.0
                     1)
  (check-true (<= 10
                  (ticks-during (lambda ()
                                  (kc-fit-job 'kmeans-fit
                                              (current-device-resources)
                                              big
                                              #f
                                              (device-matrix 64 32)
                                              1
                                              100
                                              1e-12
                                              1
                                              0.0
                                              1)))))
  (check-raft-error 'logic
                    "kmeans-fit: the argument block is 472 bytes; the job expects 520"
                    (lambda ()
                      (kc-fit-job/short 'kmeans-fit (current-device-resources) X #f fitted 0)))
  (define-job kc-predict-job
              canary
              "kc_predict_job"
              (handle view view view _int32 view (out _double)))
  (define-job kc-cluster-members-job
              canary
              "kc_cluster_members_job"
              (handle view view _int32 deposit))
  (define labels (device-vector 300 #:dtype 'int32))
  (kc-predict-job 'kmeans-predict (current-device-resources) fitted X #f 1 labels)
  (define found (deposit))
  (kc-cluster-members-job 'cluster-members (current-device-resources) X labels 0 found)
  (match-define (list found-indices found-rows) (deposit->list found))
  (check-equal? (car (shape found-rows)) (car (shape found-indices)))
  (check-raft-error
   'logic
   "cluster-members: the deposit is closed"
   (lambda () (kc-cluster-members-job 'cluster-members (current-device-resources) X labels 0 found))))

(test-canary "unsafe reference: outputs sized by the call"
  (define check (status-checker kc-last-error kc-last-error-kind))
  (define handle (resources->handle-pointer (current-device-resources)))
  (define X (made-blobs check handle))
  (define fitted (device-matrix 3 2))
  (fit-with check handle X fitted)
  (define labels (device-vector 300 #:dtype 'int32))
  (with-array-views ([c fitted] [x X] [y labels])
    (check 'kmeans-predict (lambda () (kc-predict handle c x #f 1 y))))
  (define (members-of d)
    (with-deposits ([out d])
                   (with-array-views #:resources [h (current-device-resources)] ([x X] [y labels])
                     (check 'cluster-members (lambda () (kc-cluster-members h x y 0 out))))))
  (define members (deposit))
  (members-of members)
  (match-define (list indices rows) (deposit->list members))
  (check-equal? (list (dtype indices) (dtype rows) (= (car (shape rows)) (car (shape indices))))
                '(int64 float32 #t))
  (check-true (eq? indices (first (deposit->list members))))
  (define pending (deposit))
  (check-raft-error 'logic
                    "deposit->list: the deposit is still open"
                    (lambda () (with-deposits ([out pending]) (deposit->list pending))))
  (check-equal? (deposit->list pending) '())
  (check-raft-error 'logic
                    "with-deposits: the deposit is closed"
                    (lambda () (with-deposits ([out members]) out)))
  (define elsewhere (deposit #:resources (device-resources)))
  (check-raft-error 'logic
                    "cluster-members: out: on resources other than the call's"
                    (lambda () (members-of elsewhere))))
