#lang racket/base

(require (only-in rackunit check-equal? check-false check-true)
         (only-in "../main.rkt" current-device-resources)
         (only-in "../private/dtype.rkt" dtype->code)
         (only-in "../private/job.rkt" define-job jobs-in-flight jobs-live)
         (only-in "../private/resource.rkt" with-release)
         (only-in "../unsafe.rkt" deposit deposit->list with-deposits)
         (only-in "private/collect.rkt" collect-until drain-finalizers!)
         (only-in "private/deposits.rkt"
                  check-pattern
                  check-round-trips
                  counters
                  counts
                  counts-holders
                  released-once
                  since)
         (only-in "private/gate.rkt"
                  await-entry
                  closed-gate
                  gate-entered-fd
                  gate-fd
                  open-gate!
                  release-gate)
         (only-in "private/probe.rkt"
                  probe-deposit-after-gate-job
                  probe-deposit-job
                  probe-flags
                  probe-library
                  test-probe)
         (only-in "private/raft-error.rkt" check-raft-error))

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
  (check-raft-error 'logic
                    "with-deposits: the deposit is closed"
                    (lambda () (with-deposits ([o d]) o)))
  (check-pattern (deposit->list d) 'float32 3 4)
  (define in-flight (jobs-in-flight))
  (check-raft-error 'logic "demo: the deposit is closed" (lambda () (deposit-job d 'float32 3 4)))
  (check-equal? (jobs-in-flight) in-flight)
  (define failed (deposit))
  (check-raft-error 'logic
                    "demo: failed after filling"
                    (lambda () (deposit-job failed 'float32 3 4 #:flags (probe-flags 'fail-after))))
  (check-raft-error 'logic
                    "with-deposits: the deposit is closed"
                    (lambda () (with-deposits ([o failed]) o)))
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
  (define in-flight (jobs-in-flight))
  (define live (jobs-live))
  (check-raft-error 'logic
                    "demo: the deposit is closed"
                    (lambda () (two-deposits 'demo (current-device-resources) earlier spent)))
  (check-raft-error 'logic
                    "with-deposits: the deposit is closed"
                    (lambda () (with-deposits ([o earlier]) o)))
  (check-equal? (list (jobs-in-flight) (jobs-live)) (list in-flight live)))

(define (gated-deposit-job g d dt #:resources r)
  (probe-deposit-after-gate-job 'demo r (gate-entered-fd g) (gate-fd g) d (dtype->code dt) 2 3 4 0))

(define (settled-jobs)
  (check-true (collect-until (lambda () (zero? (jobs-in-flight))))))

(test-probe "law 47: a killed caller's deposit job fills it, or releases it once (#22 law 8)"
  (define r (current-device-resources))
  (define retained (deposit))
  (with-release ([g (closed-gate) release-gate])
    (define caller (thread (lambda () (gated-deposit-job g retained 'int64 #:resources r))))
    (check-true (await-entry g))
    (kill-thread caller)
    (check-raft-error 'logic
                      "with-deposits: the deposit is already bound"
                      (lambda () (with-deposits ([out retained]) out)))
    (open-gate! g)
    (settled-jobs))
  (check-pattern (deposit->list retained) 'int64 3 4)
  (released-once
   "unretained"
   (lambda ()
     (define before (counters))
     (with-release ([g (closed-gate) release-gate])
       (define lost
         (thread (lambda () (gated-deposit-job g (deposit #:resources r) 'float32 #:resources r))))
       (check-true (await-entry g))
       (kill-thread lost)
       (for ([_ (in-range 3)])
         (collect-garbage 'major))
       (drain-finalizers!)
       (check-equal? (counts-holders (since before)) 0 "held across the killed call")
       (open-gate! g)
       (settled-jobs)))
   (counts 1 1 1 0 0)))

(test-probe "law 48: a major collection or a break during a gated deposit job (#22 law 9)"
  (define r (current-device-resources))
  (define d (deposit))
  (with-release ([g (closed-gate) release-gate])
    (define caller (thread (lambda () (gated-deposit-job g d 'float64 #:resources r))))
    (check-true (await-entry g))
    (for ([_ (in-range 3)])
      (collect-garbage 'major))
    (open-gate! g)
    (thread-wait caller))
  (check-pattern (deposit->list d) 'float64 3 4)
  (define broken (deposit))
  (with-release ([g (closed-gate) release-gate])
    (define breaking
      (thread (lambda ()
                (with-handlers ([exn:break? (lambda (_) 'broken)])
                  (gated-deposit-job g broken 'float32 #:resources r)
                  'returned))
              #:keep 'results))
    (check-true (await-entry g))
    (break-thread breaking)
    (check-false (sync/timeout 0.2 breaking))
    (open-gate! g)
    (check-equal? (thread-wait breaking) 'broken))
  (check-raft-error 'logic
                    "with-deposits: the deposit is closed"
                    (lambda () (with-deposits ([out broken]) out)))
  (check-pattern (deposit->list broken) 'float32 3 4))
