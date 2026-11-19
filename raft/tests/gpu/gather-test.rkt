#lang racket/base

(require (only-in racket/list make-list range)
         (only-in racket/match match match-define)
         (only-in rackunit check-equal? check-exn check-false check-not-false check-true)
         (only-in "../../main.rkt"
                  compare
                  device-count
                  device-resources
                  device-vector->list
                  exn:fail:raft?
                  gather
                  list*->device-matrix
                  list->device-vector
                  select
                  shape)
         (only-in "../../private/array.rkt" release-array!)
         (only-in "../../private/foreign/memory.rkt" release-failure-count)
         (only-in "../../private/resource.rkt" with-release)
         (only-in "../../private/resources.rkt" resources-handle)
         (only-in "../private/arrays.rkt" ints part storage)
         (only-in "../private/collect.rkt" drain-finalizers! drops-after)
         (only-in "../private/gather.rkt" gather-state kept)
         (only-in "../private/gpu.rkt" gpu-skip test-gpu)
         (only-in "../private/probe.rkt"
                  probe-hold!
                  probe-pool-used
                  probe-release!
                  test-pools
                  test-probe)
         (only-in "../private/raft-error.rkt" check-raft-error)
         (only-in "../private/skip.rkt" test-unless-skipped))

(test-gpu "law 12: the clustered samples are the ids whose label is not negative"
  (define state (gather-state))
  (for ([_ (in-range 100)])
    (define n (random 40 state))
    (define labels
      (for/list ([_ (in-range n)])
        (random -1 5 state)))
    (define ids (ints (range n)))
    (define clustered (compare (ints labels) '>= 0))
    (check-equal? (device-vector->list (select ids clustered))
                  (kept (range n) (map (lambda (l) (if (>= l 0) 1 0)) labels))
                  (format "~s" labels))))

(define five-rows '(matrix float32 (0 1) (2 3) (4 5) (6 7) (8 9)))
(define four-rows '(matrix float64 (0 1) (2 3) (4 5) (6 7)))

(define refusals
  `((gather "indices: expected int32 or int64, got float32" ,five-rows (float32 0 1))
    (gather "indices: expected rank 1, got rank 2" ,five-rows (matrix int32 (0) (1)))
    (gather "indices: entry 2 is 7, outside [0, 5)" ,five-rows (int32 3 0 7))
    (gather "indices: entry 2 is 7, outside [0, 5)" (int64 0 1 2 3 4) (int32 3 0 7))
    (gather "indices: entry 0 is -1, outside [0, 5)" ,five-rows (int32 -1 0))
    (gather "indices: entry 0 is 3000000000, outside [0, 5)" ,five-rows (int64 3000000000))
    (gather "indices: entry 0 is 0, outside [0, 0)" (blank float32 0 3) (int32 0))
    (gather "indices: entry 1 is 5, outside [0, 5)" (float32 0 1 2 3 4) (int64 4 5 -1))
    (select "mask: expected int32 or int64, got float64" ,four-rows (float64 1 0 1 0))
    (select "mask: expected rank 1, got rank 2" ,four-rows (matrix int32 (1) (0) (1) (0)))
    (select "mask: expected 4 elements, got 3" ,four-rows (int32 1 0 1))
    (select "mask: expected 4 elements, got 5" (int32 1 2 3 4) (int64 1 0 1 0 1))
    (compare "unsupported comparison !=; expected =, <, <=, > or >=" (int32 1 2) != 0)
    (compare "3000000000 does not fit int32" (int32 1 2) < 3000000000)
    (compare "+nan.0 is not a finite number" (int32 1 2) < +nan.0)
    (compare "1e+300 does not fit float32" (float32 1 2) < 1e300)
    (compare "0.5 does not fit int32 exactly" (int32 -1 0 1 2) = 0.5)
    (compare "1/2 does not fit int32 exactly" (int32 -1 0 1 2) < 1/2)
    (compare "-0.5 does not fit int32 exactly" (int32 -1 0 1 2) > -0.5)
    (compare "1.5 does not fit int32 exactly" (int32 -1 0 1 2) = 1.5)
    (compare "0.5 does not fit int64 exactly" (int64 -1 0 1 2) >= 0.5)
    (compare "1/2 does not fit int64 exactly" (int64 -1 0 1 2) <= 1/2)
    (compare "-0.5 does not fit int64 exactly" (int64 -1 0 1 2) > -0.5)
    (compare "1.5 does not fit int64 exactly" (int64 -1 0 1 2) = 1.5)))

(define operations (hasheq 'gather gather 'select select))

(define (refused-call row)
  (match row
    [(list 'compare _ a-spec op x)
     (define a (part a-spec))
     (values (list a) (lambda () (compare a op x)))]
    [(list name _ a-spec b-spec)
     (define a (part a-spec))
     (define b (part b-spec))
     (values (list a b) (lambda () ((hash-ref operations name) a b)))]))

(test-gpu "law 13: every refusal has its exact message and kind, and the inputs stay readable"
  (for ([row (in-list refusals)])
    (match-define (list* name message _) row)
    (define-values (inputs call) (refused-call row))
    (define before (map storage inputs))
    (check-raft-error 'logic (format "~a: ~a" name message) call)
    (check-equal? (map storage inputs) before message)))

(test-gpu "law 13: no refusal names a shim entry point"
  (for ([row (in-list refusals)])
    (define-values (_ call) (refused-call row))
    (define text
      (with-handlers ([exn:fail? exn-message])
        (call)
        ""))
    (check-false (regexp-match? #rx"rr_" text) text)))

(test-gpu "law 13: an integer-valued float threshold on an integer dtype compares exactly"
  (for ([element-type (in-list '(int32 int64))])
    (define a (ints '(-1 0 1 2) element-type))
    (check-equal? (device-vector->list (compare a '= 2.0)) '(0 0 0 1))
    (check-equal? (device-vector->list (compare a '>= -0.0)) '(0 1 1 1))
    (check-equal? (device-vector->list (compare a '< -0.0)) '(1 0 0 0))))

(define released-inputs '((gather 0) (gather 1) (select 0) (select 2) (compare 0)))

(define (call-on name inputs)
  (match-define (list a index mask) inputs)
  (match name
    ['gather (gather a index)]
    ['select (select a mask)]
    ['compare (compare a '< 2.0)]))

(test-gpu "law 13: a released input is refused before the call, and the others stay readable"
  (for ([row (in-list released-inputs)])
    (match-define (list name position) row)
    (define contents '((1.0 2.0 3.0) (0 2) (1 0 1)))
    (match-define (list xs picks keeps) contents)
    (define inputs (list (list->device-vector xs) (ints picks) (ints keeps)))
    (release-array! (list-ref inputs position))
    (check-raft-error 'logic "device-array: used after its release" (lambda () (call-on name inputs)))
    (for ([v (in-list inputs)]
          [expected (in-list contents)]
          [i (in-naturals)]
          #:unless (= i position))
      (check-equal? (device-vector->list v) expected (format "~s" row)))))

(define two-devices-skip (or gpu-skip (and (< (device-count) 2) "needs two devices")))

(test-unless-skipped two-devices-skip "law 13: indices or a mask on another device are refused"
  (define on-1 (list->device-vector '(0 1) #:dtype 'int32 #:resources (device-resources #:device 1)))
  (define a (list->device-vector '(1.0 2.0)))
  (check-raft-error 'logic
                    "gather: indices: on device 1, but the array is on device 0"
                    (lambda () (gather a on-1)))
  (check-raft-error 'logic
                    "select: mask: on device 1, but the array is on device 0"
                    (lambda () (select a on-1))))

(test-probe "an index or mask vector still pending on other resources is awaited before the call"
  (define v (ints '(10 20 30 40) 'int64))
  (define other (device-resources))
  (define index (list->device-vector '(3 0 2) #:dtype 'int32 #:resources other))
  (define mask (list->device-vector '(1 0 1 1) #:dtype 'int64 #:resources other))
  (for ([call (in-list (list (lambda () (gather v index)) (lambda () (select v mask))))]
        [expected (in-list '((40 10 30) (10 30 40)))])
    (define result (box #f))
    (define worker
      (with-release ([held
                      (probe-hold! (resources-handle 'hold other))
                      (lambda (_) (probe-release!))])
        (check-true held "the probe queued its hold")
        (define caller (thread (lambda () (set-box! result (call)))))
        (check-false (sync/timeout 1 caller) "the call waits while the input's stream is held")
        caller))
    (check-not-false (sync/timeout 10 worker))
    (check-equal? (device-vector->list (unbox result)) expected)))

(test-gpu "law 16: each result is one buffer, freed once unreachable"
  (define M (list*->device-matrix '((1 2) (3 4) (5 6)) #:dtype 'float32))
  (define index (ints '(2 0)))
  (define mask (ints '(1 0 1)))
  (for ([make (in-list (list (lambda () (gather M index))
                             (lambda () (select M mask))
                             (lambda () (compare M '> 2.0))))])
    (define-values (drops _)
      (drops-after (lambda ()
                     (make)
                     #f)))
    (check-equal? drops 1))
  (check-equal? (map shape (list M index mask)) '((3 2) (2) (3))))

(define rows-100x16
  (for/list ([i (in-range 100)])
    (for/list ([j (in-range 16)])
      (+ i (/ j 16.0)))))

(test-pools "law 17: memory stays flat over 1,000 cycles of each operation and of a refused gather"
  (define M (list*->device-matrix rows-100x16 #:dtype 'float32))
  (define index
    (ints (for/list ([i (in-range 50)])
            (* 2 i))))
  (define half
    (ints (for/list ([i (in-range 100)])
            (modulo i 2))))
  (define outside (ints (append (make-list 49 0) '(100))))
  (define (cycle)
    (gather M index)
    (select M half)
    (compare M '>= 50.0)
    (with-handlers ([exn:fail? void])
      (gather M outside)))
  (for ([_ (in-range 10)])
    (cycle))
  (drain-finalizers!)
  (define baseline (probe-pool-used 0))
  (define failures (release-failure-count))
  (for ([_ (in-range 1000)])
    (cycle))
  (drain-finalizers!)
  (define used (probe-pool-used 0))
  (printf "memory: 1000 cycles of each operation and a refused gather; pool used ~a, then ~a bytes\n"
          baseline
          used)
  (check-equal? used baseline)
  (check-equal? (release-failure-count) failures)
  (check-equal? (map shape (list M index half outside)) '((100 16) (50) (100) (50))))

(test-pools "a refused call allocates nothing: no buffer is dropped and the pool does not move"
  (define M (list*->device-matrix rows-100x16 #:dtype 'float32))
  (define outside (ints '(0 100)))
  (define short (ints '(1 0 1)))
  (define labels (ints '(1 2)))
  (define refused
    (list (lambda () (gather M outside))
          (lambda () (select M short))
          (lambda () (compare M '!= 0.0))
          (lambda () (compare labels '>= 0.5))))
  (for ([call (in-list refused)]
        [name (in-list '(gather select compare compare-scalar))])
    (drain-finalizers!)
    (define used (probe-pool-used 0))
    (define-values (drops _)
      (drops-after (lambda ()
                     (check-exn exn:fail:raft? call)
                     #f)))
    (check-equal? (list drops (probe-pool-used 0)) (list 0 used) (symbol->string name)))
  (check-equal? (map shape (list M outside short labels)) '((100 16) (2) (3) (2))))
