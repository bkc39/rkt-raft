#lang racket/base

(require (only-in rackunit check-equal? check-true)
         (only-in "../../main.rkt"
                  current-device-resources
                  device-matrix
                  device-matrix->list*
                  device-resources
                  device-vector)
         (only-in "../../private/dtype.rkt" dtype->code)
         (only-in "../../private/foreign/array.rkt" keep-reachable)
         (only-in "../../private/foreign/memory.rkt" buffer-drop-count rr-resources-free)
         (only-in "../../private/resource.rkt" with-release)
         (only-in "../../private/resources.rkt" host-resources resources-handle resources-sync!)
         (only-in "../../unsafe.rkt" device-array-release!)
         (only-in "../private/collect.rkt" drain-finalizers! settled-count)
         (only-in "../private/deposits.rkt" call-with-gated-job)
         (only-in "../private/gate.rkt" closed-gate gate-entered-fd gate-fd open-gate! release-gate)
         (only-in "../private/probe.rkt"
                  probe-deposit-job
                  probe-hold!
                  probe-hold-views-job
                  probe-release!
                  test-host-probe
                  test-probe)
         (only-in "../private/raft-error.rkt" check-raft-error)
         (only-in "../private/synced.rkt" synced?))

(test-host-probe "a view parameter refuses a non-array, naming the job"
  (with-release ([g (closed-gate) release-gate])
    (open-gate! g)
    (check-raft-error 'logic
                      "demo: expected a device array or #f for a view, given 'not-an-array"
                      (lambda ()
                        (probe-hold-views-job 'demo
                                              (host-resources)
                                              (gate-entered-fd g)
                                              (gate-fd g)
                                              'not-an-array
                                              #f)))))

(test-probe "resources released while a view settles are refused, naming the job"
  (define r (device-resources))
  (define held (device-resources))
  (define v (device-vector 4 #:resources held))
  (resources-sync! held)
  (check-true (probe-hold! (resources-handle 'hold held)))
  (thread (lambda ()
            (sleep 0.2)
            (rr-resources-free (resources-handle 'release r))
            (probe-release!)))
  (with-release ([g (closed-gate) release-gate])
    (open-gate! g)
    (check-raft-error 'logic
                      "demo: the device resources on device 0 were released"
                      (lambda ()
                        (probe-hold-views-job 'demo r (gate-entered-fd g) (gate-fd g) v #f)))))

(test-probe "a deposit parameter refuses a non-deposit, naming the job"
  (check-raft-error 'logic
                    "demo: expected a deposit for a deposit parameter, given 'not-a-deposit"
                    (lambda ()
                      (probe-deposit-job 'demo
                                         (current-device-resources)
                                         'not-a-deposit
                                         (dtype->code 'float32)
                                         2
                                         4
                                         -1
                                         0))))

(test-probe "an array released while another view settles is refused, naming the job"
  (define r (device-resources))
  (define held (device-resources))
  (define v1 (device-vector 4 #:resources r))
  (define v (device-vector 4 #:resources held))
  (resources-sync! r)
  (resources-sync! held)
  (check-true (probe-hold! (resources-handle 'hold held)))
  (thread (lambda ()
            (sleep 0.2)
            (device-array-release! v1)
            (probe-release!)))
  (with-release ([g (closed-gate) release-gate])
    (open-gate! g)
    (check-raft-error 'logic
                      "demo: a device array passed to the job was released"
                      (lambda ()
                        (probe-hold-views-job 'demo r (gate-entered-fd g) (gate-fd g) v1 v)))))

(define (held-by-job release?)
  (define x (device-matrix 3 4))
  (drain-finalizers!)
  (define drops (settled-count buffer-drop-count))
  (define elements
    (call-with-gated-job
     (lambda (g)
       (probe-hold-views-job 'demo (current-device-resources) (gate-entered-fd g) (gate-fd g) x #f))
     (lambda (g caller)
       (when release?
         (device-array-release! x)
         (check-raft-error 'logic
                           "device-array: used after its release"
                           (lambda () (device-matrix->list* x)))
         (check-equal? (settled-count buffer-drop-count) drops "freed while the job holds it"))
       (open-gate! g)
       (check-true (synced? caller 30) "the job did not return")
       (thread-wait caller))))
  (begin0 (list elements (- (settled-count buffer-drop-count) drops))
    (keep-reachable x)))

(test-probe "E9b: an array released while a job holds it is refused at once and freed when the job returns"
  (check-equal? (held-by-job #f) '(12 0))
  (check-equal? (held-by-job #t) '(12 1)))
