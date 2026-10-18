((define canary (ffi-lib (getenv "RAFT_KMEANS_CANARY"))) (values "") "" "")
((define-ffi-definer
  define-kc
  canary
  #:make-c-id
  convention:hyphen->underscore)
 (values "")
 ""
 "")
((define-kc kc-last-error (_fun -> _bytes/nul-terminated)) (values "") "" "")
((define-kc kc-last-error-kind (_fun -> _int)) (values "") "" "")
((define-kc kc-check-abi (_fun _pointer -> _int)) (values "") "" "")
((define-kc
  kc-make-blobs
  (_fun
   _pointer
   _pointer
   _pointer
   _int32
   _double
   _int32
   _double
   _double
   _uint64
   ->
   _int))
 (values "")
 ""
 "")
((define-kc
  kc-fit
  (_fun
   _pointer
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
   ->
   (status : _int)
   ->
   (values status inertia n-iter)))
 (values "")
 ""
 "")
((define-kc
  kc-predict
  (_fun
   _pointer
   _pointer
   _pointer
   _pointer
   _int32
   _pointer
   (inertia : (_ptr o _double))
   ->
   (status : _int)
   ->
   (values status inertia)))
 (values "")
 ""
 "")
((define-kc
  kc-cluster-members
  (_fun _pointer _pointer _pointer _int32 _pointer -> _int))
 (values "")
 ""
 "")
((define-job
  kc-make-blobs-job
  canary
  "kc_make_blobs_job"
  (handle view view _int32 _double _int32 _double _double _uint64))
 (values "")
 ""
 "")
((define-job
  kc-fit-job
  canary
  "kc_fit_job"
  (handle
   view
   view
   view
   _int32
   _int32
   _double
   _int32
   _double
   _uint64
   (out _double)
   (out _int32)))
 (values "")
 ""
 "")
((define-job
  kc-predict-job
  canary
  "kc_predict_job"
  (handle view view view _int32 view (out _double)))
 (values "")
 ""
 "")
((define check (status-checker kc-last-error kc-last-error-kind))
 (values "")
 ""
 "")
