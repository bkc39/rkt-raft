#lang racket/base

(require (only-in racket/match match match-define)
         (only-in rackunit check-equal? check-pred check-true)
         (only-in "../../main.rkt"
                  current-device-resources
                  device-matrix->list*
                  device-matrix?
                  device-vector->list
                  device-vector?
                  dtype
                  layout
                  shape)
         (only-in "../../private/dtype.rkt" dtype->code)
         (only-in "../../private/foreign/memory.rkt"
                  buffer-drop-count
                  holder-drop-count
                  owner-release-count
                  release-failure-count)
         (only-in "../../private/resource.rkt" with-release)
         (only-in "../../unsafe.rkt" deposit deposit->list with-array-views with-deposits)
         (only-in "collect.rkt" collect-until drain-finalizers!)
         (only-in "gate.rkt" await-entry closed-gate release-gate)
         (only-in "probe.rkt"
                  call/probe
                  probe-deposit
                  probe-flags
                  probe-owner-drops
                  probe-owner-stale)
         (only-in "raft-error.rkt" check-raft-error))

(provide call-with-gated-job
         check-deposit-closed
         check-pattern
         check-round-trips
         counters
         (struct-out counts)
         fill!
         filled
         region-values
         released-once
         settles-to
         since)

(define (fill! d
               dt
               rows
               cols
               #:count [k 2]
               #:flags [flags 0]
               #:resources [r (current-device-resources)]
               #:then [then void])
  (with-deposits ([out d])
                 (with-array-views #:resources [h r] ()
                   (call/probe 'probe-deposit
                               (lambda ()
                                 (probe-deposit h out (dtype->code dt) k rows (or cols -1) flags))))
                 (then)))

(define (filled dt
                rows
                cols
                #:count [k 2]
                #:flags [flags 0]
                #:resources [r (current-device-resources)])
  (define d (deposit #:resources r))
  (fill! d dt rows cols #:count k #:flags flags #:resources r)
  d)

(define (region-values dt r rows cols)
  (define (v x)
    (if (memq dt '(float32 float64))
        (exact->inexact x)
        x))
  (match cols
    [#f
     (for/list ([i (in-range rows)])
       (v (+ (* r 1000) i)))]
    [_
     (for/list ([i (in-range rows)])
       (for/list ([j (in-range cols)])
         (v (+ (* r 1000) (* i cols) j))))]))

(define (contents a)
  (cond
    [(device-matrix? a) (device-matrix->list* a)]
    [else (device-vector->list a)]))

(define (check-pattern arrays dt rows cols [label ""])
  (check-equal? (length arrays) 2 label)
  (for ([a (in-list arrays)]
        [r (in-naturals)])
    (check-equal? (contents a) (region-values dt r rows cols) label)))

(define (check-deposit-closed d)
  (check-raft-error 'logic
                    "with-deposits: the deposit is closed"
                    (lambda () (with-deposits ([o d]) o))))

(define (call-with-gated-job start proc)
  (with-release ([g (closed-gate) release-gate])
    (define caller (thread (lambda () (start g)) #:keep 'results))
    (check-true (await-entry g))
    (proc g caller)))

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

(define (check-round-trips fill)
  (for* ([dt (in-list '(float32 float64 int32 int64))]
         [s (in-list shapes)])
    (match-define (list rows cols order) s)
    (define label (format "~a ~a" dt s))
    (define flags
      (if (eq? order 'col-major)
          (probe-flags 'col-major)
          0))
    (define arrays (deposit->list (fill dt rows cols #:flags flags)))
    (check-equal? (length arrays) 2 label)
    (check-pattern arrays dt rows cols label)
    (for ([a (in-list arrays)])
      (check-equal? (dtype a) dt label)
      (match cols
        [#f
         (check-equal? (shape a) (list rows) label)
         (check-pred device-vector? a label)]
        [_
         (check-equal? (shape a) (list rows cols) label)
         (check-equal? (layout a) order label)]))))

(define (released-once label run expected)
  (drain-finalizers!)
  (define stale (probe-owner-stale))
  (define before (counters))
  (run)
  (check-equal? (settles-to before expected) expected label)
  (check-equal? (probe-owner-stale) stale label))
