#lang racket/base

(require (only-in ffi/unsafe cpointer?)
         (only-in racket/generator in-generator yield)
         (only-in racket/match match match-define)
         (only-in rackunit
                  check-equal?
                  check-exn
                  check-false
                  check-pred
                  check-true
                  require/expose
                  test-case)
         (only-in syntax/macro-testing convert-syntax-error)
         (only-in "../main.rkt"
                  contiguous
                  current-device-resources
                  device-matrix->list*
                  device-matrix?
                  device-resources
                  device-vector->list
                  device-vector?
                  dtype
                  layout
                  list*->device-matrix
                  list->device-vector
                  shape
                  with-device-resources)
         (only-in "../private/array.rkt" array-device release-array!)
         (only-in "../private/dtype.rkt" dtype->code)
         (only-in "../private/foreign/memory.rkt"
                  buffer-drop-count
                  holder-drop-count
                  owner-release-count
                  release-failure-count
                  resources-drop-count)
         (only-in "../private/os-call.rkt" calls-in-flight)
         (only-in "../private/resources.rkt" resources-handle)
         (only-in "../unsafe.rkt" deposit deposit->list deposit? with-array-views with-deposits)
         (only-in "private/collect.rkt" collect-until drain-finalizers!)
         (only-in "private/probe.rkt"
                  call/probe
                  probe-deposit
                  probe-flags
                  probe-hold!
                  probe-owner-drops
                  probe-owner-stale
                  probe-pool-used
                  probe-refuse-adoption!
                  probe-release!
                  test-pools
                  test-probe)
         (only-in "private/raft-error.rkt" check-raft-error))

(require/expose "../private/deposit.rkt" (deposit-handle))

