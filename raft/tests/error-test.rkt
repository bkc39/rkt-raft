#lang racket/base

(require (only-in ffi/vector f64vector f64vector->cpointer)
         (only-in rackunit check-equal? check-exn check-pred test-case)
         (only-in "../private/error.rkt" call/raft exn:fail:raft-kind exn:fail:raft?)
         (only-in "../private/foreign/array.rkt" rr-buffer-alloc rr-copy-h2d)
         (only-in "../private/foreign/core.rkt" rr-device-count rr-resources-create)
         (only-in "../private/foreign/memory.rkt" rr-buffer-free rr-resources-free)
         (only-in "private/gpu.rkt" gpu-available? skip test-gpu))

(define (raised thunk)
  (with-handlers ([exn:fail:raft? values])
    (thunk)
    #f))

(test-case "a successful call answers its result"
  (check-equal? (call/raft 'answer (lambda () 42)) 42))

(test-gpu "a refused call raises exn:fail:raft naming the caller and the cause"
  (define e (raised (lambda () (call/raft 'open-device (lambda () (rr-resources-create 4096))))))
  (check-pred exn:fail:raft? e)
  (check-equal? (exn:fail:raft-kind e) 'logic)
  (check-pred (lambda (m) (regexp-match? #rx"^open-device: rr_resources_create: no device 4096 among [0-9]+$" m))
              (exn-message e)))

(if (gpu-available?)
    (skip "a GPU is present" "without a driver, device calls are CUDA errors")
    (test-case "without a driver, device calls are CUDA errors"
      (define e (raised (lambda () (call/raft 'count (lambda () (rr-device-count))))))
      (check-pred exn:fail:raft? e)
      (check-equal? (exn:fail:raft-kind e) 'cuda)))

(test-gpu "an impossible allocation is out of memory"
  (define resources (call/raft 'oom (lambda () (rr-resources-create 0))))
  (define e (raised (lambda ()
                      (call/raft 'oom (lambda () (rr-buffer-alloc resources (expt 2 52)))))))
  (check-pred exn:fail:raft? e)
  (check-equal? (exn:fail:raft-kind e) 'out-of-memory)
  (rr-resources-free resources))

(test-gpu "a copy that does not fit is refused before it runs"
  (define resources (call/raft 'copy (lambda () (rr-resources-create 0))))
  (define buffer (call/raft 'copy (lambda () (rr-buffer-alloc resources 8))))
  (check-exn #rx"^copy: rr_copy_h2d: 16 bytes do not fit a buffer of 8 bytes$"
             (lambda ()
               (call/raft 'copy
                          (lambda ()
                            (rr-copy-h2d buffer (f64vector->cpointer (f64vector 1.0 2.0)) 16)))))
  (rr-buffer-free buffer)
  (rr-resources-free resources))

(test-gpu "the error read belongs to the call that failed"
  (define stop (box #f))
  (define noise
    (for/list ([_ (in-range 4)])
      (thread (lambda ()
                (let loop ()
                  (unless (unbox stop)
                    (call/raft 'noise rr-device-count)
                    (loop)))))))
  (for ([_ (in-range 500)])
    (check-exn #rx"^probe: rr_resources_create: no device 4096"
               (lambda () (call/raft 'probe (lambda () (rr-resources-create 4096))))))
  (set-box! stop #t)
  (for-each thread-wait noise))