((check 'kmeans-canary (lambda () (kc-check-abi (raft-abi-pointer))))
 (values)
 ""
 "")
((define ints (list*->device-matrix '((1 2) (3 4) (5 6)) #:dtype 'int32))
 (values "")
 ""
 "")
((define centers (device-matrix 2 2)) (values "") "" "")
((define handle (resources->handle-pointer (current-device-resources)))
 (values "")
 ""
 "")
((with-array-views
  ((x ints) (c centers))
  (check 'kmeans-fit (lambda () (kc-fit handle x #f c 0 300 0.0001 1 0.0 42))))
 (raise "kmeans-fit: X: expected float32 or float64, got int32")
 ""
 "")
((with-handlers
  ((exn:fail:raft? exn:fail:raft-kind))
  (with-array-views
   ((x ints) (c centers))
   (check
    'kmeans-fit
    (lambda () (kc-fit handle x #f c 0 300 0.0001 1 0.0 42)))))
 (values "'logic\n")
 ""
 "")
((struct exn:fail:canary exn:fail:raft ()) (values "") "" "")
((define check/canary
   (status-checker kc-last-error kc-last-error-kind #:exn exn:fail:canary))
 (values "")
 ""
 "")
((define X (device-matrix 300 2)) (values "") "" "")
((define truth (device-vector 300 #:dtype 'int32)) (values "") "" "")
((with-array-views
  ((x X) (y truth))
  (check/canary
   'blobs
   (lambda () (kc-make-blobs handle x y 3 0.5 1 -10.0 10.0 7))))
 (values)
 ""
 "")
((define fitted (device-matrix 3 2)) (values "") "" "")
((define-values
  (inertia n-iter)
  (with-array-views
   ((x X) (c fitted))
   (check/canary
    'kmeans-fit
    (lambda () (kc-fit handle x #f c 0 300 0.0001 1 0.0 42)))))
 (values "")
 ""
 "")
((list (> inertia 0) (>= n-iter 1)) (values "'(#t #t)\n") "" "")
((with-handlers
  ((exn:fail:canary? (lambda (e) (list 'canary (exn-message e)))))
  (with-array-views
   ((x X) (c (device-matrix 3 5)))
   (check/canary
    'kmeans-fit
    (lambda () (kc-fit handle x #f c 0 300 0.0001 1 0.0 42)))))
 (values "'(canary \"kmeans-fit: centroids: expected 2 columns, got 5\")\n")
 ""
 "")
((define-values
  (inertia n-iter)
  (kc-fit-job
   'kmeans-fit
   (current-device-resources)
   X
   #f
   fitted
   0
   300
   0.0001
   1
   0.0
   42))
 (values "")
 ""
 "")
((list (> inertia 0) (>= n-iter 1)) (values "'(#t #t)\n") "" "")
((kc-fit-job
  'kmeans-fit
  (current-device-resources)
  ints
  #f
  centers
  0
  300
  0.0001
  1
  0.0
  42)
 (raise "kmeans-fit: X: expected float32 or float64, got int32")
 ""
 "")
((kc-fit-job
  'kmeans-fit
  (current-device-resources)
  'not-an-array
  #f
  centers
  0
  300
  0.0001
  1
  0.0
  42)
 (raise
  "kmeans-fit: expected a device array or #f for a view, given 'not-an-array")
 ""
 "")
((define big (device-matrix 1000000 32)) (values "") "" "")
((kc-make-blobs-job
  'blobs
  (current-device-resources)
  big
  (device-vector 1000000 #:dtype 'int32)
  64
  1.0
  1
  -10.0
  10.0
  1)
 (values)
 ""
 "")
((define (ticks-during thunk)
   (define ticks (box 0))
   (define ticker
     (thread
      (lambda ()
        (let loop ()
          (sleep 0.005)
          (set-box! ticks (add1 (unbox ticks)))
          (loop)))))
   (thunk)
   (kill-thread ticker)
   (unbox ticks))
 (values "")
 ""
 "")
((<=
  10
  (ticks-during
   (lambda ()
     (kc-fit-job
      'kmeans-fit
      (current-device-resources)
      big
      #f
      (device-matrix 64 32)
      1
      100
      1e-12
      1
      0.0
      1))))
 (values "#t\n")
 ""
 "")
((define-job
  kc-fit-job/short
  canary
  "kc_fit_job"
  (handle view view view _int32))
 (values "")
 ""
 "")
((kc-fit-job/short 'kmeans-fit (current-device-resources) X #f fitted 0)
 (raise "kmeans-fit: the argument block is 472 bytes; the job expects 520")
 ""
 "")
((define labels (device-vector 300 #:dtype 'int32)) (values "") "" "")
((kc-predict-job
  'kmeans-predict
  (current-device-resources)
  fitted
  X
  #f
  1
  labels)
 (values "154.17282104492188\n")
 ""
 "")
((define-job
  kc-cluster-members-job
  canary
  "kc_cluster_members_job"
  (handle view view _int32 deposit))
 (values "")
 ""
 "")
((define found (deposit)) (values "") "" "")
((kc-cluster-members-job
  'cluster-members
  (current-device-resources)
  X
  labels
  0
  found)
 (values)
 ""
 "")
((deposit->list found)
 (values
  "'(#<device-vector int64[100] cuda:0 [  1   4   7 ... 292 295 298]> #<device-matrix float32[100×2] row-major cuda:0\n [[  9.078729  -8.686529]\n  [  8.251212  -8.188368]\n  [  8.923475   -9.37299]\n  ...\n  [  8.185297 -7.1188946]\n  [  8.874211  -8.659465]\n  [  9.315469  -8.734181]]>)\n")
 ""
 "")
((kc-cluster-members-job
  'cluster-members
  (current-device-resources)
  X
  labels
  0
  found)
 (raise "cluster-members: the deposit is closed")
 ""
 "")
((kc-cluster-members-job
  'cluster-members
  (current-device-resources)
  X
  labels
  0
  'not-a-deposit)
 (raise
  "cluster-members: expected a deposit for a deposit parameter, given 'not-a-deposit")
 ""
 "")
((raft-abi-pointer) (values "#<cpointer>\n") "" "")
((ptr-ref (raft-abi-pointer) _int32 0) (values "1\n") "" "")
((raft-abi-version (raft-abi)) (values "1\n") "" "")
((check 'kmeans-canary (lambda () (kc-check-abi (raft-abi-pointer))))
 (values)
 ""
 "")
((define (forged-tag type index value)
   (define tag (make-bytes 56))
   (memcpy tag (raft-abi-pointer) 56)
   (ptr-set! tag type index value)
   tag)
 (values "")
 ""
 "")
((check 'kmeans-canary (lambda () (kc-check-abi (forged-tag _int32 2 10))))
 (raise
  "kmeans-canary: RAFT: built against 26.08.00, but libraftrkt has 26.10.00; build both against the same rapids package set")
 ""
 "")
((define bigger-handle (add1 (raft-abi-handle-size (raft-abi))))
 (values "")
 ""
 "")
((check
  'kmeans-canary
  (lambda () (kc-check-abi (forged-tag _int64 6 bigger-handle))))
 (raise
  "kmeans-canary: raft::handle_t size: built against 32, but libraftrkt has 33; build both against the same rapids package set")
 ""
 "")
((resources->handle-pointer (current-device-resources))
 (values "#<cpointer>\n")
 ""
 "")
((ptr-equal? handle (resources->handle-pointer (current-device-resources)))
 (values "#t\n")
 ""
 "")
((define other (device-resources)) (values "") "" "")
((ptr-equal? handle (resources->handle-pointer other)) (values "#f\n") "" "")
((define Y (device-matrix 6 2 #:resources other)) (values "") "" "")
((define classes (device-vector 6 #:dtype 'int32 #:resources other))
 (values "")
 ""
 "")
((with-array-views
  #:resources
  (on-other other)
  ((y Y) (k classes))
  (check 'blobs (lambda () (kc-make-blobs on-other y k 2 0.1 0 -1.0 1.0 3)))
  (ptr-equal? on-other (resources->handle-pointer other)))
 (values "#t\n")
 ""
 "")
((sort (remove-duplicates (device-vector->list classes)) <)
 (values "'(0 1)\n")
 ""
 "")
((define finished (with-device-resources ((r (device-resources))) r))
 (values "")
 ""
 "")
((resources->handle-pointer finished)
 (raise
  "resources->handle-pointer: the device resources on device 0 were released")
 ""
 "")
((define score
   (with-array-views
    #:resources
    (handle (current-device-resources))
    ((c fitted) (x X) (w #f) (y labels))
    (check 'kmeans-predict (lambda () (kc-predict handle c x w 1 y)))))
 (values "")
 ""
 "")
((< (abs (- score inertia)) (* 0.001 inertia)) (values "#t\n") "" "")
((length (remove-duplicates (device-vector->list labels)))
 (values "3\n")
 ""
 "")
((define F (contiguous X #:layout 'col-major)) (values "") "" "")
((with-array-views
  ((f F))
  (list
   (ptr-ref f _int32 'abs 8)
   (ptr-ref f _int32 'abs 20)
   (list (ptr-ref f _int64 'abs 24) (ptr-ref f _int64 'abs 32))
   (list (ptr-ref f _int64 'abs 88) (ptr-ref f _int64 'abs 96))))
 (values "'(0 2 (300 2) (1 300))\n")
 ""
 "")
((with-array-views
  ((x F) (c (device-matrix 3 2)))
  (check 'kmeans-fit (lambda () (kc-fit handle x #f c 0 300 0.0001 1 0.0 42))))
 (raise "kmeans-fit: X: expected row-major, got col-major 300x2")
 ""
 "")
((define stale (with-array-views ((x X)) x)) (values "") "" "")
((with-array-views
  ((c fitted) (y labels))
  (check 'kmeans-predict (lambda () (kc-predict handle c stale #f 1 y))))
 (raise "kmeans-predict: X: not a view bound to device memory")
 ""
 "")
((define members (deposit)) (values "") "" "")
((with-deposits
  ((out members))
  (with-array-views
   #:resources
   (handle (current-device-resources))
   ((x X) (y labels))
   (check 'cluster-members (lambda () (kc-cluster-members handle x y 0 out)))))
 (values)
 ""
 "")
((match-define (list indices rows) (deposit->list members)) (values "") "" "")
((list
  (dtype indices)
  (dtype rows)
  (= (car (shape rows)) (car (shape indices))))
 (values "'(int64 float32 #t)\n")
 ""
 "")
((eq? indices (first (deposit->list members))) (values "#t\n") "" "")
((define pending (deposit)) (values "") "" "")
((with-deposits ((out pending)) (deposit->list pending))
 (raise "deposit->list: the deposit is still open")
 ""
 "")
((deposit->list pending) (values "'()\n") "" "")
((with-deposits ((out members)) out)
 (raise "with-deposits: the deposit is closed")
 ""
 "")
((define elsewhere (deposit #:resources other)) (values "") "" "")
((with-deposits
  ((out elsewhere))
  (with-array-views
   #:resources
   (handle (current-device-resources))
   ((x X) (y labels))
   (check 'cluster-members (lambda () (kc-cluster-members handle x y 0 out)))))
 (raise "cluster-members: out: on resources other than the call's")
 ""
 "")
