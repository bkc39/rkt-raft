#lang racket/base

(require (only-in racket/match match-define)
         (only-in rackunit
                  check-eq?
                  check-equal?
                  check-exn
                  check-false
                  check-pred
                  check-regexp-match
                  check-true)
         (only-in "../main.rkt"
                  current-device-resources
                  device-count
                  device-resources
                  device-resources?
                  exn:fail:raft-kind
                  exn:fail:raft?
                  resources-device
                  resources-sync!
                  with-device-resources)
         (only-in "../private/foreign/memory.rkt" resources-drop-count)
         (only-in "private/collect.rkt" collect-until)
         (only-in "private/gpu.rkt" test-gpu test-without-gpu)
         (only-in "private/python-env.rkt" run-twin test-twin)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path)

(define-runtime-path device-count-twin "python/device_count.py")

(define (in-new-thread thunk)
  (define answer (make-channel))
  (thread (lambda () (channel-put answer (thunk))))
  (channel-get answer))

(define (raised thunk)
  (with-handlers ([exn:fail:raft? values])
    (thunk)
    #f))

(define (check-raft-error e kind pattern)
  (check-pred exn:fail:raft? e)
  (check-equal? (exn:fail:raft-kind e) kind)
  (check-regexp-match pattern (exn-message e)))

(test-gpu "a thread asking twice gets the same default resources"
  (check-pred device-resources? (current-device-resources))
  (check-eq? (current-device-resources) (current-device-resources))
  (check-eq? (current-device-resources 0) (current-device-resources)))

(test-gpu "each thread gets its own default resources"
  (define mine (current-device-resources))
  (define theirs (in-new-thread current-device-resources))
  (check-pred device-resources? theirs)
  (check-false (eq? mine theirs)))

(test-gpu "a new thread does not inherit its parent's default"
  (define parent (current-device-resources))
  (match-define (list first second)
    (in-new-thread (lambda () (list (current-device-resources) (current-device-resources)))))
  (check-eq? first second)
  (check-false (eq? parent first)))

(test-gpu "resources record their device"
  (check-equal? (resources-device (device-resources)) 0)
  (check-equal? (resources-device (device-resources #:device 0)) 0)
  (check-equal? (resources-device (current-device-resources)) 0))

(test-gpu "constructed resources are new every time"
  (check-false (eq? (device-resources) (device-resources)))
  (check-false (eq? (device-resources) (current-device-resources))))

(test-gpu "with-device-resources frees on return"
  (define before (resources-drop-count))
  (check-equal? (with-device-resources ([r (device-resources)])
                  (resources-device r))
                0)
  (check-equal? (resources-drop-count) (add1 before)))

(test-gpu "with-device-resources frees on a raise"
  (define before (resources-drop-count))
  (check-exn #rx"boom"
             (lambda ()
               (with-device-resources ([r (device-resources)])
                 (error 'job "boom"))))
  (check-equal? (resources-drop-count) (add1 before)))

(test-gpu "with-device-resources frees on an escape"
  (define before (resources-drop-count))
  (check-equal? (let/ec leave
                  (with-device-resources ([r (device-resources)])
                    (leave 'left)))
                'left)
  (check-equal? (resources-drop-count) (add1 before)))

(test-gpu "with-device-resources frees every binding once"
  (define before (resources-drop-count))
  (with-device-resources ([a (device-resources)]
                          [b (device-resources)])
    (check-false (eq? a b)))
  (check-equal? (resources-drop-count) (+ before 2)))

(test-gpu "releasing resources twice frees them once"
  (define before (resources-drop-count))
  (with-device-resources ([outer (device-resources)])
    (with-device-resources ([inner outer])
      (resources-sync! inner)))
  (check-equal? (resources-drop-count) (add1 before)))

(test-gpu "a binding may name an outer variable of the same name"
  (define before (resources-drop-count))
  (define r (device-resources))
  (with-device-resources ([r r])
    (check-pred device-resources? r))
  (check-equal? (resources-drop-count) (add1 before)))

(test-gpu "unreachable resources are freed by their finalizer"
  (define before (resources-drop-count))
  (for ([_ (in-range 3)])
    (device-resources))
  (check-true (collect-until (lambda () (>= (resources-drop-count) (+ before 3))))))

(test-gpu "released resources raise exn:fail:raft naming the call"
  (define r (with-device-resources ([r (device-resources)]) r))
  (check-raft-error (raised (lambda () (resources-sync! r)))
                    'logic
                    #rx"^resources-sync!: the device resources on device 0 were released$")
  (check-equal? (resources-device r) 0))

(test-gpu "a released default is replaced on the next request"
  (define first (current-device-resources))
  (with-device-resources ([r first])
    (resources-sync! r))
  (define second (current-device-resources))
  (check-false (eq? first second))
  (check-eq? second (current-device-resources))
  (check-equal? (resources-sync! second) (void)))

(test-gpu "resources print their device and whether they were released"
  (define r (device-resources))
  (check-equal? (format "~a" r) "#<device-resources device 0>")
  (with-device-resources ([r r])
    (void))
  (check-equal? (format "~a" r) "#<device-resources device 0 released>"))

(test-gpu "device-count counts the visible devices"
  (check-pred exact-positive-integer? (device-count)))

(test-twin "device-count agrees with CuPy"
  (check-equal? (device-count) (hash-ref (run-twin device-count-twin (hasheq)) 'devices)))

(test-gpu "a missing device is a logic error naming the caller"
  (define n (device-count))
  (check-raft-error (raised (lambda () (device-resources #:device n)))
                    'logic
                    (regexp (format "^device-resources: rr_resources_create: no device ~a among ~a$"
                                    n n)))
  (check-raft-error (raised (lambda () (current-device-resources n)))
                    'logic
                    #rx"^current-device-resources: rr_resources_create: no device")
  (check-raft-error (raised (lambda () (device-resources #:device -1)))
                    'logic
                    #rx"^device-resources: rr_resources_create: no device -1 among"))

(test-without-gpu "without a driver, device-count raises a CUDA error"
  (check-raft-error (raised device-count) 'cuda #rx"^device-count: cudaGetDeviceCount: "))
