#lang racket/base

(require (only-in racket/list permutations take)
         (only-in racket/match match-define)
         (only-in rackunit check-equal? check-true)
         (only-in "../../main.rkt" current-device-resources device-vector->list)
         (only-in "../../private/exn.rkt" exn:fail:raft?)
         (only-in "../../private/foreign/array.rkt" keep-reachable)
         (only-in "../../unsafe.rkt"
                  deposit
                  deposit->device-csr-matrix
                  deposit->list
                  deposit-release!
                  device-array-release!
                  with-deposits)
         (only-in "../private/collect.rkt" drain-finalizers! releases-settled?)
         (only-in "../private/deposits.rkt"
                  check-pattern
                  counters
                  counts
                  fill!
                  filled
                  held
                  in-order
                  released-once
                  since)
         (only-in "../private/probe.rkt" probe-pool-used test-pools test-probe)
         (only-in "../private/raft-error.rkt" check-raft-error)
         (only-in "../private/synced.rkt" synced?))

(define (check-released d)
  (for ([use (in-list (list (lambda () (deposit->list d))
                            (lambda () (deposit->device-csr-matrix d #:shape '(2 2)))
                            (lambda () (with-deposits ([o d]) o))))])
    (check-raft-error 'logic "deposit: used after its release" use)))

(test-probe "E1a: a released deposit refuses deposit->list, its list cached or not"
  (define cached (filled 'float32 3 4))
  (define arrays (deposit->list cached))
  (deposit-release! cached)
  (check-raft-error 'logic "deposit: used after its release" (lambda () (deposit->list cached)))
  (check-pattern arrays 'float32 3 4)
  (define uncached (filled 'float32 3 4))
  (deposit-release! uncached)
  (check-raft-error 'logic "deposit: used after its release" (lambda () (deposit->list uncached))))

(define (step-counts done)
  (define holders (if (memq 'release-deposit done) 1 0))
  (define owner (if (= (length done) 3) 1 0))
  (counts owner owner holders (- (length done) holders) 0))

(test-probe "E2: every order of the three releases frees the owner at the third, exactly once"
  (for ([order (in-list (permutations '(release-deposit (release-array 0) (release-array 1))))])
    (define steps
      (for/list ([what (in-list order)]
                 [i (in-naturals 1)])
        (list what (step-counts (take order i)))))
    (released-once (format "~a" order)
                   (in-order (lambda () (held 'float64)) steps)
                   (counts 1 1 1 2 0))))

(define (released-now label d expected)
  (released-once label
                 (lambda ()
                   (define before (counters))
                   (deposit-release! d)
                   (check-equal? (since before) expected label)
                   (check-released d))
                 expected)
  (keep-reachable d))

(test-probe "E4: a deposit released before adoption frees its owner and refuses every use"
  (released-now "filled" (filled 'float32 3 4) (counts 1 1 1 0 0))
  (released-now "never filled" (deposit) (counts 0 0 1 0 0)))

(test-probe "E5: a second release of each does nothing"
  (define h (held 'int32))
  (released-once "twice"
                 (lambda ()
                   (define before (counters))
                   (for ([_ (in-range 2)])
                     (deposit-release! (hash-ref h 'deposit))
                     (for-each device-array-release! (hash-ref h 'arrays)))
                   (check-equal? (since before) (counts 1 1 1 2 0)))
                 (counts 1 1 1 2 0))
  (keep-reachable h))

(define racers 50)

(test-probe "E7: two threads releasing the same deposits and arrays at once release each once"
  (drain-finalizers!)
  (define before (counters))
  (define hs
    (for/list ([_ (in-range racers)])
      (held 'float32)))
  (define start (make-semaphore 0))
  (define (racer)
    (thread (lambda ()
              (semaphore-wait start)
              (for ([h (in-list hs)])
                (deposit-release! (hash-ref h 'deposit))
                (for-each device-array-release! (hash-ref h 'arrays))))))
  (define threads (list (racer) (racer)))
  (semaphore-post start)
  (semaphore-post start)
  (for ([t (in-list threads)])
    (check-true (synced? t 60) "a releasing thread did not finish"))
  (check-equal? (since before) (counts racers racers racers (* 2 racers) 0))
  (keep-reachable hs))

(define (filler r ds go)
  (thread
   (lambda ()
     (for/fold ([filled 0]
                [refused 0]
                [late '()]
                #:result (list filled refused late))
               ([d (in-list ds)])
       (define entered? #f)
       (semaphore-post go)
       (with-handlers ([exn:fail:raft? (lambda (e)
                                         (if entered?
                                             (values filled refused (cons (exn-message e) late))
                                             (values filled (add1 refused) late)))])
         (fill! d 'float32 3 4 #:resources r #:before (lambda () (set! entered? #t)))
         (values (add1 filled) refused late))))
   #:keep 'results))

(define (releaser ds go)
  (thread (lambda ()
            (for ([d (in-list ds)])
              (sync/timeout 60 go)
              (deposit-release! d)))))

(test-probe "E7b: a release racing with-deposits and its fill frees each holder once, never refused at the close"
  (drain-finalizers!)
  (define before (counters))
  (define ds
    (for/list ([_ (in-range (* 4 racers))])
      (deposit)))
  (define go (make-semaphore 0))
  (define threads (list (filler (current-device-resources) ds go) (releaser ds go)))
  (for ([t (in-list threads)])
    (check-true (synced? t 60) "a racing thread did not finish"))
  (match-define (list filled refused late) (thread-wait (car threads)))
  (check-equal? late '() "refused after binding")
  (check-equal? (+ filled refused) (length ds))
  (check-equal? (since before) (counts filled filled (length ds) 0 0))
  (keep-reachable ds))

(test-probe "E8: a released deposit prints released, and its arrays their values"
  (define d (filled 'int64 7 #f))
  (match-define (list a b) (deposit->list d))
  (define texts (map (lambda (x) (format "~a" x)) (list a b)))
  (deposit-release! d)
  (check-equal? (format "~a" d) "#<deposit device 0 released>")
  (check-equal? (map (lambda (x) (format "~a" x)) (list a b)) texts)
  (check-equal? (device-vector->list a) '(0 1 2 3 4 5 6)))

(define region-elements (* 1024 1024))
(define region-bytes (* 8 region-elements))

(test-pools "E11: explicit releases free an adopted deposit's memory without the collector"
  (drain-finalizers!)
  (define baseline (probe-pool-used 0))
  (define d (filled 'float64 region-elements #f))
  (define arrays (deposit->list d))
  (define used (probe-pool-used 0))
  (check-true (>= (- used baseline) (* 2 region-bytes)))
  (deposit-release! d)
  (check-true (releases-settled?))
  (check-equal? (probe-pool-used 0) used "the regions are alive")
  (define before (current-memory-use))
  (for-each device-array-release! arrays)
  (check-true (releases-settled?) "a release is still queued")
  (check-equal? (probe-pool-used 0) baseline "the pool did not return to its baseline")
  (check-true (>= (- before (current-memory-use)) (- (* 2 region-bytes) (* 128 1024))))
  (check-equal? (format "~a" d) "#<deposit device 0 released>")
  (keep-reachable arrays))
