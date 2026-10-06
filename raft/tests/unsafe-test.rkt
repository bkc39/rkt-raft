#lang racket/base

(require (only-in ffi/unsafe _int32 _int64 cpointer? ptr-equal? ptr-ref)
         (only-in racket/generator in-generator yield)
         (only-in rackunit
                  check-equal?
                  check-exn
                  check-false
                  check-not-false
                  check-pred
                  check-true
                  test-case)
         (only-in syntax/macro-testing convert-syntax-error)
         (only-in "../main.rkt"
                  current-device-resources
                  device-matrix
                  device-resources
                  device-vector
                  exn:fail:raft
                  exn:fail:raft-kind
                  list*->device-matrix
                  raft-abi
                  with-device-resources)
         (only-in "../private/array.rkt" release-array!)
         (only-in "../private/foreign/array.rkt"
                  view-data
                  view-device
                  view-dtype-code
                  view-shape
                  view-strides)
         (only-in "../private/foreign/memory.rkt" buffer-drop-count)
         (only-in "../private/resource.rkt" with-release)
         (only-in "../private/resources.rkt" resources-handle)
         (only-in "../unsafe.rkt"
                  raft-abi-pointer
                  resources->handle-pointer
                  status-checker
                  with-array-views)
         (only-in "private/collect.rkt" drain-finalizers!)
         (only-in "private/gpu.rkt" test-gpu)
         (only-in "private/probe.rkt" probe-hold! probe-release! test-probe)
         (only-in "private/raft-error.rkt" check-raft-error))

