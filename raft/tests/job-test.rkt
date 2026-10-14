#lang racket/base

(require (only-in ffi/unsafe
                  _double
                  _double*
                  _float
                  _int16
                  _int32
                  _int64
                  _int8
                  _uint16
                  _uint32
                  _uint64
                  _uint8
                  void/reference-sink)
         (only-in ffi/unsafe/atomic call-as-atomic)
         (only-in racket/list list-set)
         (only-in racket/match match-define)
         (only-in racket/math nan?)
         (only-in rackunit
                  check-equal?
                  check-eqv?
                  check-exn
                  check-false
                  check-not-equal?
                  check-pred
                  check-true
                  test-case)
         (only-in syntax/macro-testing convert-syntax-error)
         ;; whole-module: it also provides syntax/parse at phase 1
         syntax/parse/define
         (only-in "../main.rkt"
                  current-device-resources
                  device-matrix
                  device-resources
                  device-vector
                  exn:fail:raft
                  exn:fail:raft?
                  exn:fail:raft-kind
                  with-device-resources)
         (only-in "../private/foreign/memory.rkt"
                  buffer-drop-count
                  release-failure-count
                  resources-drop-count)
         (only-in "../private/job.rkt" define-job executor-threads jobs-in-flight jobs-live)
         (only-in "../private/resource.rkt" with-release)
         (only-in "../private/resources.rkt" host-resources)
         (only-in "../unsafe.rkt" resources->handle-pointer)
         (only-in "private/collect.rkt" collect-until drain-finalizers!)
         (only-in "private/gate.rkt"
                  await-entry
                  closed-gate
                  gate-entered-fd
                  gate-fd
                  open-gate!
                  release-gate)
         (only-in "private/probe.rkt"
                  call/probe
                  gate-job
                  probe-echo-job
                  probe-fail-job
                  probe-gate-job
                  probe-hold-views-job
                  probe-library
                  probe-thread-id-job
                  probe-token-job
                  probe-tokens
                  probe-tokens-clear!
                  rr-probe-thread-id
                  test-host-probe
                  test-probe)
         (only-in "private/raft-error.rkt" check-raft-error))

