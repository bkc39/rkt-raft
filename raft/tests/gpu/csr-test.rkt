#lang racket/base

(require (only-in racket/list range)
         (only-in rackunit check-eq? check-equal? check-false check-true)
         (only-in "../../main.rkt"
                  csr-data
                  csr-indices
                  csr-indptr
                  device-array?
                  device-count
                  device-csr-matrix
                  device-csr-matrix->list*
                  device-csr-matrix->triplets
                  device-csr-matrix?
                  device-matrix?
                  device-resources
                  device-vector->list
                  device-vector?
                  dtype
                  list*->device-csr-matrix
                  list*->device-matrix
                  list->device-vector
                  nnz
                  shape
                  triplets->device-csr-matrix)
         (only-in "../../private/array.rkt" buffer->device-array device-array-buffer release-array!)
         (only-in "../../private/csr.rkt" parts->device-csr-matrix)
         (only-in "../../private/foreign/memory.rkt" buffer-drop-count release-failure-count)
         (only-in "../private/collect.rkt" drain-finalizers! settled-count)
         (only-in "../private/gpu.rkt" gpu-skip test-gpu)
         (only-in "../private/probe.rkt" probe-pool-used test-pools)
         (only-in "../private/raft-error.rkt" check-raft-error)
         (only-in "../private/skip.rkt" test-unless-skipped))

