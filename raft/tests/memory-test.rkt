#lang racket/base

(require (only-in ffi/vector f64vector f64vector->list)
         (only-in rackunit check-equal? check-exn check-true)
         (only-in "../private/foreign/memory.rkt"
                  buffer-drop-count
                  release-failure-count
                  resources-drop-count
                  rr-buffer-free
                  rr-resources-free)
         (only-in "../private/resource.rkt" with-release)
         (only-in "private/gpu.rkt" test-gpu)
         (only-in "private/native.rkt" copy-in! copy-out new-buffer new-resources))

(define (collect-until done?)
  (for/or ([_ (in-range 50)])
    (collect-garbage 'major)
    (sync (system-idle-evt))
    (done?)))

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
    (copy-in! buffer (f64vector 2.0 4.0))
    (rr-resources-free resources)
    (check-equal? (f64vector->list (copy-out buffer 2)) '(2.0 4.0))))

(test-gpu "a second release does nothing and a released handle cannot be used"
  (define resources (new-resources))
  (define buffer (new-buffer resources 8))
  (define before (buffer-drop-count))
  (rr-buffer-free buffer)
  (rr-buffer-free buffer)
  (check-equal? (buffer-drop-count) (add1 before))
  (check-exn #rx"rr-buffer" (lambda () (copy-in! buffer (f64vector 1.0))))
  (rr-resources-free resources)
  (rr-resources-free resources)
  (check-exn #rx"rr-resources" (lambda () (new-buffer resources 8))))

(test-gpu "releasing a handle as the wrong type raises and keeps it alive"
  (with-release ([resources (new-resources) rr-resources-free])
    (define before (resources-drop-count))
    (check-exn #rx"rr-buffer" (lambda () (rr-buffer-free resources)))
    (check-equal? (resources-drop-count) before)
    (with-release ([buffer (new-buffer resources 8) rr-buffer-free])
      (copy-in! buffer (f64vector 1.0)))))

(test-gpu "with-release after an explicit release frees once"
  (with-release ([resources (new-resources) rr-resources-free])
    (define before (buffer-drop-count))
    (with-release ([buffer (new-buffer resources 8) rr-buffer-free])
      (rr-buffer-free buffer))
    (check-equal? (buffer-drop-count) (add1 before))))

(test-gpu "no release failed"
  (collect-until (lambda () #f))
  (check-equal? (release-failure-count) 0))
