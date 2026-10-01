#lang racket/base

(require (only-in racket/list make-list remove-duplicates)
         (only-in racket/match match-define)
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
         (only-in "private/gpu.rkt" test-gpu))

(define (printed v)
  (format "~a" v))

(define (raft-message thunk)
  (with-handlers ([exn:fail:raft? exn-message])
    (thunk)
    #f))

(define (released-message who)
  (format "~a: the device resources on device 0 were released" who))

(define (missing-device-message who n)
  (format "~a: rr_resources_create: no device ~a among ~a" who n (device-count)))

(test-gpu "getting started: the driver sees a GPU"
  (check-pred exact-positive-integer? (device-count)))

(test-gpu "resources guide: finding the GPU"
  (define (check-device wanted)
    (unless (< wanted (device-count))
      (error 'check-device "GPU ~a requested, but only ~a visible" wanted (device-count)))
    wanted)
  (check-equal? (check-device 0) 0)
  (check-exn (regexp (format "^check-device: GPU 4 requested, but only ~a visible$" (device-count)))
             (lambda () (check-device 4))))

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
  (check-equal? (length (remove-duplicates (cons (current-device-resources) used) eq?)) 4))

(test-gpu "resources guide: waiting for the GPU"
  (define (timed r thunk)
    (define start (current-inexact-milliseconds))
    (define result (thunk))
    (resources-sync! r)
    (values result (- (current-inexact-milliseconds) start)))
  (define-values (answer ms) (timed (current-device-resources) (lambda () 42)))
  (check-equal? (list answer (< ms 1000.0)) '(42 #t)))

(test-gpu "resources guide: when something goes wrong"
  (define (try-device d)
    (with-handlers ([exn:fail:raft?
                     (lambda (e) (list (exn:fail:raft-kind e) (exn-message e)))])
      (resources-device (device-resources #:device d))))
  (check-equal? (try-device 0) 0)
  (check-equal? (try-device 12) (list 'logic (missing-device-message 'device-resources 12)))
  (define finished (with-device-resources ([r (device-resources)]) r))
  (check-equal? (printed finished) "#<device-resources device 0 released>")
  (check-equal? (raft-message (lambda () (resources-sync! finished)))
                (released-message 'resources-sync!)))

(test-gpu "reference: device-resources"
  (define r (device-resources))
  (check-equal? (printed r) "#<device-resources device 0>")
  (check-equal? (resources-device r) 0)
  (define loader (device-resources))
  (define trainer (device-resources))
  (check-false (eq? loader trainer))
  (check-equal? (map resources-device (list loader trainer)) '(0 0))
  (check-equal? (raft-message (lambda () (device-resources #:device (device-count))))
                (missing-device-message 'device-resources (device-count)))
  (define (resources-for wanted)
    (device-resources #:device (if (< wanted (device-count)) wanted 0)))
  (check-equal? (resources-device (resources-for 3)) 0))

(test-gpu "reference: device-resources?"
  (define loader (device-resources))
  (define trainer (device-resources))
  (check-true (device-resources? (current-device-resources)))
  (check-false (device-resources? 0))
  (define (resources-or-default maybe-resources)
    (if (device-resources? maybe-resources)
        maybe-resources
        (current-device-resources)))
  (check-true (eq? (resources-or-default #f) (current-device-resources)))
  (check-true (eq? (resources-or-default loader) loader))
  (define settings (list 'batch-size 256 loader 'verbose trainer))
  (check-equal? (length (filter device-resources? settings)) 2))

(test-gpu "reference: resources-device"
  (define loader (device-resources))
  (define trainer (device-resources))
  (check-equal? (resources-device (current-device-resources)) 0)
  (define (tag-with-device r result)
    (cons (format "cuda:~a" (resources-device r)) result))
  (check-equal? (tag-with-device trainer 'loss-0.42) '("cuda:0" . loss-0.42))
  (define pool (list loader trainer (current-device-resources)))
  (check-equal? (for/fold ([by-device (hasheqv)])
                          ([r (in-list pool)])
                  (hash-update by-device (resources-device r) add1 0))
                (hasheqv 0 3)))

(test-gpu "reference: resources-sync!"
  (define trainer (device-resources))
  (check-equal? (resources-sync! (current-device-resources)) (void))
  (define (milliseconds-on r thunk)
    (define start (current-inexact-milliseconds))
    (thunk)
    (resources-sync! r)
    (- (current-inexact-milliseconds) start))
  (check-true (< (milliseconds-on trainer void) 1000.0))
  (define waiter (thread (lambda () (resources-sync! trainer))))
  (thread-wait waiter)
  (check-true (thread-dead? waiter))
  (define finished (with-device-resources ([r (device-resources)]) r))
  (check-equal? (raft-message (lambda () (resources-sync! finished)))
                (released-message 'resources-sync!)))

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
  (check-equal? (raft-message (lambda () (resources-sync! left)))
                (released-message 'resources-sync!)))

(test-gpu "reference: device-count"
  (check-pred exact-positive-integer? (device-count))
  (define (pick-device wanted)
    (if (< wanted (device-count)) wanted 0))
  (check-equal? (pick-device 0) 0)
  (check-equal? (pick-device 7) (if (< 7 (device-count)) 7 0))
  (define per-device
    (for/list ([d (in-range (device-count))])
      (device-resources #:device d)))
  (check-equal? (map resources-device per-device) (for/list ([d (in-range (device-count))]) d)))

(test-gpu "reference: exn:fail:raft"
  (define missing
    (with-handlers ([exn:fail:raft? values])
      (device-resources #:device (device-count))))
  (check-equal? (exn-message missing) (missing-device-message 'device-resources (device-count)))
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
  (define finished (with-device-resources ([r (device-resources)]) r))
  (check-equal? (with-handlers ([exn:fail:raft?
                                 (lambda (e)
                                   (match-define (list who _ ...)
                                     (string-split (exn-message e) ": "))
                                   who)])
                  (resources-sync! finished))
                "resources-sync!"))
