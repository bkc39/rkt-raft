#lang racket/base

(require (only-in racket/list make-list range remove-duplicates)
         (only-in racket/match match-define)
         (only-in racket/port with-output-to-string)
         (only-in racket/string string-split)
         (only-in rackunit check-equal? check-exn check-false check-pred check-true)
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
         (only-in "private/collect.rkt" drain-finalizers!)
         (only-in "private/gpu.rkt" test-gpu)
         (only-in "private/raft-error.rkt" check-raft-error))

(define (printed v)
  (format "~a" v))

(define released-message "resources-sync!: the device resources on device 0 were released")

(define (missing-device-message n)
  (format "device-resources: rr_resources_create: no device ~a among ~a" n (device-count)))

(define (released-resources)
  (with-device-resources ([r (device-resources)]) r))

(test-gpu "getting started: the driver sees a GPU"
  (check-pred exact-positive-integer? (device-count)))

(test-gpu "resources guide: finding the GPU"
  (check-pred exact-positive-integer? (device-count))
  (check-raft-error 'logic (missing-device-message 4) (lambda () (device-resources #:device 4))))

(test-gpu "resources guide: the default resources"
  (define r (current-device-resources))
  (check-equal? (printed r) "#<device-resources device 0>")
  (check-equal? (resources-device r) 0)
  (check-true (eq? r (current-device-resources))))

(test-gpu "resources guide: resources for a batch job"
  (define (process-batch rows)
    (with-device-resources ([r (device-resources)])
      (for ([row (in-list rows)])
        (unless (= (length row) 2)
          (error 'process-batch "row ~a has ~a columns" row (length row))))
      (resources-sync! r)
      (length rows)))
  (drain-finalizers!)
  (define before (resources-drop-count))
  (check-equal? (process-batch '((1.0 2.0) (3.0 4.0))) 2)
  (check-exn #rx"^process-batch: row \\(3.0\\) has 1 columns$"
             (lambda () (process-batch '((1.0 2.0) (3.0)))))
  (check-equal? (resources-drop-count) (+ before 2) "both batches released their resources"))

(test-gpu "resources guide: one resources object per worker thread"
  (define (run-workers n job)
    (define results
      (for/list ([i (in-range n)])
        (define done (make-channel))
        (thread (lambda () (channel-put done (job i))))
        done))
    (map channel-get results))
  (define (worker i)
    (define r (current-device-resources))
    (resources-sync! r)
    r)
  (define used (run-workers 3 worker))
  (check-equal? (map printed used) (make-list 3 "#<device-resources device 0>"))
  (define everyone (cons (current-device-resources) used))
  (check-equal? (length (remove-duplicates everyone eq?)) 4))

(test-gpu "resources guide: waiting for the GPU"
  (define (timed r thunk)
    (define start (current-inexact-milliseconds))
    (define result (thunk))
    (resources-sync! r)
    (values result (- (current-inexact-milliseconds) start)))
  (define-values (answer ms) (timed (current-device-resources) (lambda () 42)))
  (check-equal? answer 42)
  (check-true (and (real? ms) (<= 0 ms 1000.0))))

(test-gpu "resources guide: when something goes wrong"
  (define (try-device d)
    (with-handlers ([exn:fail:raft?
                     (lambda (e) (list (exn:fail:raft-kind e) (exn-message e)))])
      (resources-device (device-resources #:device d))))
  (check-equal? (try-device 0) 0)
  (check-equal? (try-device 12) (list 'logic (missing-device-message 12)))
  (define finished (released-resources))
  (check-equal? (printed finished) "#<device-resources device 0 released>")
  (check-raft-error 'logic released-message (lambda () (resources-sync! finished))))

(test-gpu "reference: device-resources"
  (define r (device-resources))
  (check-equal? (printed r) "#<device-resources device 0>")
  (check-equal? (resources-device r) 0)
  (define loader (device-resources))
  (define trainer (device-resources))
  (check-false (eq? loader trainer))
  (check-equal? (map resources-device (list loader trainer)) '(0 0))
  (check-raft-error 'logic
                    (missing-device-message (device-count))
                    (lambda () (device-resources #:device (device-count)))))

(test-gpu "reference: device-resources?"
  (define loader (device-resources))
  (check-true (device-resources? (current-device-resources)))
  (check-false (device-resources? 0))
  (define (as-resources where)
    (if (device-resources? where)
        where
        (current-device-resources where)))
  (check-true (eq? (as-resources 0) (current-device-resources)))
  (check-true (eq? (as-resources loader) loader))
  (check-true (device-resources? (released-resources))))

(test-gpu "reference: resources-device"
  (define loader (device-resources))
  (define trainer (device-resources))
  (check-equal? (resources-device (current-device-resources)) 0)
  (check-equal? (with-output-to-string
                  (lambda () (printf "training on cuda:~a\n" (resources-device trainer))))
                "training on cuda:0\n")
  (define (same-device? a b)
    (= (resources-device a) (resources-device b)))
  (check-true (same-device? loader trainer))
  (check-equal? (resources-device (released-resources)) 0))

(test-gpu "reference: resources-sync!"
  (define trainer (device-resources))
  (check-equal? (resources-sync! (current-device-resources)) (void))
  (define (milliseconds-on r thunk)
    (define start (current-inexact-milliseconds))
    (thunk)
    (resources-sync! r)
    (- (current-inexact-milliseconds) start))
  (check-true (<= 0 (milliseconds-on trainer void) 1000.0))
  (check-equal? (with-output-to-string
                  (lambda ()
                    (thread-wait (thread (lambda ()
                                           (resources-sync! trainer)
                                           (displayln "the trainer's stream has drained"))))))
                "the trainer's stream has drained\n")
  (check-raft-error 'logic released-message (lambda () (resources-sync! (released-resources)))))

(test-gpu "reference: current-device-resources"
  (check-true (eq? (current-device-resources) (current-device-resources)))
  (check-true (eq? (current-device-resources) (current-device-resources 0)))
  (define (worker-resources)
    (define answer (make-channel))
    (thread (lambda () (channel-put answer (current-device-resources))))
    (channel-get answer))
  (define a (worker-resources))
  (define b (worker-resources))
  (check-equal? (list (eq? a b) (eq? a (current-device-resources))) '(#f #f))
  (define before (current-device-resources))
  (with-device-resources ([r before])
    (resources-sync! r))
  (check-equal? (printed before) "#<device-resources device 0 released>")
  (check-false (eq? before (current-device-resources))))

(test-gpu "reference: with-device-resources"
  (check-equal? (with-device-resources ([r (device-resources)])
                  (resources-sync! r)
                  (resources-device r))
                0)
  (define (run-batch items)
    (with-device-resources ([r (device-resources)])
      (for ([item (in-list items)])
        (when (negative? item)
          (error 'run-batch "bad item ~a" item)))
      (resources-sync! r)
      (length items)))
  (check-equal? (run-batch '(1 2 3)) 3)
  (check-exn #rx"^run-batch: bad item -2$" (lambda () (run-batch '(1 -2 3))))
  (define-values (left right)
    (with-device-resources ([left (device-resources)]
                            [right (device-resources)])
      (values left right)))
  (check-equal? (map printed (list left right))
                (make-list 2 "#<device-resources device 0 released>"))
  (check-raft-error 'logic released-message (lambda () (resources-sync! left))))

(test-gpu "reference: device-count"
  (check-pred exact-positive-integer? (device-count))
  (define (device-for-worker i)
    (modulo i (device-count)))
  (check-equal? (map device-for-worker '(0 1 2 3))
                (for/list ([i (in-range 4)]) (modulo i (device-count))))
  (define per-device
    (for/list ([d (in-range (device-count))])
      (device-resources #:device d)))
  (check-equal? (map resources-device per-device) (range (device-count))))

(test-gpu "reference: exn:fail:raft"
  (define missing
    (with-handlers ([exn:fail:raft? values])
      (device-resources #:device (device-count))))
  (check-equal? (exn-message missing) (missing-device-message (device-count)))
  (check-equal? (exn:fail:raft-kind missing) 'logic)
  (define (describe-failure thunk)
    (with-handlers ([exn:fail:raft?
                     (lambda (e)
                       (case (exn:fail:raft-kind e)
                         [(out-of-memory) 'free-memory-and-retry]
                         [(logic) 'fix-the-call]
                         [else 'report]))])
      (thunk)
      'ok))
  (check-equal? (describe-failure (lambda () (current-device-resources))) 'ok)
  (check-equal? (describe-failure (lambda () (device-resources #:device 99))) 'fix-the-call)
  (check-equal? (with-handlers ([exn:fail:raft?
                                 (lambda (e)
                                   (match-define (list who _ ...)
                                     (string-split (exn-message e) ": "))
                                   who)])
                  (resources-sync! (released-resources)))
                "resources-sync!"))
