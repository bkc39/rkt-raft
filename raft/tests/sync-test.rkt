#lang racket/base

(require (only-in rackunit check-equal? check-false check-not-false check-true)
         (only-in "../main.rkt" current-device-resources device-resources resources-sync!)
         (only-in "../private/resource.rkt" with-release)
         (only-in "../private/resources.rkt" resources-handle)
         (only-in "private/gpu.rkt" test-gpu)
         (only-in "private/probe.rkt" probe-hold! probe-release! test-probe))

(define (held-stream r thunk)
  (with-release ([held (probe-hold! (resources-handle 'hold r)) (lambda (_) (probe-release!))])
    (check-true held "the probe queued its hold")
    (thunk)))

(test-gpu "resources-sync! returns at once on an idle stream"
  (check-equal? (resources-sync! (current-device-resources)) (void))
  (check-equal? (resources-sync! (device-resources)) (void)))

(test-probe "resources-sync! waits until the stream drains"
  (define r (device-resources))
  (define waiter
    (held-stream r
                 (lambda ()
                   (define waiter (thread (lambda () (resources-sync! r))))
                   (check-false (sync/timeout 0.2 waiter) "the sync waits while the stream is held")
                   waiter)))
  (check-not-false (sync/timeout 10 waiter) "the sync returns once the stream drains"))

(test-probe "a break ends a waiting sync, and the program runs meanwhile"
  (define r (device-resources))
  (define outcome (box 'waiting))
  (held-stream
   r
   (lambda ()
     (define waiter
       (thread (lambda ()
                 (with-handlers ([exn:break? (lambda (_) (set-box! outcome 'broken))])
                   (resources-sync! r)
                   (set-box! outcome 'synced)))))
     (check-false (sync/timeout 0.2 waiter))
     (collect-garbage 'major)
     (check-true (thread-running? waiter) "a major collection finished while the sync waited")
     (break-thread waiter)
     (check-not-false (sync/timeout 5 waiter) "the break reached the waiting thread")))
  (check-equal? (unbox outcome) 'broken)
  (check-equal? (resources-sync! r) (void)))
