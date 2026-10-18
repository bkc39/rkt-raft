#lang racket/base

(require (only-in ffi/unsafe _fun _int _uint64 define-cstruct get-ffi-obj)
         (only-in racket/list make-list)
         (only-in rackunit check-equal? check-exn check-false check-true test-case)
         (only-in "../../main.rkt" current-device-resources)
         (only-in "../../private/deposit.rkt" call-with-deposits-bound)
         (only-in "../../private/dtype.rkt" dtype->code)
         (only-in "../../private/job.rkt" define-job jobs-in-flight jobs-live)
         (only-in "../../private/resource.rkt" with-release)
         (only-in "../../private/resources.rkt" host-resources)
         (only-in "../../unsafe.rkt" deposit deposit->list with-deposits)
         (only-in "../private/collect.rkt" collect-until drain-finalizers!)
         (only-in "../private/deposits.rkt"
                  call-with-gated-job
                  check-deposit-closed
                  check-pattern
                  check-round-trips
                  counters
                  counts
                  counts-holders
                  released-once
                  since)
         (only-in "../private/gate.rkt" closed-gate gate-entered-fd gate-fd open-gate! release-gate)
         (only-in "../private/probe.rkt"
                  probe-deposit-after-gate-job
                  probe-deposit-before-gate-job
                  probe-deposit-job
                  probe-flags
                  probe-library
                  probe-sleep-job
                  test-host-probe
                  test-probe
                  with-hold-timeout)
         (only-in "../private/raft-error.rkt" check-raft-error))