(test-case "raft-abi-pointer points at the tag raft-abi reads"
  (define tag (raft-abi-pointer))
  (check-pred cpointer? tag)
  (check-true (ptr-equal? tag (raft-abi-pointer)))
  (define abi (raft-abi))
  (check-equal? (ptr-ref tag _int32 0) (hash-ref abi 'abi-version))
  (check-equal? (ptr-ref tag _int64 6) (hash-ref abi 'handle-size)))

(test-gpu "resources->handle-pointer answers the same handle for the same resources"
  (define r (device-resources))
  (define handle (resources->handle-pointer r))
  (check-pred cpointer? handle)
  (check-true (ptr-equal? handle (resources->handle-pointer r)))
  (check-false (ptr-equal? handle (resources->handle-pointer (device-resources)))))

(test-gpu "resources->handle-pointer refuses released resources, naming itself"
  (define r (with-device-resources ([r (device-resources)]) r))
  (check-raft-error 'logic
                    "resources->handle-pointer: the device resources on device 0 were released"
                    (lambda () (resources->handle-pointer r))))

(test-gpu "with-array-views binds each array's view in the body"
  (define X (list*->device-matrix '((1 2 3) (4 5 6)) #:dtype 'float32 #:layout 'col-major))
  (define y (device-vector 4 #:dtype 'int64))
  (with-array-views ([x X] [v y])
    (check-not-false (view-data x))
    (check-equal? (list (view-dtype-code x) (view-shape x) (view-strides x) (view-device x))
                  '(0 (2 3) (1 2) 0))
    (check-equal? (list (view-dtype-code v) (view-shape v) (view-strides v)) '(3 (4) (1)))))

(test-gpu "with-array-views binds #f to #f, for optional arrays"
  (check-equal? (with-array-views ([w #f] [x (device-vector 3)])
                  (list w (and x #t)))
                '(#f #t)))

(test-gpu "with-array-views answers its body's values"
  (define-values (a b)
    (with-array-views ([x (device-vector 3)])
      (values 1 2)))
  (check-equal? (list a b) '(1 2)))

(test-gpu "a view that escapes the body is cleared"
  (define escaped (with-array-views ([x (device-vector 3)]) x))
  (check-false (view-data escaped))
  (check-equal? (view-device escaped) -1))

(test-gpu "with-array-views keeps an array reachable until the body ends"
  (drain-finalizers!)
  (define before (buffer-drop-count))
  (with-array-views ([x (device-matrix 64 64)])
    (drain-finalizers!)
    (check-equal? (buffer-drop-count) before "the array lives while its view is bound")
    (check-not-false (view-data x)))
  (drain-finalizers!)
  (check-equal? (buffer-drop-count) (add1 before) "and is freed once the body ends"))

(test-gpu "a generator resuming with-array-views raises instead of binding again"
  (check-raft-error 'logic
                    "with-array-views: cannot re-enter its body after its resources were released"
                    (lambda ()
                      (for/list ([v (in-generator (with-array-views ([x (device-vector 2)])
                                                    (yield x)
                                                    (yield x)))])
                        v))))

(test-gpu "with-array-views refuses a released array"
  (define a (device-vector 3))
  (release-array! a)
  (check-raft-error 'logic
                    "device-array: used after its release"
                    (lambda () (with-array-views ([x a]) x))))

(test-case "a name bound twice is a syntax error"
  (check-exn #rx"duplicate binding name"
             (lambda () (convert-syntax-error (with-array-views ([a #f] [a #f]) a)))))

(test-probe "with-array-views waits for work queued on the array's stream"
  (define r (device-resources))
  (define a (device-vector 8 #:resources r))
  (define entered (box #f))
  (define released (box #f))
  (define worker
    (with-release ([held
                    (probe-hold! (resources-handle 'hold r))
                    (lambda (_)
                      (set-box! released (current-inexact-milliseconds))
                      (probe-release!))])
      (check-true held)
      (define body-thread
        (thread (lambda ()
                  (with-array-views ([x a])
                    (set-box! entered (current-inexact-milliseconds))))))
      (check-false (sync/timeout 0.2 body-thread) "the body waits while the stream is held")
      (check-false (unbox entered))
      body-thread))
  (check-not-false (sync/timeout 10 worker))
  (check-true (>= (unbox entered) (unbox released))))

(define (checker . failure)
  (status-checker (lambda () (car failure)) (lambda () (cadr failure))))

(test-case "status-checker answers the values after a zero status"
  (define check (checker #"unused" 0))
  (define-values (a b) (check 'demo (lambda () (values 0 'a 'b))))
  (check-equal? (list a b) '(a b))
  (check-equal? (call-with-values (lambda () (check 'demo (lambda () 0))) list) '()))

(test-case "status-checker raises exn:fail:raft with the library's message and kind"
  (check-raft-error 'logic
                    "kmeans-fit: X: expected float32"
                    (lambda () ((checker #"X: expected float32" 3) 'kmeans-fit (lambda () 1))))
  (check-raft-error 'out-of-memory
                    "fit: pool exhausted"
                    (lambda () ((checker "pool exhausted" 1) 'fit (lambda () (values 2 'ignored)))))
  (check-raft-error 'generic "fit: odd" (lambda () ((checker #"odd" 9) 'fit (lambda () 1))))
  (check-raft-error 'cuda
                    "fit: bad � byte"
                    (lambda () ((checker #"bad \377 byte" 'cuda) 'fit (lambda () 1)))))

(struct exn:fail:canary exn:fail:raft ())

(test-case "status-checker builds a downstream's own exception"
  (define check (status-checker (lambda () #"refused") (lambda () 3) #:exn exn:fail:canary))
  (check-exn (lambda (e)
               (and (exn:fail:canary? e)
                    (equal? (exn-message e) "blobs: refused")
                    (eq? (exn:fail:raft-kind e) 'logic)))
             (lambda () (check 'blobs (lambda () 1)))))

(test-case "status-checker reads the error only after a failure"
  (define reads 0)
  (define check
    (status-checker (lambda ()
                      (set! reads (add1 reads))
                      #"")
                    (lambda () 0)))
  (check 'demo (lambda () 0))
  (check-equal? reads 0))

(test-gpu "the handle pointer and views of the default resources work together"
  (define r (current-device-resources))
  (define handle (resources->handle-pointer r))
  (with-array-views ([x (device-vector 5 #:resources r)])
    (check-pred cpointer? handle)
    (check-pred cpointer? x)))
