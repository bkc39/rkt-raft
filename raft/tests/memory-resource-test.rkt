#lang racket/base

(require (only-in rackunit check-equal? check-true)
         (only-in "../main.rkt" current-device-resources device-count resources-sync!)
         (only-in "../private/foreign/memory.rkt" rr-buffer-free)
         (only-in "../private/resource.rkt" with-release)
         (only-in "../private/resources.rkt" memory-resource-kind resources-handle)
         (only-in "private/gpu.rkt" test-gpu)
         (only-in "private/native.rkt" new-buffer)
         (only-in "private/probe.rkt" probe-current-is-async? probe-pool-used test-pools)
         (only-in "private/raft-error.rkt" check-raft-error))

(define mebibyte (expt 2 20))

(test-pools "the default memory resource is RMM's CUDA async pool"
  (current-device-resources)
  (check-equal? (memory-resource-kind 0) 'cuda-async)
  (check-equal? (memory-resource-kind) 'cuda-async))

(test-gpu "asking about a missing device is a logic error"
  (check-raft-error 'logic
                    #rx"^memory-resource-kind: no device"
                    (lambda () (memory-resource-kind (device-count)))))

(test-pools "a second library sees the pool raft installed"
  (current-device-resources)
  (check-true (probe-current-is-async? 0)))

(test-pools "buffers raft allocates come from the pool the second library sees"
  (define r (current-device-resources))
  (resources-sync! r)
  (define before (probe-pool-used 0))
  (check-true (>= before 0) "the second library reads the pool's statistics")
  (with-release ([buffer (new-buffer (resources-handle 'alloc r) mebibyte) rr-buffer-free])
    (resources-sync! r)
    (check-true (>= (probe-pool-used 0) (+ before mebibyte))
                "the allocation shows in the pool the second library sees"))
  (resources-sync! r)
  (check-true (< (probe-pool-used 0) (+ before mebibyte)) "the free returns it to the pool"))
