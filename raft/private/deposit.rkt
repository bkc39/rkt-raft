#lang racket/base

(require (only-in ffi/unsafe/atomic call-as-atomic)
         (only-in racket/match match)
         (only-in "array.rkt" release-array! view->array)
         (only-in "csr.rkt" checked-csr)
         (only-in "error.rkt" call/raft)
         (only-in "exn.rkt" raise-raft)
         (only-in "foreign/array.rkt" blank-view keep-reachable)
         (only-in "foreign/deposit-api.rkt"
                  rr-holder-adopt
                  rr-holder-close
                  rr-holder-count
                  rr-holder-create
                  rr-holder-record)
         (only-in "foreign/memory.rkt" rr-holder-free)
         (only-in "resource.rkt" with-release)
         (only-in "resources.rkt" resources-device resources-handle))

(provide call-with-deposits-bound
         deposit->device-csr-matrix
         deposit->list
         deposit-handle
         deposit-close
         deposit-record
         deposit-release!
         deposit?
         open-deposit)

(struct deposit (handle device [arrays #:mutable] [state #:mutable])
  #:property prop:custom-write
  (lambda (d port _mode)
    (fprintf port
             "#<deposit device ~a~a>"
             (deposit-device d)
             (if (released-deposit? d) " released" ""))))

(define (open-deposit who resources)
  (deposit (call/raft who (lambda () (rr-holder-create (resources-handle who resources))))
           (resources-device resources)
           #f
           'open))

(define (released-deposit? d)
  (and (memq (deposit-state d) '(releasing released)) #t))

(define (refuse-released d)
  (when (released-deposit? d)
    (raise-raft 'deposit 'logic "used after its release")))

(define (free-holder! d)
  (set-deposit-state! d 'released)
  (rr-holder-free (deposit-handle d)))

;; A record handed to native code is freed only once its binding lets go of it:
;; the state moves from bound to releasing, and the unbind frees the holder.
(define (unbind! d)
  (match (deposit-state d)
    ['releasing (free-holder! d)]
    [_ (set-deposit-state! d 'open)]))

(define (deposit-record who d)
  (call-as-atomic (lambda ()
                    (refuse-released d)
                    (begin0 (call/raft who (lambda () (rr-holder-record (deposit-handle d))))
                      (set-deposit-state! d 'bound)))))

(define ((deposit-close d) _record)
  (call-as-atomic (lambda ()
                    (dynamic-wind void
                                  (lambda ()
                                    (call/raft 'with-deposits
                                               (lambda () (rr-holder-close (deposit-handle d)))))
                                  (lambda () (unbind! d)))))
  (keep-reachable d))

(define (deposit-release! d)
  (call-as-atomic (lambda ()
                    (set-deposit-arrays! d #f)
                    (match (deposit-state d)
                      ['open (free-holder! d)]
                      ['bound (set-deposit-state! d 'releasing)]
                      [_ (void)]))))

(define (call-with-deposits-bound who deposits proc)
  (define handed-over? #f)
  (define ((close-unless-handed-over d) record)
    (if handed-over?
        (call-as-atomic (lambda () (unbind! d)))
        ((deposit-close d) record)))
  (let bind ([pending deposits]
             [records '()])
    (match pending
      ['()
       (begin0 (proc (reverse records) (map deposit-handle deposits))
         (set! handed-over? #t))]
      [(cons d rest)
       (with-release #:who who ([record (deposit-record who d) (close-unless-handed-over d)])
         (bind rest (cons record records)))])))

(define (adopt who holder index)
  (define view (blank-view))
  (view->array (call/raft who (lambda () (rr-holder-adopt holder index view))) view))

(define (adopt-all who d)
  (define holder (deposit-handle d))
  (define count (call/raft who (lambda () (rr-holder-count holder))))
  (define arrays
    (for/fold ([adopted '()]
               #:result (reverse adopted))
              ([index (in-range count)])
      (with-handlers ([exn:fail? (lambda (e)
                                   (for-each release-array! adopted)
                                   (raise e))])
        (cons (adopt who holder index) adopted))))
  (set-deposit-arrays! d arrays)
  arrays)

(define (adopted who d)
  (call-as-atomic (lambda ()
                    (refuse-released d)
                    (or (deposit-arrays d) (adopt-all who d)))))

(define (deposit->list d)
  (adopted 'deposit->list d))

(define (deposit->device-csr-matrix d #:shape extents)
  (define who 'deposit->device-csr-matrix)
  (match (adopted who d)
    [(list indptr indices data) (checked-csr who indptr indices data extents)]
    [arrays
     (define n (length arrays))
     (raise-raft who
                 'logic
                 "the deposit holds ~a region~a; a CSR matrix needs 3"
                 n
                 (if (= n 1) "" "s"))]))
