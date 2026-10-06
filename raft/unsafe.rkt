#lang racket/base

(require (for-syntax racket/base)
         ;; whole-module: it also provides syntax/parse at phase 1
         syntax/parse/define)

(provide raft-abi-pointer
         resources->handle-pointer
         status-checker
         with-array-views)

(define (raft-abi-pointer)
  (error 'raft-abi-pointer "not implemented"))

(define (resources->handle-pointer _resources)
  (error 'resources->handle-pointer "not implemented"))

(define ((status-checker _last-error _last-error-kind #:exn [_exn #f]) who _thunk)
  (error who "not implemented"))

(define-syntax-parse-rule (with-array-views ([name:id array:expr] ...) body:expr ...+)
  (error 'with-array-views "not implemented"))
