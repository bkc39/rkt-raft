#lang racket/base

(require (only-in racket/list make-list permutations take)
         (only-in racket/match match-define)
         (only-in rackunit check-equal? check-true)
         (only-in "../../main.rkt" device-vector->list)
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
                  filled
                  held
                  in-order
                  released-once
                  settles-to)
         (only-in "../private/probe.rkt" probe-pool-used test-pools test-probe)
         (only-in "../private/raft-error.rkt" check-raft-error))

(define (check-released d)
  (for ([use (in-list (list (lambda () (deposit->list d))
                            (lambda () (deposit->device-csr-matrix d #:shape '(2 2)))
                            (lambda () (with-deposits ([o d]) o))))])
    (check-raft-error 'logic "deposit: used after its release" use)))

(test-probe "E1: a released deposit refuses deposit->list, its list cached or not"
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
  (for ([order (in-list (permutations '(release-deposit release-array-0 release-array-1)))])
    (define steps
      (for/list ([what (in-list order)]
                 [i (in-naturals 1)])
        (list what (step-counts (take order i)))))
    (released-once (format "~a" order)
                   (in-order (lambda () (held 'float64)) steps)
                   (counts 1 1 1 2 0))))

(test-probe "E4: a deposit released before adoption frees its owner and refuses every use"
  (define d (filled 'float32 3 4))
  (released-once "filled"
                 (lambda ()
                   (deposit-release! d)
                   (check-released d))
                 (counts 1 1 1 0 0))
  (define empty (deposit))
  (released-once "never filled"
                 (lambda ()
                   (deposit-release! empty)
                   (check-released empty))
                 (counts 0 0 1 0 0)))

(test-probe "E5: a second release of each does nothing"
  (released-once "twice"
                 (lambda ()
                   (define h (held 'int32))
                   (define d (hash-ref h 'deposit))
                   (define arrays (hash-ref h 'arrays))
                   (for ([_ (in-range 2)])
                     (deposit-release! d)
                     (for-each device-array-release! arrays)))
                 (counts 1 1 1 2 0)))

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
    (check-true (and (sync/timeout 60 t) #t) "a releasing thread did not finish"))
  (define expected (counts racers racers racers (* 2 racers) 0))
  (check-equal? (settles-to before expected) expected)
  (check-equal? (length hs) racers))

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

(define (pool-settles-to expected)
  (for/or ([pause (in-list (cons 0 (make-list 200 0.01)))])
    (sleep pause)
    (releases-settled?)
    (= (probe-pool-used 0) expected)))

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
  (check-true (pool-settles-to baseline) "the pool did not return to its baseline")
  (check-true (>= (- before (current-memory-use)) (- (* 2 region-bytes) (* 128 1024))))
  (check-equal? (length arrays) 2)
  (check-equal? (format "~a" d) "#<deposit device 0 released>"))
