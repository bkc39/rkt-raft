#lang racket/base

(require (only-in rackunit check-true)
         (only-in "../main.rkt" device-resources device-vector)
         (only-in "../private/foreign/memory.rkt" rr-resources-free)
         (only-in "../private/resource.rkt" with-release)
         (only-in "../private/resources.rkt" host-resources resources-handle resources-sync!)
         (only-in "private/gate.rkt" closed-gate gate-entered-fd gate-fd open-gate! release-gate)
         (only-in "private/probe.rkt"
                  probe-hold!
                  probe-hold-views-job
                  probe-release!
                  test-host-probe
                  test-probe)
         (only-in "private/raft-error.rkt" check-raft-error))

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
