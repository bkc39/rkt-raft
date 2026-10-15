#lang racket/base

(require (only-in racket/generator in-generator yield)
         (only-in racket/match match-define)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path
         (only-in rackunit
                  check-eq?
                  check-equal?
                  check-exn
                  check-false
                  check-pred
                  check-true
                  test-case)
         (only-in syntax/macro-testing convert-syntax-error)
         (only-in "../main.rkt"
                  current-device-resources
                  device-count
                  device-resources
                  device-resources?
                  resources-device
                  resources-sync!
                  with-device-resources)
         (only-in "../private/foreign/memory.rkt" resources-drop-count)
         (only-in "private/collect.rkt" collect-until drain-finalizers!)
         (only-in "private/gpu.rkt" test-gpu test-without-gpu)
         (only-in "private/python-env.rkt" run-twin test-twin)
         (only-in "private/raft-error.rkt" check-raft-error))

(define-runtime-path device-count-twin "python/device_count.py")

(define (call-in-new-thread thunk)
  (define answer (make-channel))
  (thread (lambda () (channel-put answer (thunk))))
  (channel-get answer))

(define (drops-during thunk)
  (drain-finalizers!)
  (define before (resources-drop-count))
  (thunk)
  (- (resources-drop-count) before))

(test-gpu "a thread asking twice gets the same default resources"
  (check-pred device-resources? (current-device-resources))
  (check-eq? (current-device-resources) (current-device-resources))
  (check-eq? (current-device-resources 0) (current-device-resources)))

(test-gpu "each thread gets its own default resources"
  (define mine (current-device-resources))
  (define theirs (call-in-new-thread current-device-resources))
  (check-pred device-resources? theirs)
  (check-false (eq? mine theirs)))

(test-gpu "a new thread does not inherit its parent's default"
  (define parent (current-device-resources))
  (match-define (list first second)
    (call-in-new-thread (lambda () (list (current-device-resources) (current-device-resources)))))
  (check-eq? first second)
  (check-false (eq? parent first)))

(test-gpu "a parallel thread gets its own default too"
  (define mine (current-device-resources))
  (define answer (make-channel))
  (thread #:pool 'own (lambda () (channel-put answer (current-device-resources))))
  (check-false (eq? mine (channel-get answer))))

(test-gpu "a finished thread's default is freed after a collection"
  (drain-finalizers!)
  (define before (resources-drop-count))
  (for ([_ (in-range 3)])
    (thread-wait (thread (lambda () (resources-sync! (current-device-resources))))))
  (check-true (collect-until (lambda () (>= (resources-drop-count) (+ before 3))))))

(test-gpu "resources record their device"
  (check-equal? (resources-device (device-resources)) 0)
  (check-equal? (resources-device (device-resources #:device 0)) 0)
  (check-equal? (resources-device (current-device-resources)) 0))

(test-gpu "constructed resources are new every time"
  (check-false (eq? (device-resources) (device-resources)))
  (check-false (eq? (device-resources) (current-device-resources))))

(test-gpu "with-device-resources frees on return"
  (check-equal? (drops-during (lambda ()
                                (check-equal? (with-device-resources ([r (device-resources)])
                                                (resources-device r))
                                              0)))
                1))

(test-gpu "with-device-resources frees on a raise"
  (check-equal? (drops-during (lambda ()
                                (check-exn #rx"boom"
                                           (lambda ()
                                             (with-device-resources ([r (device-resources)])
                                               (error 'job "boom"))))))
                1))

(test-gpu "with-device-resources frees on an escape"
  (check-equal? (drops-during (lambda ()
                                (check-equal? (let/ec leave
                                                (with-device-resources ([r (device-resources)])
                                                  (leave 'left)))
                                              'left)))
                1))

(test-gpu "with-device-resources frees every binding once"
  (check-equal? (drops-during (lambda ()
                                (with-device-resources ([a (device-resources)] [b (device-resources)])
                                  (check-false (eq? a b)))))
                2))

(test-gpu "releasing resources twice frees them once"
  (check-equal? (drops-during (lambda ()
                                (with-device-resources ([outer (device-resources)])
                                  (with-device-resources ([inner outer])
                                    (resources-sync! inner)))))
                1))

(test-gpu "a binding may name an outer variable of the same name"
  (check-equal? (drops-during (lambda ()
                                (define r (device-resources))
                                (with-device-resources ([r r])
                                  (check-pred device-resources? r))))
                1))

(test-gpu "a later binding sees the earlier ones"
  (with-device-resources ([a (device-resources)] [b (device-resources #:device (resources-device a))])
    (check-equal? (resources-device b) (resources-device a))))

(test-gpu "a generator resuming with-device-resources raises instead of acquiring again"
  (define acquired 0)
  (define (acquire!)
    (set! acquired (add1 acquired))
    (device-resources))
  (check-equal?
   (drops-during
    (lambda ()
      (check-raft-error
       'logic
       "with-device-resources: cannot re-enter its body after its resources were released"
       (lambda ()
         (for/list ([r (in-generator (with-device-resources ([r (acquire!)])
                                       (yield r)
                                       (yield r)))])
           r)))))
   1
   "the yield released the one handle")
  (check-equal? acquired 1 "no second handle was acquired"))

(test-case "a name bound twice is a syntax error"
  (check-exn #rx"duplicate binding name"
             (lambda ()
               (convert-syntax-error
                (with-device-resources ([a (device-resources)] [a (device-resources)]) a)))))

(test-gpu "unreachable resources are freed by their finalizer"
  (drain-finalizers!)
  (define before (resources-drop-count))
  (for ([_ (in-range 3)])
    (device-resources))
  (check-true (collect-until (lambda () (>= (resources-drop-count) (+ before 3))))))

(test-gpu "released resources raise exn:fail:raft naming the call"
  (define r (with-device-resources ([r (device-resources)]) r))
  (check-raft-error 'logic
                    "resources-sync!: the device resources on device 0 were released"
                    (lambda () (resources-sync! r)))
  (check-equal? (resources-device r) 0)
  (check-pred device-resources? r))

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
  (check-raft-error 'logic
                    (format "device-resources: no device ~a among ~a" n n)
                    (lambda () (device-resources #:device n)))
  (check-raft-error 'logic
                    #rx"^current-device-resources: no device"
                    (lambda () (current-device-resources n)))
  (check-raft-error 'logic
                    #rx"^device-resources: no device -1 among"
                    (lambda () (device-resources #:device -1))))

(test-without-gpu "without a driver, device-count raises a CUDA error"
  (check-raft-error 'cuda #rx"^device-count: cudaGetDeviceCount: " device-count))
