#lang racket/base

(require (only-in racket/flonum flvector in-flvector)
         (only-in rackunit check-equal? check-exn check-pred check-true)
         (only-in "../private/error.rkt" exn:fail:raft-kind exn:fail:raft?)
         (only-in "../private/foreign/memory.rkt"
                  buffer-drop-count
                  release-failure-count
                  resources-drop-count
                  rr-buffer-free
                  rr-resources-free)
         (only-in "../private/resource.rkt" with-release)
         (only-in "private/collect.rkt" collect-until)
         (only-in "private/gpu.rkt" test-gpu)
         (only-in "private/native.rkt" copy-in! copy-out new-buffer new-resources))

(define (raised thunk)
  (with-handlers ([exn:fail:raft? values])
    (thunk)
    #f))

(test-gpu "an explicit free releases once and cancels the finalizer"
  (with-release ([resources (new-resources) rr-resources-free])
    (define before (buffer-drop-count))
    (rr-buffer-free (new-buffer resources 64))
    (check-equal? (buffer-drop-count) (add1 before))
    (collect-until (lambda () #f))
    (check-equal? (buffer-drop-count) (add1 before))))

(test-gpu "an unreachable buffer is released by its finalizer"
  (with-release ([resources (new-resources) rr-resources-free])
    (define before (buffer-drop-count))
    (for ([_ (in-range 10)])
      (new-buffer resources 256))
    (check-true (collect-until (lambda () (>= (buffer-drop-count) (+ before 10))))
                "ten dropped buffers reach the native free")))

(test-gpu "unreachable resources are released by their finalizer"
  (define before (resources-drop-count))
  (for ([_ (in-range 3)])
    (new-resources))
  (check-true (collect-until (lambda () (>= (resources-drop-count) (+ before 3))))))

(test-gpu "a buffer keeps its stream alive after its resources are freed"
  (define resources (new-resources))
  (with-release ([buffer (new-buffer resources 16) rr-buffer-free])
    (copy-in! buffer (flvector 2.0 4.0))
    (rr-resources-free resources)
    (check-equal? (for/list ([x (in-flvector (copy-out buffer 2))])
                    x)
                  '(2.0 4.0))))

(test-gpu "a second release does nothing and a released handle cannot be used"
  (define resources (new-resources))
  (define buffer (new-buffer resources 8))
  (define before (buffer-drop-count))
  (rr-buffer-free buffer)
  (rr-buffer-free buffer)
  (check-equal? (buffer-drop-count) (add1 before))
  (define after-buffer (raised (lambda () (copy-in! buffer (flvector 1.0)))))
  (check-pred exn:fail:raft? after-buffer)
  (check-equal? (exn:fail:raft-kind after-buffer) 'logic)
  (check-equal? (exn-message after-buffer) "device-array: used after its release")
  (rr-resources-free resources)
  (rr-resources-free resources)
  (define after-resources (raised (lambda () (new-buffer resources 8))))
  (check-pred exn:fail:raft? after-resources)
  (check-equal? (exn-message after-resources) "device-resources: used after its release"))

(test-gpu "releasing a handle as the wrong type raises and keeps it alive"
  (with-release ([resources (new-resources) rr-resources-free])
    (define before (resources-drop-count))
    (check-exn #rx"rr-buffer" (lambda () (rr-buffer-free resources)))
    (check-equal? (resources-drop-count) before)
    (with-release ([buffer (new-buffer resources 8) rr-buffer-free])
      (copy-in! buffer (flvector 1.0))
      (check-equal? (for/list ([x (in-flvector (copy-out buffer 1))]) x) '(1.0)))))

(test-gpu "with-release after an explicit release frees once"
  (with-release ([resources (new-resources) rr-resources-free])
    (define before (buffer-drop-count))
    (with-release ([buffer (new-buffer resources 8) rr-buffer-free])
      (rr-buffer-free buffer))
    (check-equal? (buffer-drop-count) (add1 before))))

(test-gpu "no release failed"
  (collect-until (lambda () #f))
  (check-equal? (release-failure-count) 0))