(define (fill! d
               dt
               rows
               cols
               #:count [k 2]
               #:flags [flags 0]
               #:resources [r (current-device-resources)])
  (with-deposits ([out d])
                 (with-array-views #:resources [h r] ()
                   (call/probe 'probe-deposit
                               (lambda ()
                                 (probe-deposit h out (dtype->code dt) k rows (or cols -1) flags))))))

(define (filled dt
                rows
                cols
                #:count [k 2]
                #:flags [flags 0]
                #:resources [r (current-device-resources)])
  (define d (deposit #:resources r))
  (fill! d dt rows cols #:count k #:flags flags #:resources r)
  d)

(define (pattern dt
          r
          rows
          cols)
  (define (v x)
    (if (memq dt '(float32 float64))
        (exact->inexact x)
        x))
  (if cols
      (for/list ([i (in-range rows)])
        (for/list ([j (in-range cols)])
          (v (+ (* r 1000) (* i cols) j))))
      (for/list ([i (in-range rows)])
        (v (+ (* r 1000) i)))))

(define (contents a)
  (if (device-matrix? a)
      (device-matrix->list* a)
      (device-vector->list a)))

(define (check-pattern arrays dt rows cols [label ""])
  (check-equal? (length arrays) 2 label)
  (for ([a (in-list arrays)]
        [r (in-naturals)])
    (check-equal? (contents a)
                  (pattern dt
                    r
                    rows
                    cols)
                  label)))

(struct counts (owners probe-drops holders buffers failures) #:transparent)

(define (counters)
  (counts (owner-release-count)
          (probe-owner-drops)
          (holder-drop-count)
          (buffer-drop-count)
          (release-failure-count)))

(define (since before)
  (define now (counters))
  (counts (- (counts-owners now) (counts-owners before))
          (- (counts-probe-drops now) (counts-probe-drops before))
          (- (counts-holders now) (counts-holders before))
          (- (counts-buffers now) (counts-buffers before))
          (- (counts-failures now) (counts-failures before))))

(define (settles-to before expected)
  (collect-until (lambda () (equal? (since before) expected)))
  (since before))

(define shapes
  '((0 #f #f) (1 #f #f) (7 #f #f) (1000 #f #f) (3 4 row-major) (3 4 col-major) (0 4 row-major)))

(test-probe "law 1: every dtype and shape round-trips through deposit->list"
  (for* ([dt (in-list '(float32 float64 int32 int64))]
         [s (in-list shapes)])
    (match-define (list rows cols order) s)
    (define label (format "~a ~a" dt s))
    (define flags
      (if (eq? order 'col-major)
          (probe-flags 'col-major)
          0))
    (define arrays (deposit->list (filled dt rows cols #:flags flags)))
    (check-equal? (length arrays) 2 label)
    (check-pattern arrays dt rows cols label)
    (for ([a (in-list arrays)])
      (check-equal? (dtype a) dt label)
      (check-equal? (shape a)
                    (if cols
                        (list rows cols)
                        (list rows))
                    label)
      (if cols
          (check-equal? (layout a) order label)
          (check-pred device-vector? a label)))))

(test-probe "law 2: deposit->list answers the same arrays, from two threads at once too"
  (define d (filled 'float32 3 4))
  (define once (deposit->list d))
  (check-true (andmap eq? once (deposit->list d)))
  (define shared (filled 'int64 5 #f))
  (match-define (list first second)
    (map thread-wait
         (for/list ([_ (in-range 2)])
           (thread (lambda () (deposit->list shared)) #:keep 'results))))
  (check-true (andmap eq? first second))
  (check-pattern first 'int64 5 #f))

(define (released-once label run expected)
  (drain-finalizers!)
  (define stale (probe-owner-stale))
  (define before (counters))
  (run)
  (check-equal? (settles-to before expected) expected label)
  (check-equal? (probe-owner-stale) stale label))

(define (held dt #:resources [r (current-device-resources)])
  (define d (filled dt 3 4 #:resources r))
  (make-hasheq (list (cons 'deposit d) (cons 'arrays (deposit->list d)) (cons 'dtype dt))))

(define (drop! h what)
  (match what
    ['released-arrays
     (for-each release-array! (hash-ref h 'arrays))
     (hash-remove! h 'arrays)]
    [_ (hash-remove! h what)]))

(define (read-back h label)
  (match (hash-ref h 'arrays #f)
    [#f (void)]
    [arrays (check-pattern arrays (hash-ref h 'dtype) 3 4 label)]))

(define (in-order make steps)
  (lambda ()
    (define before (counters))
    (define h (make))
    (for ([step (in-list steps)])
      (match-define (list what expected) step)
      (define label (symbol->string what))
      (drop! h what)
      (check-equal? (settles-to before expected) expected label)
      (read-back h label))))

(define (held-past-resources)
  (define drops (resources-drop-count))
  (define h
    (with-device-resources ([r (device-resources)])
      (held 'int32 #:resources r)))
  (drain-finalizers!)
  (check-equal? (- (resources-drop-count) drops) 1)
  h)

(define (failed-after-filling)
  (define d (deposit))
  (check-raft-error 'logic
                    "probe-deposit: failed after filling"
                    (lambda () (fill! d 'float32 3 4 #:flags (probe-flags 'fail-after))))
  (check-pattern (deposit->list d) 'float32 3 4))

(test-probe "law 3: the owner is released exactly once, whatever is dropped first"
  (for ([case (in-list
               `(("arrays first" ,(lambda () (held 'float32))
                                 ((released-arrays ,(counts 0 0 0 2 0)))
                                 ,(counts 1 1 1 2 0))
                 ("deposit first" ,(lambda () (held 'float32))
                                  ((deposit ,(counts 0 0 1 0 0)))
                                  ,(counts 1 1 1 2 0))
                 ("resources first" ,held-past-resources
                                    ((deposit ,(counts 0 0 1 0 0)))
                                    ,(counts 1 1 1 2 0))
                 ("never converted" ,(lambda () (filled 'float64 7 #f)) () ,(counts 1 1 1 0 0))
                 ("never filled" ,(lambda ()
                                    (with-deposits ([out (deposit)]) (check-pred cpointer? out)))
                                 ()
                                 ,(counts 0 0 1 0 0))
                 ("filled, then the call failed" ,failed-after-filling () ,(counts 1 1 1 2 0))))])
    (match-define (list label make steps expected) case)
    (released-once label (in-order make steps) expected)))

(test-probe "law 4: adopted arrays outlive their resources object"
  (drain-finalizers!)
  (define before (resources-drop-count))
  (define arrays
    (with-device-resources ([r (device-resources)])
      (deposit->list (filled 'float64 3 4 #:resources r))))
  (drain-finalizers!)
  (check-equal? (- (resources-drop-count) before) 1)
  (check-pattern arrays 'float64 3 4))

(define (refused-by-downstream message thunk)
  (define before (counters))
  (check-raft-error 'logic message thunk)
  (check-equal? (counts-probe-drops (since before)) 1 message)
  (check-equal? (counts-owners (since before)) 0 message))

(test-probe "law 5: a downstream refusal frees the owner on the downstream side"
  (define other (device-resources))
  (define elsewhere (deposit #:resources other))
  (refused-by-downstream "probe-deposit: out: on resources other than the call's"
                         (lambda () (fill! elsewhere 'float32 3 4)))
  (check-equal? (deposit->list elsewhere) '())
  (define twice (deposit))
  (refused-by-downstream "probe-deposit: out: already filled"
                         (lambda () (fill! twice 'int32 3 4 #:flags (probe-flags 'twice))))
  (check-pattern (deposit->list twice) 'int32 3 4)
  (refused-by-downstream "probe-deposit: out: 9 regions; the most is 8"
                         (lambda () (fill! (deposit) 'float32 2 #f #:count 9)))
  (refused-by-downstream "probe-deposit: out: region 1 overlaps region 0"
                         (lambda () (fill! (deposit) 'float32 3 4 #:flags (probe-flags 'overlap))))
  (released-once "an empty fill"
                 (lambda () (check-equal? (deposit->list (filled 'float32 3 4 #:count 0)) '()))
                 (counts 1 1 1 0 0)))

(test-probe "law 6: the shim checks a record filled by hand again"
  (for ([case (in-list '((misalign "deposit->list: region 0: not aligned to its element size")
                         (host "deposit->list: region 0: not device memory on device 0")
                         (rank3 "deposit->list: region 0: expected rank 1 or 2, got rank 3")))])
    (match-define (list flag message) case)
    (released-once (symbol->string flag)
                   (lambda ()
                     (define d (filled 'float32 3 4 #:flags (probe-flags 'raw flag)))
                     (check-raft-error 'logic message (lambda () (deposit->list d)))
                     (check-raft-error 'logic message (lambda () (deposit->list d))))
                   (counts 1 1 1 0 0))))

(test-probe "law 6: a refused adoption frees the arrays adopted before it, and a retry adopts all"
  (released-once "refused at region 1"
                 (lambda ()
                   (define d (filled 'int64 3 4))
                   (define before (counters))
                   (probe-refuse-adoption! (deposit-handle d) 1)
                   (check-raft-error 'logic
                                     "deposit->list: region 1: refused by the probe"
                                     (lambda () (deposit->list d)))
                   (check-equal? (since before) (counts 0 0 0 1 0))
                   (check-pattern (deposit->list d) 'int64 3 4))
                 (counts 1 1 1 3 0)))

(test-probe "law 7: an open deposit, a closed one and re-entry each have their error"
  (define d (deposit))
  (check-pred deposit? d)
  (check-false (deposit? (current-device-resources)))
  (check-raft-error 'logic
                    "deposit->list: the deposit is still open"
                    (lambda () (with-deposits ([out d]) (deposit->list d))))
  (check-equal? (deposit->list d) '())
  (check-raft-error 'logic
                    "with-deposits: the deposit is closed"
                    (lambda () (with-deposits ([out d]) out)))
  (define used (filled 'float32 3 4))
  (check-raft-error 'logic
                    "with-deposits: the deposit is closed"
                    (lambda () (with-deposits ([out used]) out)))
  (check-raft-error
   'logic
   "with-deposits: cannot re-enter its body after its resources were released"
   (lambda ()
     (for/list ([v (in-generator (with-deposits ([out (deposit)]) (yield out) (yield out)))])
       v))))

(test-case "law 7: duplicate ids are a syntax error"
  (check-exn #rx"duplicate binding name"
             (lambda () (convert-syntax-error (with-deposits ([a (deposit)] [a (deposit)]) a)))))

(define (await-calls)
  (for ([_ (in-range 500)]
        #:break (zero? (calls-in-flight)))
    (sleep 0.01))
  (check-equal? (calls-in-flight) 0))

(test-probe "law 8: a killed caller's deposit is filled, or released once"
  (define r (current-device-resources))
  (define retained (deposit))
  (check-true (probe-hold! (resources-handle 'test r)))
  (define caller
    (thread (lambda () (fill! retained 'int64 3 4 #:flags (probe-flags 'wait) #:resources r))))
  (sleep 0.05)
  (kill-thread caller)
  (check-raft-error 'logic
                    "with-deposits: the deposit is already bound"
                    (lambda () (with-deposits ([out retained]) out)))
  (probe-release!)
  (await-calls)
  (check-pattern (deposit->list retained) 'int64 3 4)
  (released-once "unretained"
                 (lambda ()
                   (define before (counters))
                   (check-true (probe-hold! (resources-handle 'test r)))
                   (define lost
                     (thread (lambda () (fill! (deposit) 'float32 3 4 #:flags (probe-flags 'wait)))))
                   (sleep 0.05)
                   (kill-thread lost)
                   (for ([_ (in-range 3)])
                     (collect-garbage 'major))
                   (drain-finalizers!)
                   (check-equal? (counts-holders (since before)) 0 "held across the killed call")
                   (probe-release!)
                   (await-calls))
                 (counts 1 1 1 0 0)))

(test-probe "law 9: a major collection or a break during a blocking deposit call"
  (define r (current-device-resources))
  (define d (deposit))
  (check-true (probe-hold! (resources-handle 'test r)))
  (define caller
    (thread (lambda () (fill! d 'float64 3 4 #:flags (probe-flags 'wait) #:resources r))))
  (sleep 0.05)
  (for ([_ (in-range 3)])
    (collect-garbage 'major))
  (probe-release!)
  (thread-wait caller)
  (check-pattern (deposit->list d) 'float64 3 4)
  (define broken (deposit))
  (check-true (probe-hold! (resources-handle 'test r)))
  (define outcome (box #f))
  (define breaker
    (thread (lambda ()
              (with-handlers ([exn:break? (lambda (_) (set-box! outcome 'broken))])
                (fill! broken 'float32 3 4 #:flags (probe-flags 'wait) #:resources r)
                (set-box! outcome 'returned)))))
  (sleep 0.05)
  (break-thread breaker)
  (probe-release!)
  (thread-wait breaker)
  (check-equal? (unbox outcome) 'broken)
  (check-raft-error 'logic
                    "with-deposits: the deposit is closed"
                    (lambda () (with-deposits ([out broken]) out)))
  (check-pattern (deposit->list broken) 'float32 3 4))

(test-probe "law 10: adopted arrays work wherever a raft array does"
  (match-define (list m _) (deposit->list (filled 'float32 3 4)))
  (match-define (list v _) (deposit->list (filled 'float32 7 #f)))
  (define twin (list*->device-matrix (device-matrix->list* m) #:dtype 'float32))
  (check-equal? (device-matrix->list* (contiguous m #:layout 'col-major))
                (device-matrix->list* (contiguous twin #:layout 'col-major)))
  (check-equal? (layout (contiguous m #:layout 'col-major)) 'col-major)
  (check-equal? (format "~a" m) (format "~a" twin))
  (check-equal? (format "~a" v)
                (format "~a" (list->device-vector (device-vector->list v) #:dtype 'float32)))
  (check-true (with-array-views ([x m] [y v])
                (and (cpointer? x) (cpointer? y))))
  (check-equal? (array-device m) 0)
  (match-define (list col _) (deposit->list (filled 'int32 3 4 #:flags (probe-flags 'col-major))))
  (check-equal? (device-matrix->list* (contiguous col #:layout 'row-major))
                (pattern 'int32
                  0
                  3
                  4)))

(define cycles 1000)

(test-pools "law 11: memory stays flat over 1,000 cycles of fill, adopt and drop"
  (for ([_ (in-range 10)])
    (deposit->list (filled 'float32 3 4)))
  (drain-finalizers!)
  (define baseline (probe-pool-used 0))
  (define before (counters))
  (for ([_ (in-range cycles)])
    (deposit->list (filled 'float32 3 4)))
  (define expected (counts cycles cycles cycles (* 2 cycles) 0))
  (define settled (settles-to before expected))
  (drain-finalizers!)
  (define used (probe-pool-used 0))
  (printf
   "memory: ~a deposits; pool used ~a bytes before, ~a after; ~a owners released, ~a probe drops, ~a holders and ~a buffers freed; ~a release failures\n"
   cycles
   baseline
   used
   (counts-owners settled)
   (counts-probe-drops settled)
   (counts-holders settled)
   (counts-buffers settled)
   (counts-failures settled))
  (check-equal? settled expected)
  (check-equal? used baseline))
