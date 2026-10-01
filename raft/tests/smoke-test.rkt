#lang racket/base

(require (only-in ffi/vector f64vector->cpointer f64vector->list list->f64vector make-f64vector)
         (only-in rackunit check-equal?)
         (only-in "../main.rkt" raft-version)
         (only-in "../private/error.rkt" call/raft)
         (only-in "../private/foreign/array.rkt" rr-buffer-alloc rr-copy-d2h rr-copy-h2d)
         (only-in "../private/foreign/core.rkt" rr-resources-create)
         (only-in "../private/foreign/memory.rkt" rr-buffer-free rr-resources-free)
         (only-in "../private/resource.rkt" with-release)
         (only-in "private/gpu.rkt" test-gpu)
         (only-in "private/python-env.rkt" check-close run-twin test-twin)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path)

(define-runtime-path twin "python/round_trip.py")

(define (round-trip xs)
  (define n (length xs))
  (define bytes (* 8 n))
  (with-release ([resources (call/raft 'round-trip (lambda () (rr-resources-create 0)))
                            rr-resources-free]
                 [buffer (call/raft 'round-trip (lambda () (rr-buffer-alloc resources bytes)))
                         rr-buffer-free])
    (define host (list->f64vector xs))
    (call/raft 'round-trip (lambda () (rr-copy-h2d buffer (f64vector->cpointer host) bytes)))
    (define back (make-f64vector n))
    (call/raft 'round-trip (lambda () (rr-copy-d2h (f64vector->cpointer back) buffer bytes)))
    (f64vector->list back)))

(define values-in '(1.5 -2.25 0.0 3.0 1e300 -1e-300 0.1 123456789.0))

(test-gpu "a list of flonums comes back unchanged"
  (check-equal? (round-trip values-in) values-in))

(test-gpu "special values survive the trip bit for bit"
  (define specials (list -0.0 +inf.0 -inf.0 +nan.0 4.9406564584124654e-324))
  (check-equal? (round-trip specials) specials))

(test-gpu "an empty list is an empty trip"
  (check-equal? (round-trip '()) '()))

(test-twin "the round trip matches pylibraft's device_ndarray"
  (define twin-result (run-twin twin (hasheq 'values values-in)))
  (check-equal? (hash-ref twin-result 'version) (raft-version)
                "the twin runs the RAPIDS release the shim links")
  (check-close (round-trip values-in) (hash-ref twin-result 'values)))
