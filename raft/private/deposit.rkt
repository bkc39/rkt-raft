#lang racket/base

(require (only-in "resources.rkt" current-device-resources))

(provide close-deposit!
         deposit
         deposit->list
         deposit-record
         deposit?)

(struct deposit (handle device [arrays #:mutable])
  #:omit-define-syntaxes
  #:constructor-name holder->deposit)

(define (deposit #:resources [resources (current-device-resources)]) ;; noqa
  (error 'unimplemented))

(define (deposit-record who d)
  (error 'unimplemented))

(define (close-deposit! d)
  (error 'unimplemented))

(define (deposit->list d)
  (error 'unimplemented))