(define (ints xs [element-type 'int32])
  (list->device-vector xs #:dtype element-type))

(define (floats xs [element-type 'float32])
  (list->device-vector xs #:dtype element-type))

(define (parts m)
  (map device-vector->list (list (csr-indptr m) (csr-indices m) (csr-data m))))

(define (triplets m)
  (call-with-values (lambda () (device-csr-matrix->triplets m)) list))

(define G-rows '((0 1.5 0 0) (0 0 0 0) (2 0 0 -3)))

(test-gpu "law 1: the constructor shares its parts, and shape, dtype and nnz read them"
  (define indptr (ints '(0 2 2 3)))
  (define indices (ints '(3 0 1)))
  (define vals (floats '(0.5 1.0 2.0)))
  (define m (device-csr-matrix indptr indices vals #:shape '(3 4)))
  (check-eq? (csr-indptr m) indptr)
  (check-eq? (csr-indices m) indices)
  (check-eq? (csr-data m) vals)
  (check-equal? (shape m) '(3 4))
  (check-equal? (dtype m) 'float32)
  (check-equal? (nnz m) 3)
  (check-equal? (dtype (csr-indices m)) 'int32)
  (define wide
    (device-csr-matrix (ints '(0 1) 'int64)
                       (ints '(0) 'int64)
                       (floats '(1.0) 'float64)
                       #:shape '(1 1)))
  (check-equal? (list (dtype wide) (dtype (csr-indptr wide)) (nnz wide)) '(float64 int64 1)))

(test-gpu "law 2: device-csr-matrix? holds only for CSR matrices, which are not dense arrays"
  (define m (list*->device-csr-matrix G-rows))
  (check-true (device-csr-matrix? m))
  (check-false (device-array? m))
  (check-false (device-matrix? m))
  (check-false (device-vector? m))
  (for ([v (list (list*->device-matrix G-rows) (ints '(0 1)) G-rows 3 #f)])
    (check-false (device-csr-matrix? v))))

(test-gpu "law 6: ->triplets of a non-canonical CSR is its storage order, and ->list* sums repeats"
  (define m
    (device-csr-matrix (ints '(0 3 3 5))
                       (ints '(2 0 2 1 1))
                       (floats '(1.0 2.0 3.0 4.0 5.0) 'float64)
                       #:shape '(3 3)))
  (check-equal? (triplets m) '((0 0 0 2 2) (2 0 2 1 1) (1.0 2.0 3.0 4.0 5.0)))
  (check-equal? (device-csr-matrix->list* m) '((2.0 0.0 4.0) (0.0 0.0 0.0) (0.0 9.0 0.0)))
  (define zeros (device-csr-matrix (ints '(0 2)) (ints '(1 1)) (floats '(0.0 0.0)) #:shape '(1 2)))
  (check-equal? (triplets zeros) '((0 0) (1 1) (0.0 0.0)))
  (check-equal? (nnz zeros) 2))

(test-gpu "law 7: empty matrices convert both ways and print"
  (define none (list*->device-csr-matrix '()))
  (check-equal? (shape none) '(0 0))
  (check-equal? (parts none) '((0) () ()))
  (check-equal? (device-csr-matrix->list* none) '())
  (check-equal? (triplets none) '(() () ()))
  (check-equal? (format "~a" none) "#<device-csr-matrix float64 [0×0] nnz=0 index=int32 cuda:0>")
  (define no-cols (list*->device-csr-matrix '(() () ())))
  (check-equal? (shape no-cols) '(3 0))
  (check-equal? (parts no-cols) '((0 0 0 0) () ()))
  (check-equal? (device-csr-matrix->list* no-cols) '(() () ()))
  (check-equal? (triplets no-cols) '(() () ()))
  (check-equal? (format "~a" no-cols) "#<device-csr-matrix float64 [3×0] nnz=0 index=int32 cuda:0>")
  (define no-rows (triplets->device-csr-matrix '() '() '() #:shape '(0 4)))
  (check-equal? (parts no-rows) '((0) () ()))
  (check-equal? (device-csr-matrix->list* no-rows) '())
  (check-equal? (shape (device-csr-matrix (ints '(0)) (ints '()) (floats '()) #:shape '(0 4))) '(0 4))
  (check-equal? (format "~a" no-rows) "#<device-csr-matrix float64 [0×4] nnz=0 index=int32 cuda:0>")
  (define gaps-rows '((0 0) (1 2) (0 0) (3 0) (0 0)))
  (define gaps (list*->device-csr-matrix gaps-rows))
  (check-equal? (parts gaps) '((0 0 2 2 3 3) (0 1 0) (1.0 2.0 3.0)))
  (check-equal? (device-csr-matrix->list* gaps) '((0.0 0.0) (1.0 2.0) (0.0 0.0) (3.0 0.0) (0.0 0.0)))
  (check-equal? (triplets gaps) '((1 1 3) (0 1 0) (1.0 2.0 3.0)))
  (define-values (gap-rows gap-cols gap-vals) (device-csr-matrix->triplets gaps))
  (check-equal? (parts (triplets->device-csr-matrix gap-rows gap-cols gap-vals #:shape '(5 2)))
                (parts gaps))
  (check-equal?
   (format "~a" gaps)
   "#<device-csr-matrix float64 [5×2] nnz=3 index=int32 cuda:0\n (1 0) 1.0\n (1 1) 2.0\n (3 0) 3.0>")
  (define wide (triplets->device-csr-matrix '() '() '() #:shape '(1 3000000000) #:index-dtype 'int64))
  (check-equal? (parts wide) '((0 0) () ()))
  (check-equal? (triplets wide) '(() () ()))
  (check-equal? (shape (device-csr-matrix (ints '(0 0) 'int64)
                                          (ints '() 'int64)
                                          (floats '() 'float64)
                                          #:shape '(1 3000000000)))
                '(1 3000000000))
  (check-equal? (format "~a" wide)
                "#<device-csr-matrix float64 [1×3000000000] nnz=0 index=int64 cuda:0>"))

(define (refuses who message thunk . inputs)
  (check-raft-error 'logic (format "~a: ~a" who message) thunk)
  (for ([v (in-list inputs)])
    (check-true (list? (device-vector->list v)))))

(define (check-construction message indptr indices vals shape)
  (refuses 'device-csr-matrix
           message
           (lambda () (device-csr-matrix indptr indices vals #:shape shape))
           indptr
           indices
           vals))

(test-gpu "law 8: malformed parts are refused by the shim's structural checks, in table order"
  (define indptr (ints '(0 2 2 3)))
  (define indices (ints '(3 0 1)))
  (define vals (floats '(0.5 1.0 2.0)))
  (check-construction "indptr: expected int32 or int64, got float32"
                      (floats '(0 2 2 3))
                      indices
                      vals
                      '(3 4))
  (check-construction "indices: expected int32, as indptr is, got int64"
                      indptr
                      (ints '(3 0 1) 'int64)
                      vals
                      '(3 4))
  (check-construction "data: expected float32 or float64, got int32"
                      indptr
                      indices
                      (ints '(1 2 3))
                      '(3 4))
  (check-raft-error 'logic
                    "device-csr-matrix: indptr: expected rank 1, got rank 2"
                    (lambda ()
                      (device-csr-matrix (list*->device-matrix '((0) (2) (2) (3)) #:dtype 'int32)
                                         indices
                                         vals
                                         #:shape '(3 4))))
  (check-construction "shape: negative extent -1" indptr indices vals '(3 -1))
  (check-construction "shape: negative extent -3" indptr indices vals '(-3 4))
  (check-construction "shape: 3000000000 rows do not fit int32 indices"
                      indptr
                      indices
                      vals
                      '(3000000000 4))
  (check-construction "shape: 3000000000 columns do not fit int32 indices"
                      (ints '(0 3))
                      indices
                      vals
                      '(1 3000000000))
  (check-construction "indptr: expected 4 elements, got 3" (ints '(0 2 3)) indices vals '(3 4))
  (check-construction "data: expected 5 elements, got 4"
                      (ints '(0 2 2 5))
                      (ints '(0 1 2 3 0))
                      (floats '(1 2 3 4))
                      '(3 4)))

(test-gpu "law 8: malformed contents are refused by the shim's scan, at the first offending entry"
  (define indices (ints '(3 0 1)))
  (define vals (floats '(0.5 1.0 2.0)))
  (check-construction "indptr: starts at 1, expected 0" (ints '(1 2 3 3)) indices vals '(3 4))
  (check-construction "indptr: ends at 4, expected 5, the length of indices"
                      (ints '(0 2 2 4))
                      (ints '(0 1 2 3 0))
                      (floats '(1 2 3 4 5))
                      '(3 4))
  (check-construction "indptr: entry 2 (2) is less than entry 1 (3)"
                      (ints '(0 3 2 3))
                      indices
                      vals
                      '(3 4))
  (check-construction "indices: entry 2 is 7, outside [0, 4)"
                      (ints '(0 2 2 3))
                      (ints '(3 0 7))
                      vals
                      '(3 4))
  (check-construction "indices: entry 0 is -1, outside [0, 4)"
                      (ints '(0 2 2 3))
                      (ints '(-1 0 1))
                      vals
                      '(3 4))
  (check-construction "indptr: starts at 1, expected 0" (ints '(1 3 2 3)) (ints '(3 0 7)) vals '(3 4))
  (check-construction "indptr: entry 2 (2) is less than entry 1 (3)"
                      (ints '(0 3 2 3))
                      (ints '(3 0 7))
                      vals
                      '(3 4)))

(test-gpu "law 8: a released part is refused before the call"
  (define indptr (ints '(0 2 2 3)))
  (define vals (floats '(0.5 1.0 2.0)))
  (define indices (ints '(3 0 1)))
  (release-array! indices)
  (check-raft-error 'logic
                    "device-array: used after its release"
                    (lambda () (device-csr-matrix indptr indices vals #:shape '(3 4))))
  (check-equal? (device-vector->list indptr) '(0 2 2 3)))

(test-unless-skipped (or gpu-skip (and (< (device-count) 2) "needs two devices"))
                     "law 8: parts on two devices are refused"
  (define on-1
    (list->device-vector '(3 0 1) #:dtype 'int32 #:resources (device-resources #:device 1)))
  (check-construction "indices: on device 1, but indptr is on device 0"
                      (ints '(0 2 2 3))
                      on-1
                      (floats '(0.5 1.0 2.0))
                      '(3 4)))

(test-gpu "law 8: the conversions refuse data they cannot convert, naming themselves"
  (check-raft-error 'logic
                    "list*->device-csr-matrix: row 1 has 1 element, but row 0 has 2: '(3)"
                    (lambda () (list*->device-csr-matrix '((1 2) (3)))))
  (check-raft-error 'logic
                    "list*->device-csr-matrix: 1e+300 does not fit float32"
                    (lambda () (list*->device-csr-matrix '((1e300)) #:dtype 'float32)))
  (check-raft-error 'logic
                    "triplets->device-csr-matrix: cols has 2 elements, but rows has 3"
                    (lambda ()
                      (triplets->device-csr-matrix '(0 1 2) '(0 1) '(1. 2. 3.) #:shape '(3 3))))
  (check-raft-error 'logic
                    "triplets->device-csr-matrix: vals has 1 element, but rows has 3"
                    (lambda () (triplets->device-csr-matrix '(0 1 2) '(0 1 2) '(1.) #:shape '(3 3))))
  (check-raft-error 'logic
                    "triplets->device-csr-matrix: triplet 1 has row 3, outside [0, 3)"
                    (lambda () (triplets->device-csr-matrix '(0 3) '(0 0) '(1. 2.) #:shape '(3 3))))
  (check-raft-error 'logic
                    "triplets->device-csr-matrix: triplet 0 has col -1, outside [0, 4)"
                    (lambda () (triplets->device-csr-matrix '(0) '(-1) '(1.) #:shape '(3 4))))
  (check-raft-error 'logic
                    "triplets->device-csr-matrix: triplet 0 has row 1.5, not an exact integer"
                    (lambda () (triplets->device-csr-matrix '(1.5) '(0) '(1.) #:shape '(3 4))))
  (check-raft-error 'logic
                    "triplets->device-csr-matrix: triplet 0 has col 1.0, not an exact integer"
                    (lambda () (triplets->device-csr-matrix '(0) '(1.0) '(1.) #:shape '(3 4))))
  (check-raft-error 'logic
                    "list*->device-csr-matrix: indptr: expected int32 or int64, got float32"
                    (lambda () (list*->device-csr-matrix G-rows #:index-dtype 'float32)))
  (check-raft-error
   'logic
   "triplets->device-csr-matrix: indptr: expected int32 or int64, got float32"
   (lambda () (triplets->device-csr-matrix '(0) '(0) '(1.) #:shape '(1 1) #:index-dtype 'float32)))
  (check-raft-error 'logic
                    "list*->device-csr-matrix: data: expected float32 or float64, got int32"
                    (lambda () (list*->device-csr-matrix G-rows #:dtype 'int32)))
  (check-raft-error 'logic
                    "triplets->device-csr-matrix: data: expected float32 or float64, got int64"
                    (lambda ()
                      (triplets->device-csr-matrix '(0) '(0) '(1) #:shape '(1 1) #:dtype 'int64)))
  (check-raft-error
   'logic
   "list*->device-csr-matrix: unsupported dtype float16; expected float32, float64, int32 or int64"
   (lambda () (list*->device-csr-matrix G-rows #:dtype 'float16)))
  (check-raft-error
   'logic
   "triplets->device-csr-matrix: unsupported dtype float16; expected float32, float64, int32 or int64"
   (lambda () (triplets->device-csr-matrix '(0) '(0) '(1.) #:shape '(1 1) #:index-dtype 'float16))))

(test-gpu "law 11: a CSR matrix prints its entries in storage order"
  (define G (list*->device-csr-matrix G-rows #:dtype 'float32))
  (check-equal? (format "~a" G)
                (string-append "#<device-csr-matrix float32 [3×4] nnz=3 index=int32 cuda:0\n"
                               " (0 1) 1.5\n"
                               " (2 0) 2.0\n"
                               " (2 3) -3.0>"))
  (check-equal? (format "~a" (list*->device-csr-matrix '((0.1)) #:dtype 'float32))
                "#<device-csr-matrix float32 [1×1] nnz=1 index=int32 cuda:0\n (0 0) 0.1>")
  (check-equal? (format "~a" (list*->device-csr-matrix '((0.1)) #:index-dtype 'int64))
                "#<device-csr-matrix float64 [1×1] nnz=1 index=int64 cuda:0\n (0 0) 0.1>"))

(test-gpu "law 11: above 50 entries only the first and last 25 print, with their rows found"
  (define rows
    (for/list ([r (in-range 120)])
      (for/list ([c (in-range 3)])
        (if (and (even? r) (= c (modulo (quotient r 2) 3)))
            (add1 (quotient r 2))
            0))))
  (define m (list*->device-csr-matrix rows #:index-dtype 'int64))
  (define (line k)
    (format " (~a ~a) ~a.0" (* 2 k) (modulo k 3) (add1 k)))
  (check-equal? (format "~a" m)
                (string-append "#<device-csr-matrix float64 [120×3] nnz=60 index=int64 cuda:0\n"
                               (apply string-append
                                      (for/list ([k (in-range 25)])
                                        (string-append (line k) "\n")))
                               " ...\n"
                               (apply string-append
                                      (for/list ([k (in-range 35 60)])
                                        (string-append (line k) (if (= k 59) ">" "\n"))))))
  (define fifty (list*->device-csr-matrix (list (range 1 51))))
  (check-equal? (length (regexp-match* #rx"\n" (format "~a" fifty))) 50))

(test-gpu "law 11: a released part prints <released>, an unreadable one the reason"
  (define G (list*->device-csr-matrix G-rows #:dtype 'float32))
  (release-array! (csr-data G))
  (check-equal? (format "~a" G)
                "#<device-csr-matrix float32 [3×4] nnz=3 index=int32 cuda:0 <released>>")
  (define indices (ints '(3 0 1)))
  (define past-the-end
    (buffer->device-array (device-array-buffer indices) 1000 '(3) '(1) 'int32 'device))
  (define broken (parts->device-csr-matrix (ints '(0 2 2 3)) past-the-end (floats '(1 2 3)) '(3 4)))
  (check-equal?
   (format "~a" broken)
   (string-append
    "#<device-csr-matrix float32 [3×4] nnz=3 index=int32 cuda:0 <values unavailable: "
    "device-csr-matrix: 12 bytes at byte offset 1000 do not fit a buffer of 12 bytes>>")))

(define (drops-after make)
  (drain-finalizers!)
  (define before (settled-count buffer-drop-count))
  (define kept (make))
  (drain-finalizers!)
  (values (- (settled-count buffer-drop-count) before) kept))

(test-gpu "law 12: an unreachable CSR matrix frees its three parts, and a kept part outlives it"
  (define-values (all _none)
    (drops-after (lambda ()
                   (list*->device-csr-matrix G-rows)
                   #f)))
  (check-equal? all 3)
  (define-values (two kept) (drops-after (lambda () (csr-data (list*->device-csr-matrix G-rows)))))
  (check-equal? two 2)
  (check-equal? (device-vector->list kept) '(1.5 2.0 -3.0)))

(define sparse-rows
  (let ([state (vector->pseudo-random-generator (vector 1 2 3 4 5 6))])
    (for/list ([_ (in-range 100)])
      (for/list ([_ (in-range 100)])
        (if (< (random state) 0.05)
            (random 1 10 state)
            0)))))

(test-pools "law 13: memory stays flat over 1,000 cycles of list*->device-csr-matrix and drop"
  (for ([_ (in-range 10)])
    (list*->device-csr-matrix sparse-rows))
  (drain-finalizers!)
  (define baseline (probe-pool-used 0))
  (define failures (release-failure-count))
  (for ([_ (in-range 1000)])
    (list*->device-csr-matrix sparse-rows))
  (drain-finalizers!)
  (define used (probe-pool-used 0))
  (printf "memory: 1000 CSR matrices; pool used ~a bytes before, ~a after\n" baseline used)
  (check-equal? used baseline)
  (check-equal? (release-failure-count) failures))
