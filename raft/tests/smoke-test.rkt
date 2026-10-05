#lang racket/base

(require (only-in racket/flonum flvector in-flvector)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path
         (only-in rackunit check-equal? check-true)
         (only-in "../main.rkt" raft-version)
         (only-in "../private/error.rkt" call/raft)
         (only-in "../private/foreign/core.rkt" rr-resources-sync)
         (only-in "../private/foreign/memory.rkt" rr-buffer-free rr-resources-free)
         (only-in "../private/resource.rkt" with-release)
         (only-in "private/gpu.rkt" test-gpu)
         (only-in "private/native.rkt" copy-in! copy-out new-buffer new-resources)
         (only-in "private/python-env.rkt" check-close run-twin test-twin))

(define-runtime-path twin "python/round_trip.py")

(define (round-trip xs)
  (define n (length xs))
  (with-release ([resources (new-resources) rr-resources-free]
                 [buffer (new-buffer resources (* 8 n)) rr-buffer-free])
    (copy-in! buffer (apply flvector xs))
    (for/list ([x (in-flvector (copy-out buffer n))]) x)))

(define values-in '(1.5 -2.25 0.0 3.0 1e300 -1e-300 0.1 123456789.0))

(test-gpu "a list of flonums comes back unchanged"
  (check-equal? (round-trip values-in) values-in))

(test-gpu "special values survive the trip bit for bit"
  (define specials (list -0.0 +inf.0 -inf.0 +nan.0 4.9406564584124654e-324))
  (check-equal? (round-trip specials) specials))

(test-gpu "resources synchronize their stream"
  (with-release ([resources (new-resources) rr-resources-free])
    (check-true (call/raft 'sync (lambda () (rr-resources-sync resources))))))

(test-gpu "an empty list is an empty trip"
  (check-equal? (round-trip '()) '()))

(test-twin "the round trip matches pylibraft's device_ndarray"
  (define twin-result (run-twin twin (hasheq 'values values-in)))
  (check-equal? (hash-ref twin-result 'version)
                (raft-version)
                "the twin runs the RAPIDS release the shim links")
  (check-close (round-trip values-in) (hash-ref twin-result 'values)))