(define (await-in-flight n)
  (for/or ([_ (in-range 1000)])
    (cond
      [(= (jobs-in-flight) n) #t]
      [else
       (sleep 0.01)
       #f])))

(define (open-fds)
  (length (directory-list "/proc/self/fd")))

(define (settled-threads)
  (drain-finalizers!)
  (let settle ([seen (executor-threads)]
               [stable 0])
    (sleep 0.02)
    (define now (executor-threads))
    (cond
      [(not (= now seen)) (settle now 0)]
      [(< stable 4) (settle now (add1 stable))]
      [else now])))

(define-syntax-parse-rule (check-job-syntax pattern:expr (declaration ...))
  (check-exn pattern
             (lambda ()
               (convert-syntax-error (let ()
                                       (define-job declaration ...)
                                       (void))))))

(test-case "define-job refuses a malformed declaration"
  (check-job-syntax #rx"at most one handle parameter"
                    (demo probe-library "rr_probe_token_job" (handle _int32 handle)))
  (check-job-syntax #rx"expected a job parameter"
                    (demo probe-library "rr_probe_token_job" (_pointer)))
  (check-job-syntax #rx"expected a job parameter" (demo probe-library "rr_probe_token_job" (_bytes)))
  (check-job-syntax #rx"expected a job parameter" (demo probe-library "rr_probe_token_job" (view?)))
  (check-job-syntax #rx"expected a job parameter" (demo probe-library "rr_probe_token_job" (5)))
  (check-job-syntax #rx"expected a job parameter"
                    (demo probe-library "rr_probe_token_job" ((in _int32))))
  (check-job-syntax #rx"expected an output type"
                    (demo probe-library "rr_probe_token_job" ((out _double*))))
  (check-job-syntax #rx"expected an output type"
                    (demo probe-library "rr_probe_token_job" ((out view))))
  (check-job-syntax exn:fail:syntax? ("demo" probe-library "rr_probe_token_job" (_int32)))
  (check-job-syntax
   exn:fail:syntax?
   (demo probe-library "rr_probe_token_job" (_int32) #:exn exn:fail:raft #:exn exn:fail:raft)))

(test-host-probe "define-job evaluates its library, entry and exception once, at definition"
  (define counts (vector 0 0 0))
  (define (counted i v)
    (vector-set! counts i (add1 (vector-ref counts i)))
    v)
  (define-job counted-job
              (counted 0 probe-library)
              (counted 1 "rr_probe_token_job")
              (_int32)
              #:exn (counted 2 exn:fail:raft))
  (define r (host-resources))
  (probe-tokens-clear!)
  (counted-job 'demo r 1)
  (counted-job 'demo r 2)
  (check-equal? (probe-tokens) '(1 2))
  (check-equal? counts (vector 1 1 1))
  (check-exn exn:fail:filesystem?
             (lambda ()
               (define-job missing probe-library "rr_probe_no_such_job" ())
               missing)))

(test-host-probe "a job procedure is named, with the arity of its arguments"
  (check-equal? (object-name probe-echo-job) 'probe-echo-job)
  (check-equal? (procedure-arity probe-echo-job) 12)
  (check-equal? (procedure-arity probe-thread-id-job) 2)
  (check-equal? (procedure-arity probe-gate-job) 7)
  (drain-finalizers!)
  (define live (jobs-live))
  (check-exn exn:fail:contract:arity? (lambda () (probe-echo-job 'demo (host-resources) 1)))
  (check-equal? (jobs-live) live))

(define echo-cases
  (list (list -128 -32768 (- (expt 2 31)) (- (expt 2 63)) 0 0 0 0 1.5 -0.0)
        (list 127
              32767
              (sub1 (expt 2 31))
              (sub1 (expt 2 63))
              255
              65535
              (sub1 (expt 2 32))
              (sub1 (expt 2 64))
              -2.25
              +inf.0)
        (list 0 0 0 0 0 0 0 0 3.4028234663852886e38 -inf.0)
        (list 0 0 0 0 0 0 0 0 -0.0 4.9e-324)
        (list 0 0 0 0 0 0 0 0 +inf.0 1.7976931348623157e308)
        (list 0 0 0 0 0 0 0 0 +nan.0 0.0)))

(define (check-same got want)
  (cond
    [(and (flonum? want) (nan? want)) (check-true (nan? got))]
    [else (check-eqv? got want)]))

(test-host-probe "the echo job returns every input it was given"
  (define r (host-resources))
  (for ([inputs (in-list echo-cases)])
    (define outputs (call-with-values (lambda () (apply probe-echo-job 'demo r inputs)) list))
    (check-equal? (length outputs) 10)
    (for-each check-same outputs inputs)))

(define echo-zeros (list 0 0 0 0 0 0 0 0 0.0 0.0))

(test-host-probe "a value its slot cannot hold raises a contract error naming the job"
  (define r (host-resources))
  (define in-flight (jobs-in-flight))
  (drain-finalizers!)
  (define live (jobs-live))
  (for ([refusal (in-list '((2 x "_int32") (4 256 "_uint8") (9 2 "_double") (3 2.0 "_int64")))])
    (match-define (list at value type) refusal)
    (define args (list-set echo-zeros at value))
    (check-exn (lambda (e)
                 (and (exn:fail:contract? e)
                      (regexp-match? #rx"^demo: given value does not fit primitive C type"
                                     (exn-message e))
                      (regexp-match? (regexp-quote (format "C type: ~a" type)) (exn-message e))
                      (not (regexp-match? #rx"ptr-set!" (exn-message e)))))
               (lambda () (apply probe-echo-job 'demo r args))))
  (check-equal? (jobs-in-flight) in-flight)
  (check-equal? (jobs-live) live))

(test-host-probe "_double* converts an exact input"
  (define-job echo*
              probe-library
              "rr_probe_echo_job"
              (_int8 _int16
                     _int32
                     _int64
                     _uint8
                     _uint16
                     _uint32
                     _uint64
                     _float
                     _double*
                     (out _int8)
                     (out _int16)
                     (out _int32)
                     (out _int64)
                     (out _uint8)
                     (out _uint16)
                     (out _uint32)
                     (out _uint64)
                     (out _float)
                     (out _double)))
  (define outputs
    (call-with-values (lambda () (apply echo* 'demo (host-resources) (list-set echo-zeros 9 1/2)))
                      list))
  (check-eqv? (list-ref outputs 9) 0.5))

(test-host-probe "a declaration whose block is the wrong size is refused before the call"
  (define-job short-echo
              probe-library
              "rr_probe_echo_job"
              (_int8 _int16
                     _int32
                     _int64
                     _uint8
                     _uint16
                     _uint32
                     _uint64
                     _float
                     _double
                     (out _int8)
                     (out _int16)
                     (out _int32)
                     (out _int64)
                     (out _uint8)
                     (out _uint16)
                     (out _uint32)
                     (out _uint64)
                     (out _float)))
  (define-job long-echo
              probe-library
              "rr_probe_echo_job"
              (_int8 _int16
                     _int32
                     _int64
                     _uint8
                     _uint16
                     _uint32
                     _uint64
                     _float
                     _double
                     (out _int8)
                     (out _int16)
                     (out _int32)
                     (out _int64)
                     (out _uint8)
                     (out _uint16)
                     (out _uint32)
                     (out _uint64)
                     (out _float)
                     (out _double)
                     _int32))
  (define r (host-resources))
  (probe-tokens-clear!)
  (check-raft-error 'logic
                    "demo: the argument block is 88 bytes; the job expects 96"
                    (lambda () (apply short-echo 'demo r echo-zeros)))
  (check-raft-error 'logic
                    "demo: the argument block is 104 bytes; the job expects 96"
                    (lambda () (apply long-echo 'demo r (append echo-zeros '(0)))))
  (check-equal? (probe-tokens) '()))

(test-host-probe "a failing job raises the kind and message it recorded"
  (define r (host-resources))
  (for ([kind (in-list '(0 1 2 3 9))]
        [expected (in-list '(generic out-of-memory cuda logic generic))])
    (check-raft-error expected "demo: token 7" (lambda () (probe-fail-job 'demo r 7 kind 0)))))

(struct exn:fail:probe exn:fail:raft ())

(test-host-probe "#:exn builds the downstream's own exception"
  (define-job probe-fail-job*
              probe-library
              "rr_probe_fail_job"
              (_int32 _int32 _int32)
              #:exn exn:fail:probe)
  (check-exn (lambda (e)
               (and (exn:fail:probe? e)
                    (equal? (exn-message e) "demo: token 7")
                    (eq? (exn:fail:raft-kind e) 'logic)))
             (lambda () (probe-fail-job* 'demo (host-resources) 7 3 0))))

(test-host-probe "a long message is cut on a character boundary"
  (define message
    (with-handlers ([exn:fail:raft? exn-message])
      (probe-fail-job 'demo (host-resources) 1 3 5000)))
  (check-true (regexp-match? #rx"^demo: token 1 " message))
  (check-false (regexp-match? #rx"\uFFFD" message))
  (check-true (<= (bytes-length (string->bytes/utf-8 (substring message 6))) 4095)))

(define (failures-of resources-for)
  (define callers
    (for/list ([t (in-range 4)])
      (thread (lambda ()
                (define r (resources-for t))
                (for/list ([i (in-range 25)])
                  (with-handlers ([exn:fail:raft? (lambda (e)
                                                    (list (exn:fail:raft-kind e) (exn-message e)))])
                    (probe-fail-job 'demo r (+ (* 100 t) i) (modulo i 4) 0))))
              #:keep 'results)))
  (map thread-wait callers))

(define (expected-failures t)
  (for/list ([i (in-range 25)])
    (list (list-ref '(generic out-of-memory cuda logic) (modulo i 4))
          (format "demo: token ~a" (+ (* 100 t) i)))))

(test-host-probe "concurrent failures on separate workers each raise their own error"
  (for ([got (in-list (failures-of (lambda (_) (host-resources))))]
        [t (in-naturals)])
    (check-equal? got (expected-failures t))))

(test-host-probe "concurrent failures on one worker each raise their own error"
  (define r (host-resources))
  (for ([got (in-list (failures-of (lambda (_) r)))]
        [t (in-naturals)])
    (check-equal? got (expected-failures t))))

(test-host-probe "a break during a failing job wins over the failure"
  (with-release ([g (closed-gate) release-gate])
    (define caller
      (thread (lambda ()
                (with-handlers ([(lambda (_) #t) values])
                  (gate-job 'demo (host-resources) g #:fail-kind 3)))
              #:keep 'results))
    (check-true (await-entry g))
    (break-thread caller)
    (open-gate! g)
    (check-pred exn:break? (thread-wait caller))))

(test-host-probe "a job refuses atomic mode and leaves the process running"
  (define in-flight (jobs-in-flight))
  (define r (host-resources))
  (check-raft-error 'logic
                    "demo: cannot wait for a job in atomic mode"
                    (lambda ()
                      (call-as-atomic (lambda () (apply probe-echo-job 'demo r echo-zeros)))))
  (check-equal? (jobs-in-flight) in-flight))

(test-host-probe "a job refuses released resources"
  (define r (with-device-resources ([r (host-resources)]) r))
  (check-raft-error 'logic
                    "demo: the device resources on device -1 were released"
                    (lambda () (probe-token-job 'demo r 1))))

(test-host-probe "a handle parameter refuses resources without a device"
  (define-job handled probe-library "rr_probe_token_job" (handle _int32))
  (check-raft-error 'logic
                    "demo: the resources have no device"
                    (lambda () (handled 'demo (host-resources) 1)))
  (check-raft-error 'logic
                    "resources->handle-pointer: the resources have no device"
                    (lambda () (resources->handle-pointer (host-resources)))))

(test-host-probe "other Racket threads run during a job"
  (with-release ([g (closed-gate) release-gate])
    (thread (lambda ()
              (let tick ([n 0])
                (cond
                  [(= n 20) (open-gate! g)]
                  [else
                   (sleep 0.01)
                   (tick (add1 n))]))))
    (check-equal? (gate-job 'demo (host-resources) g) 1)))

(test-host-probe "each resources object has its own worker thread"
  (define r1 (host-resources))
  (define r2 (host-resources))
  (define tid (probe-thread-id-job 'demo r1))
  (check-equal? (probe-thread-id-job 'demo r1) tid)
  (check-not-equal? tid (call/probe 'tid rr-probe-thread-id))
  (check-not-equal? (probe-thread-id-job 'demo r2) tid))

(test-host-probe "jobs on one resources object run one at a time"
  (define r (host-resources))
  (with-release ([ga (closed-gate) release-gate] [gb (closed-gate) release-gate])
    (define a (thread (lambda () (gate-job 'demo r ga)) #:keep 'results))
    (check-true (await-entry ga))
    (open-gate! gb)
    (define b (thread (lambda () (gate-job 'demo r gb)) #:keep 'results))
    (check-true (await-in-flight 2))
    (check-false (await-entry gb 0.2))
    (open-gate! ga)
    (check-equal? (thread-wait a) 1)
    (check-true (await-entry gb))
    (check-equal? (thread-wait b) 1)))

(test-host-probe "jobs on one resources object run in submission order"
  (define r (host-resources))
  (probe-tokens-clear!)
  (with-release ([g (closed-gate) release-gate])
    (define held (thread (lambda () (gate-job 'demo r g))))
    (check-true (await-entry g))
    (define tokens
      (for/list ([token (in-list '(1 2 3))])
        (define t (thread (lambda () (probe-token-job 'demo r token))))
        (check-true (await-in-flight (add1 token)))
        t))
    (open-gate! g)
    (for-each thread-wait (cons held tokens))
    (check-equal? (probe-tokens) '(1 2 3))))

(test-host-probe "jobs on two resources objects run in parallel"
  (with-release ([g1 (closed-gate) release-gate] [g2 (closed-gate) release-gate])
    (define callers
      (for/list ([g (in-list (list g1 g2))])
        (thread (lambda () (gate-job 'demo (host-resources) g)))))
    (check-true (await-entry g1))
    (check-true (await-entry g2))
    (open-gate! g1)
    (open-gate! g2)
    (for-each thread-wait callers)))

(test-host-probe "jobs-in-flight counts running and queued jobs"
  (define r (host-resources))
  (check-equal? (jobs-in-flight) 0)
  (with-release ([g (closed-gate) release-gate])
    (define held (thread (lambda () (gate-job 'demo r g))))
    (check-true (await-entry g))
    (check-equal? (jobs-in-flight) 1)
    (define queued (thread (lambda () (probe-token-job 'demo r 1))))
    (check-true (await-in-flight 2))
    (open-gate! g)
    (for-each thread-wait (list held queued)))
  (check-equal? (jobs-in-flight) 0)
  (with-handlers ([exn:fail:raft? void])
    (probe-fail-job 'demo r 1 3 0))
  (check-equal? (jobs-in-flight) 0)
  (with-release ([g (closed-gate) release-gate])
    (define caller
      (thread (lambda ()
                (with-handlers ([exn:break? void])
                  (gate-job 'demo r g)))))
    (check-true (await-entry g))
    (break-thread caller)
    (open-gate! g)
    (thread-wait caller))
  (check-equal? (jobs-in-flight) 0))

(test-host-probe "a break during a job is raised once the job returns"
  (with-release ([g (closed-gate) release-gate])
    (define opened (box #f))
    (define caller
      (thread (lambda ()
                (with-handlers ([exn:break? (lambda (_) (list 'broken (unbox opened)))])
                  (gate-job 'demo (host-resources) g)))
              #:keep 'results))
    (check-true (await-entry g))
    (break-thread caller)
    (check-false (sync/timeout 0.2 caller))
    (set-box! opened #t)
    (open-gate! g)
    (check-equal? (thread-wait caller) '(broken #t))))

(test-host-probe "with breaks disabled a break stays pending past the job"
  (with-release ([g (closed-gate) release-gate])
    (define events (box '()))
    (define (record! event)
      (set-box! events (cons event (unbox events))))
    (define caller
      (thread (lambda ()
                (with-handlers ([exn:break? (lambda (_) (record! 'broken))])
                  (parameterize-break #f (gate-job 'demo (host-resources) g) (record! 'returned))
                  (sync never-evt)))))
    (check-true (await-entry g))
    (break-thread caller)
    (check-false (sync/timeout 0.2 caller))
    (open-gate! g)
    (thread-wait caller)
    (check-equal? (unbox events) '(broken returned))))

(test-host-probe "a killed caller's job lives until it returns"
  (drain-finalizers!)
  (define live (jobs-live))
  (with-release ([g (closed-gate) release-gate])
    (define caller (thread (lambda () (gate-job 'demo (host-resources) g))))
    (check-true (await-entry g))
    (kill-thread caller)
    (drain-finalizers!)
    (check-equal? (jobs-in-flight) 1)
    (check-equal? (jobs-live) (add1 live))
    (open-gate! g)
    (check-true (collect-until (lambda () (and (= (jobs-in-flight) 0) (= (jobs-live) live)))))))

(test-host-probe "a killed caller's queued job still runs"
  (define r (host-resources))
  (probe-tokens-clear!)
  (with-release ([g (closed-gate) release-gate])
    (define held (thread (lambda () (gate-job 'demo r g))))
    (check-true (await-entry g))
    (define queued (thread (lambda () (probe-token-job 'demo r 9))))
    (check-true (await-in-flight 2))
    (kill-thread queued)
    (open-gate! g)
    (thread-wait held)
    (check-true (collect-until (lambda () (= (jobs-in-flight) 0))))
    (check-equal? (probe-tokens) '(9))))

(test-host-probe "a thousand jobs leave no job, descriptor or thread behind"
  (drain-finalizers!)
  (define live (jobs-live))
  (define fds (open-fds))
  (define threads (settled-threads))
  (define r (host-resources))
  (for ([_ (in-range 1000)])
    (apply probe-echo-job 'demo r echo-zeros))
  (drain-finalizers!)
  (check-equal? (jobs-live) live)
  (check-equal? (open-fds) fds)
  (check-equal? (executor-threads) (add1 threads))
  (void/reference-sink r))

(test-host-probe "a worker ends with its resources"
  (define threads (settled-threads))
  (define drops (resources-drop-count))
  (for ([_ (in-range 20)])
    (with-device-resources ([r (host-resources)])
      (probe-token-job 'demo r 1)))
  (check-true (collect-until (lambda () (= (executor-threads) threads))))
  (check-equal? (resources-drop-count) (+ drops 20)))

(test-host-probe "released resources finish the work already queued"
  (define threads (settled-threads))
  (probe-tokens-clear!)
  (with-release ([g (closed-gate) release-gate])
    (define-values (held queued)
      (with-device-resources ([r (host-resources)])
        (define held (thread (lambda () (gate-job 'demo r g)) #:keep 'results))
        (check-true (await-entry g))
        (define queued (thread (lambda () (probe-token-job 'demo r 5))))
        (check-true (await-in-flight 2))
        (values held queued)))
    (open-gate! g)
    (check-equal? (thread-wait held) 1)
    (thread-wait queued)
    (check-equal? (probe-tokens) '(5))
    (check-true (collect-until (lambda () (= (executor-threads) threads))))))

(test-host-probe "a thousand jobs take under two seconds"
  (define r (host-resources))
  (define start (current-inexact-monotonic-milliseconds))
  (for ([_ (in-range 1000)])
    (apply probe-echo-job 'demo r echo-zeros))
  (check-true (< (- (current-inexact-monotonic-milliseconds) start) 2000)))

(test-probe "a killed caller's arrays and resources live until its job returns"
  (define (counts)
    (list (buffer-drop-count) (resources-drop-count) (release-failure-count)))
  (with-release ([g (closed-gate) release-gate])
    (define caller
      (thread (lambda ()
                (define r (device-resources))
                (probe-hold-views-job 'demo
                                      r
                                      (gate-entered-fd g)
                                      (gate-fd g)
                                      (device-matrix 3 4 #:resources r)
                                      (device-vector 5 #:resources r)))))
    (check-true (await-entry g))
    (drain-finalizers!)
    (match-define (and before (list buffers-before _ _)) (counts))
    (kill-thread caller)
    (drain-finalizers!)
    (match-define (list buffers-after _ _) (counts))
    (check-equal? buffers-after buffers-before)
    (open-gate! g)
    (check-true (collect-until (lambda () (equal? (map - (counts) before) '(2 1 0)))))))

(test-probe "a job binds each array's view"
  (define r (device-resources))
  (with-release ([g (closed-gate) release-gate])
    (open-gate! g)
    (check-equal? (probe-hold-views-job 'demo
                                        r
                                        (gate-entered-fd g)
                                        (gate-fd g)
                                        (device-matrix 3 4 #:resources r)
                                        (device-vector 5 #:resources r))
                  17)
    (check-equal? (probe-hold-views-job 'demo
                                        r
                                        (gate-entered-fd g)
                                        (gate-fd g)
                                        (device-matrix 3 4 #:resources r)
                                        #f)
                  12)))

(test-probe "each thread's default resources has its own worker"
  (define threads (settled-threads))
  (with-release ([g1 (closed-gate) release-gate] [g2 (closed-gate) release-gate])
    (define callers
      (for/list ([g (in-list (list g1 g2))])
        (thread (lambda ()
                  (define r (current-device-resources))
                  (list r (gate-job 'demo r g) (probe-thread-id-job 'demo r)))
                #:keep 'results)))
    (check-true (await-entry g1))
    (check-true (await-entry g2))
    (open-gate! g1)
    (open-gate! g2)
    (match-define (list (list r1 _ tid1) (list r2 _ tid2)) (map thread-wait callers))
    (check-false (eq? r1 r2))
    (check-not-equal? tid1 tid2)
    (for ([_ (in-range 20)])
      (thread-wait (thread (lambda () (probe-thread-id-job 'demo (current-device-resources))))))
    (drain-finalizers!)
    (check-true (collect-until (lambda () (= (executor-threads) threads))))))
