#lang racket/base

(require (only-in ffi/unsafe/atomic call-as-atomic)
         (only-in "array.rkt" release-array! view->array)
         (only-in "error.rkt" call/raft)
         (only-in "foreign/array.rkt" blank-view keep-reachable)
         (only-in "foreign/deposit-api.rkt"
                  rr-holder-adopt
                  rr-holder-close
                  rr-holder-count
                  rr-holder-create
                  rr-holder-record)
         (only-in "resources.rkt" resources-device resources-handle))

(provide deposit->list
         deposit-handle
         deposit-record
         deposit-release
         deposit?
         open-deposit)

(struct deposit (handle device [arrays #:mutable])
  #:constructor-name holder->deposit
  #:property prop:custom-write
  (lambda (d port _mode) (fprintf port "#<deposit device ~a>" (deposit-device d))))

(define (open-deposit resources)
  (holder->deposit (call/raft 'deposit
                              (lambda () (rr-holder-create (resources-handle 'deposit resources))))
                   (resources-device resources)
                   #f))

(define (deposit-record who d)
  (call/raft who (lambda () (rr-holder-record (deposit-handle d)))))

(define ((deposit-release d) _record)
  (call/raft 'with-deposits (lambda () (rr-holder-close (deposit-handle d))))
  (keep-reachable d))

(define (adopt holder index)
  (define view (blank-view))
  (view->array (call/raft 'deposit->list (lambda () (rr-holder-adopt holder index view))) view))

(define (adopt-all d)
  (define holder (deposit-handle d))
  (define count (call/raft 'deposit->list (lambda () (rr-holder-count holder))))
  (define arrays
    (for/fold ([adopted '()]
               #:result (reverse adopted))
              ([index (in-range count)])
      (with-handlers ([exn:fail? (lambda (e)
                                   (for-each release-array! adopted)
                                   (raise e))])
        (cons (adopt holder index) adopted))))
  (set-deposit-arrays! d arrays)
  arrays)

(define (deposit->list d)
  (call-as-atomic (lambda () (or (deposit-arrays d) (adopt-all d)))))
