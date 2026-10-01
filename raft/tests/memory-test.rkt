#lang racket/base

(require (only-in ffi/vector f64vector f64vector->cpointer f64vector->list make-f64vector)
         (only-in rackunit check-equal? check-true)
         (only-in "../private/error.rkt" call/raft)
         (only-in "../private/foreign/array.rkt" rr-buffer-alloc rr-copy-d2h rr-copy-h2d)
         (only-in "../private/foreign/core.rkt" rr-resources-create)
         (only-in "../private/foreign/memory.rkt"
                  buffer-drop-count
                  resources-drop-count
                  rr-buffer-free
                  rr-resources-free)
         (only-in "private/gpu.rkt" test-gpu))

(define (new-resources)
  (call/raft 'memory-test (lambda () (rr-resources-create 0))))

(define (new-buffer resources bytes)
  (call/raft 'memory-test (lambda () (rr-buffer-alloc resources bytes))))

(define (collect-until done?)
  (for/or ([_ (in-range 50)])
    (collect-garbage 'major)
    (sync (system-idle-evt))
    (done?)))

(test-gpu "an explicit free releases once and cancels the finalizer"
  (define resources (new-resources))
  (define before (buffer-drop-count))
  (let ([buffer (new-buffer resources 64)])
    (rr-buffer-free buffer))
  (check-equal? (buffer-drop-count) (add1 before))
  (collect-until (lambda () #f))
  (check-equal? (buffer-drop-count) (add1 before))
  (rr-resources-free resources))

(test-gpu "an unreachable buffer is released by its finalizer"
  (define resources (new-resources))
  (define before (buffer-drop-count))
  (for ([_ (in-range 10)])
    (new-buffer resources 256))
  (check-true (collect-until (lambda () (>= (buffer-drop-count) (+ before 10))))
              "ten dropped buffers reach the native free")
  (rr-resources-free resources))

(test-gpu "unreachable resources are released by their finalizer"
  (define before (resources-drop-count))
  (for ([_ (in-range 3)])
    (new-resources))
  (check-true (collect-until (lambda () (>= (resources-drop-count) (+ before 3))))))

(test-gpu "a buffer keeps its stream alive after its resources are freed"
  (define resources (new-resources))
  (define buffer (new-buffer resources 16))
  (call/raft 'memory-test
             (lambda () (rr-copy-h2d buffer (f64vector->cpointer (f64vector 2.0 4.0)) 16)))
  (rr-resources-free resources)
  (define back (make-f64vector 2))
  (call/raft 'memory-test (lambda () (rr-copy-d2h (f64vector->cpointer back) buffer 16)))
  (check-equal? (f64vector->list back) '(2.0 4.0))
  (rr-buffer-free buffer))
