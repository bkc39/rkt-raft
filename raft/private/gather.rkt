#lang racket/base

(require (only-in racket/list append-map)
         (only-in "array.rkt" device-array-dtype settled-arguments view->array)
         (only-in "error.rkt" call/raft)
         (only-in "foreign/array-api.rkt" rr-array-compare rr-array-gather rr-array-select)
         (only-in "foreign/array.rkt" blank-view)
         (only-in "pack.rkt" pack-vector))

(provide compare
         gather
         select)

(define (array-call who entry inputs . more)
  (define arguments (append (append-map (lambda (a) (settled-arguments who a)) inputs) more))
  (define view (blank-view))
  (define handle (call/raft who (lambda () (apply entry (append arguments (list view))))))
  (view->array handle view))

(define (gather a indices)
  (array-call 'gather rr-array-gather (list a indices)))

(define (select a mask)
  (array-call 'select rr-array-select (list a mask)))

(define (compare a op x)
  (array-call 'compare
              rr-array-compare
              (list a)
              op
              (pack-vector 'compare (device-array-dtype a) 1 (list x))))
