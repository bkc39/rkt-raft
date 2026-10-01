#lang racket/base

(require (only-in racket/list make-list)
         (only-in rackunit check-equal? check-false check-not-false check-true test-case)
         (only-in "../main.rkt"
                  current-device-resources
                  device-resources
                  resources-sync!
                  with-device-resources)
         (only-in "../private/resource.rkt" with-release)
         (only-in "../private/resources.rkt" in-backoff resources-handle)
         (only-in "private/gpu.rkt" test-gpu)
         (only-in "private/probe.rkt" probe-hold! probe-release! test-probe)
         (only-in "private/raft-error.rkt" check-raft-error))

(define (call-with-held-stream r thunk)
  (with-release ([held (probe-hold! (resources-handle 'hold r)) (lambda (_) (probe-release!))])
    (check-true held "the probe queued its hold")
    (thunk)))

(define (sync-in-thread r outcome)
  (thread (lambda ()
            (with-handlers ([(lambda (_) #t) (lambda (e) (set-box! outcome e))])
              (resources-sync! r)
              (set-box! outcome 'synced)))))

(test-case "the backoff yields, then sleeps longer up to a millisecond"
  (check-equal? (for/list ([pause (in-backoff)]
                           [_ (in-range 26)])
                  pause)
                (append (make-list 16 0.0)
                        (list 1e-5 2e-5 4e-5 8e-5 16e-5 32e-5 64e-5 1e-3 1e-3 1e-3))))

(test-gpu "resources-sync! returns at once on an idle stream"
  (check-equal? (resources-sync! (current-device-resources)) (void))
  (check-equal? (resources-sync! (device-resources)) (void)))

(test-probe "resources-sync! waits until the stream drains"
            (define r (device-resources))
            (define outcome (box 'waiting))
            (define waiter
              (call-with-held-stream r
                                     (lambda ()
                                       (define waiter (sync-in-thread r outcome))
                                       (check-false (sync/timeout 0.2 waiter)
                                                    "the sync waits while the stream is held")
                                       waiter)))
            (check-not-false (sync/timeout 10 waiter) "the sync returns once the stream drains")
            (check-equal? (unbox outcome) 'synced))

(test-probe "a break ends a waiting sync, and the program runs meanwhile"
            (define r (device-resources))
            (define outcome (box 'waiting))
            (call-with-held-stream r
                                   (lambda ()
                                     (define waiter (sync-in-thread r outcome))
                                     (check-false (sync/timeout 0.2 waiter))
                                     (collect-garbage 'major)
                                     (check-true (thread-running? waiter)
                                                 "a major collection finished while the sync waited")
                                     (break-thread waiter)
                                     (check-not-false (sync/timeout 5 waiter)
                                                      "the break reached the waiting thread")))
            (check-true (exn:break? (unbox outcome)))
            (check-equal? (resources-sync! r) (void)))

(test-probe "resources released during a sync end it with exn:fail:raft"
            (define r (device-resources))
            (define outcome (box 'waiting))
            (call-with-held-stream r
                                   (lambda ()
                                     (define waiter (sync-in-thread r outcome))
                                     (check-false (sync/timeout 0.2 waiter))
                                     (with-device-resources ([released r]) (void))
                                     (check-not-false (sync/timeout 5 waiter))))
            (check-raft-error 'logic
                              "resources-sync!: the device resources on device 0 were released"
                              (lambda () (raise (unbox outcome)))))