(define (deposit-job d dt rows cols #:count [k 2] #:flags [flags 0])
  (probe-deposit-job 'demo (current-device-resources) d (dtype->code dt) k rows (or cols -1) flags))

(define (job-filled dt rows cols #:count [k 2] #:flags [flags 0])
  (define d (deposit))
  (deposit-job d dt rows cols #:count k #:flags flags)
  d)

(test-probe "law 43: every dtype and shape round-trips through a deposit job"
  (check-round-trips job-filled))

(test-probe "law 44: a job closes its deposit"
  (define d (job-filled 'float32 3 4))
  (check-deposit-closed d)
  (check-pattern (deposit->list d) 'float32 3 4)
  (define in-flight (jobs-in-flight))
  (check-raft-error 'logic "demo: the deposit is closed" (lambda () (deposit-job d 'float32 3 4)))
  (check-equal? (jobs-in-flight) in-flight)
  (define failed (deposit))
  (check-raft-error 'logic
                    "demo: failed after filling"
                    (lambda () (deposit-job failed 'float32 3 4 #:flags (probe-flags 'fail-after))))
  (check-deposit-closed failed)
  (check-pattern (deposit->list failed) 'float32 3 4)
  (define twice (deposit))
  (check-raft-error 'logic
                    "demo: out: already filled"
                    (lambda () (deposit-job twice 'int32 3 4 #:flags (probe-flags 'twice))))
  (check-pattern (deposit->list twice) 'int32 3 4))

(test-probe "law 45: a job refuses a deposit another binding holds"
  (define d (deposit))
  (with-deposits ([o d])
                 (check-raft-error 'logic
                                   "demo: the deposit is already bound"
                                   (lambda () (deposit-job d 'float32 3 4)))))

(test-probe "law 46: a failed binding closes the deposits bound before it"
  (define-job two-deposits probe-library "rr_probe_token_job" (deposit deposit))
  (define earlier (deposit))
  (define spent (deposit))
  (with-deposits ([o spent]) o)
  (check-true (collect-until (lambda () (and (zero? (jobs-in-flight)) (zero? (jobs-live)))))
              "a job of an earlier law is still alive")
  (check-raft-error 'logic
                    "demo: the deposit is closed"
                    (lambda () (two-deposits 'demo (current-device-resources) earlier spent)))
  (check-deposit-closed earlier)
  (check-equal? (list (jobs-in-flight) (jobs-live)) '(0 0)))

(test-probe "law 46: a submit that raises or escapes closes the deposits bound for it"
  (define raised (deposit))
  (check-exn #rx"^submit refused$"
             (lambda ()
               (call-with-deposits-bound 'demo
                                         (list raised)
                                         (lambda (_records _holders) (error "submit refused")))))
  (check-deposit-closed raised)
  (define escaped (deposit))
  (let/ec escape
    (call-with-deposits-bound 'demo (list escaped) (lambda (_records _holders) (escape 'escaped))))
  (check-deposit-closed escaped)
  (define submitted (deposit))
  (call-with-deposits-bound 'demo
                            (list submitted)
                            (lambda (records holders)
                              (check-equal? (map length (list records holders)) '(1 1))))
  (check-raft-error 'logic
                    "with-deposits: the deposit is already bound"
                    (lambda () (with-deposits ([o submitted]) o))))

(test-probe "law 46: a break during a submit closes the deposits bound for it"
  (define broken (deposit))
  (check-exn exn:break?
             (lambda ()
               (call-with-deposits-bound 'demo
                                         (list broken)
                                         (lambda (_records _holders)
                                           (break-thread (current-thread))
                                           (sleep 0)))))
  (check-deposit-closed broken))

(define ((gated job d dt #:resources [r (current-device-resources)]) g)
  (job 'demo r (gate-entered-fd g) (gate-fd g) d (dtype->code dt) 2 3 4 0))

(define (settled-jobs)
  (check-true (collect-until (lambda () (zero? (jobs-in-flight))))))

(test-probe "law 47: a killed caller's deposit job fills a deposit still referenced (#22 law 8)"
  (define retained (deposit))
  (call-with-gated-job (gated probe-deposit-after-gate-job retained 'int64)
                       (lambda (g caller)
                         (kill-thread caller)
                         (check-raft-error 'logic
                                           "with-deposits: the deposit is already bound"
                                           (lambda () (with-deposits ([out retained]) out)))
                         (open-gate! g)
                         (settled-jobs)))
  (check-pattern (deposit->list retained) 'int64 3 4))

(test-probe "law 47: a killed caller's deposit job releases a dropped deposit once (#22 law 8)"
  (define r (current-device-resources))
  (define (dropped-deposit-job)
    (define before (counters))
    (define cell (box (deposit #:resources r)))
    (define collected (make-weak-box (unbox cell)))
    (define (start g)
      (define d (unbox cell))
      (set-box! cell #f)
      ((gated probe-deposit-after-gate-job d 'float32 #:resources r) g))
    (call-with-gated-job
     start
     (lambda (g caller)
       (kill-thread caller)
       (drain-finalizers!)
       (check-false (weak-box-value collected) "the deposit was not collected")
       (check-equal? (counts-holders (since before)) 0 "held across the killed call")
       (open-gate! g)
       (settled-jobs))))
  (released-once "unretained" dropped-deposit-job (counts 1 1 1 0 0)))

(test-probe "law 48: a major collection during a gated deposit job (#22 law 9)"
  (define d (deposit))
  (call-with-gated-job (gated probe-deposit-after-gate-job d 'float64)
                       (lambda (g caller)
                         (for ([_ (in-range 3)])
                           (collect-garbage 'major))
                         (open-gate! g)
                         (thread-wait caller)))
  (check-pattern (deposit->list d) 'float64 3 4))

(test-probe "law 48: a break during a gated deposit job (#22 law 9)"
  (define broken (deposit))
  (define job (gated probe-deposit-after-gate-job broken 'float32))
  (define (breakable g)
    (with-handlers ([exn:break? (lambda (_) 'broken)])
      (job g)
      'returned))
  (call-with-gated-job breakable
                       (lambda (g caller)
                         (break-thread caller)
                         (check-false (sync/timeout 0.2 caller))
                         (open-gate! g)
                         (check-equal? (thread-wait caller) 'broken)))
  (check-deposit-closed broken)
  (check-pattern (deposit->list broken) 'float32 3 4))

(test-probe "law 104: a deposit job's arrays are adopted only after the job closes the deposit"
  (define d (deposit))
  (define job (gated probe-deposit-before-gate-job d 'int32))
  (call-with-gated-job (lambda (g)
                         (job g)
                         'returned)
                       (lambda (g caller)
                         (check-raft-error 'logic
                                           "deposit->list: the deposit is still open"
                                           (lambda () (deposit->list d)))
                         (open-gate! g)
                         (check-equal? (thread-wait caller) 'returned)))
  (check-pattern (deposit->list d) 'int32 3 4))

(test-probe "a deposit job whose gate stays closed fails once the probe's hold times out"
  (define d (deposit))
  (define start (current-inexact-monotonic-milliseconds))
  (with-release ([g (closed-gate) release-gate])
    (with-hold-timeout 100
                       (check-raft-error 'generic
                                         "demo: gate timed out"
                                         (lambda ()
                                           ((gated probe-deposit-after-gate-job d 'float32) g)))))
  (define waited (- (current-inexact-monotonic-milliseconds) start))
  (check-true (< waited 2000) (format "the job waited ~a ms for its gate" waited))
  (check-deposit-closed d))

(define rlimit-nofile 7)
(define descriptor-limit 256)

(define-cstruct _rlimit
  ([cur _uint64]
   [max _uint64]))

(define getrlimit (get-ffi-obj "getrlimit" #f (_fun _int _rlimit-pointer -> _int)))
(define setrlimit (get-ffi-obj "setrlimit" #f (_fun _int _rlimit-pointer -> _int)))

(define (open-until-refused)
  (let loop ([ports '()])
    (define port
      (with-handlers ([exn:fail:filesystem? (lambda (_e) #f)])
        (open-input-file "/dev/null")))
    (if port
        (loop (cons port ports))
        ports)))

(define (exhausting-limit saved)
  (min descriptor-limit (rlimit-cur saved) (rlimit-max saved)))

(test-case "the exhausting limit never raises the soft or the hard limit"
  (check-equal? (exhausting-limit (make-rlimit 512 200)) 200)
  (check-equal? (exhausting-limit (make-rlimit 100 4096)) 100)
  (check-equal? (exhausting-limit (make-rlimit 4096 4096)) descriptor-limit))

(define (warm-job-closed? live)
  (for/or ([pause (in-list (cons 0 (make-list 500 0.01)))])
    (sleep pause)
    (<= (jobs-live) live)))

(define (warm! resources)
  (define live (jobs-live))
  (probe-sleep-job 'warm resources 0)
  (check-true (warm-job-closed? live) "the warm job was never freed"))

(define (call-with-descriptors-exhausted thunk)
  (define saved (make-rlimit 0 0))
  (check-equal? (getrlimit rlimit-nofile saved) 0)
  (define ports '())
  (dynamic-wind (lambda ()
                  (check-equal? (setrlimit rlimit-nofile
                                           (make-rlimit (exhausting-limit saved) (rlimit-max saved)))
                                0)
                  (set! ports (open-until-refused)))
                thunk
                (lambda ()
                  (for-each close-input-port ports)
                  (check-equal? (setrlimit rlimit-nofile saved) 0))))

(test-host-probe "a job that cannot be submitted for want of a descriptor raises 'generic"
  (define r (host-resources))
  (warm! r)
  (call-with-descriptors-exhausted
   (lambda ()
     (check-raft-error 'generic #rx"^demo: eventfd: " (lambda () (probe-sleep-job 'demo r 0))))))

(test-probe "a deposit job that cannot be submitted for want of a descriptor closes its deposit"
  (warm! (current-device-resources))
  (define d (deposit))
  (call-with-descriptors-exhausted
   (lambda ()
     (check-raft-error 'generic #rx"^demo: eventfd: " (lambda () (deposit-job d 'float32 3 4)))))
  (check-deposit-closed d))
