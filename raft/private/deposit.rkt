#lang racket/base

(require (only-in ffi/unsafe/atomic call-as-atomic)
         (only-in "array.rkt" view->array)
         (only-in "error.rkt" call/raft)
         (only-in "foreign/array.rkt" blank-view)
         (only-in "foreign/deposit-api.rkt"
                  rr-holder-adopt
                  rr-holder-close
                  rr-holder-count
                  rr-holder-create
                  rr-holder-record)
         (only-in "resources.rkt" current-device-resources resources-device resources-handle))

(provide close-deposit!
         deposit
         deposit->list
         deposit-record
         deposit?)

(struct deposit (handle device [arrays #:mutable])
  #:omit-define-syntaxes
  #:constructor-name holder->deposit
  #:property prop:custom-write
  (lambda (d port _mode) (fprintf port "#<deposit device ~a>" (deposit-device d))))

(define (deposit #:resources [resources (current-device-resources)]) ;; noqa
  (holder->deposit
   (call/raft 'deposit (lambda () (rr-holder-create (resources-handle 'deposit resources))))
   (resources-device resources)
   #f))

(define (deposit-record who d)
  (call/raft who (lambda () (rr-holder-record (deposit-handle d)))))

(define (close-deposit! d)
  (call/raft 'with-deposits (lambda () (rr-holder-close (deposit-handle d)))))

(define (adopt holder index)
  (define view (blank-view))
  (view->array (call/raft 'deposit->list (lambda () (rr-holder-adopt holder index view))) view))

(define (adopt-all d)
  (define holder (deposit-handle d))
  (define count (call/raft 'deposit->list (lambda () (rr-holder-count holder))))
  (define arrays
    (for/list ([index (in-range count)])
      (adopt holder index)))
  (set-deposit-arrays! d arrays)
  arrays)

(define (deposit->list d)
  (call-as-atomic (lambda () (or (deposit-arrays d) (adopt-all d)))))
