#lang racket/base

(require (only-in racket/match match-define)
         (only-in rackunit check-equal? check-true)
         (only-in "../../main.rkt" current-device-resources device-vector->list list->device-vector)
         (only-in "../../private/dtype.rkt" dtype->code)
         (only-in "../../private/foreign/array.rkt" keep-reachable)
         (only-in "../../unsafe.rkt"
                  deposit
                  deposit->device-csr-matrix
                  device-array-release!
                  with-array-views
                  with-deposits)
         (only-in "../private/collect.rkt" drain-finalizers!)
         (only-in "../private/csr.rkt" triplets)
         (only-in "../private/deposits.rkt" counters counts-buffers since)
         (only-in "../private/probe.rkt" call/probe probe-deposit-csr-views test-probe)
         (only-in "../private/raft-error.rkt" check-raft-error)
         (only-in "../private/synced.rkt" synced?))

(define (freed before)
  (counts-buffers (since before)))

(define (check-refused a label)
  (for ([use (in-list (list (lambda () (device-vector->list a))
                            (lambda () (with-array-views ([again a]) again))))])
    (check-raft-error 'logic "device-array: used after its release" use))
  (check-equal? (format "~a" a) "#<device-vector float64[2] cuda:0 <released>>" label))

(define (fresh)
  (drain-finalizers!)
  (values (list->device-vector '(1.0 2.0) #:dtype 'float64) (counters)))

(test-probe "V1: an array released inside a binding is read through its view and freed at the exit"
  (define r (current-device-resources))
  (define indptr (list->device-vector '(0 1 2) #:dtype 'int64))
  (define indices (list->device-vector '(1 0) #:dtype 'int64))
  (define-values (data before) (fresh))
  (define d (deposit))
  (with-deposits
   ([out d])
   (with-array-views #:resources [h r] ([p indptr] [i indices] [x data])
     (device-array-release! data)
     (check-equal? (freed before) 0 "freed while a view holds it")
     (check-refused data "inside the binding")
     (call/probe
      'probe-deposit-csr-views
      (lambda ()
        (probe-deposit-csr-views h out (dtype->code 'int32) (dtype->code 'float64) p i x 0))))
   (check-equal? (freed before) 1 "not freed at the exit"))
  (check-equal? (triplets (deposit->device-csr-matrix d #:shape '(2 2))) '((0 1) (1 0) (1.0 2.0)))
  (check-refused data "after the exit")
  (keep-reachable (list indptr indices data d)))

(test-probe "V2: nested bindings of one array free it at the outer exit"
  (define-values (v before) (fresh))
  (with-array-views ([outer v])
    (with-array-views ([inner v])
      (device-array-release! v))
    (check-equal? (freed before) 0 "freed at the inner exit"))
  (check-equal? (freed before) 1 "not freed at the outer exit")
  (keep-reachable v))

(define (holder v entered leave)
  (thread (lambda ()
            (with-array-views ([x v])
              (semaphore-post entered)
              (sync/timeout 30 leave)))))

(test-probe "V3: views held by two threads free the array when the second exits, in either order"
  (for ([order (in-list '((0 1) (1 0)))])
    (define label (format "~a" order))
    (define-values (v before) (fresh))
    (define entered (make-semaphore 0))
    (define leaves (list (make-semaphore 0) (make-semaphore 0)))
    (define holders
      (for/list ([leave (in-list leaves)])
        (holder v entered leave)))
    (for ([_ (in-list holders)])
      (check-true (synced? entered 10) label))
    (check-true (synced? (thread (lambda () (device-array-release! v))) 10) label)
    (check-equal? (freed before) 0 label)
    (match-define (list first-out second-out) order)
    (semaphore-post (list-ref leaves first-out))
    (check-true (synced? (list-ref holders first-out) 10) label)
    (check-equal? (freed before) 0 (string-append label ": freed at the first exit"))
    (semaphore-post (list-ref leaves second-out))
    (check-true (synced? (list-ref holders second-out) 10) label)
    (check-equal? (freed before) 1 (string-append label ": not freed at the second exit"))
    (keep-reachable v)))

(test-probe "V4: a binding after the release raises and leaves the count alone"
  (define-values (v before) (fresh))
  (with-array-views ([x v])
    (device-array-release! v)
    (check-raft-error 'logic
                      "device-array: used after its release"
                      (lambda () (with-array-views ([y v]) y)))
    (check-equal? (freed before) 0))
  (check-equal? (freed before) 1)
  (keep-reachable v))

(define exits
  `((raise ,(lambda (v)
              (with-handlers ([(lambda (e) (eq? e 'raised)) void])
                (with-array-views ([x v])
                  (raise 'raised)))))
    (escape ,(lambda (v)
               (let/ec k
                 (with-array-views ([x v])
                   (k x)))))))

(test-probe "V5: a raise or an escape out of the binding ends its hold"
  (for ([exit (in-list exits)])
    (match-define (list kind leave) exit)
    (define-values (v before) (fresh))
    (leave v)
    (device-array-release! v)
    (check-equal? (freed before) 1 (symbol->string kind))
    (keep-reachable v)))

(test-probe "V6: an array no binding holds is freed by its release"
  (define-values (v before) (fresh))
  (device-array-release! v)
  (check-equal? (freed before) 1)
  (check-refused v "released")
  (keep-reachable v))

(test-probe "V7: a second release, before and after the last exit, does nothing"
  (define-values (v before) (fresh))
  (with-array-views ([x v])
    (device-array-release! v)
    (device-array-release! v)
    (check-equal? (freed before) 0))
  (check-equal? (freed before) 1)
  (device-array-release! v)
  (check-equal? (freed before) 1)
  (keep-reachable v))
