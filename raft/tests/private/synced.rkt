#lang racket/base

(provide synced?)

(define (synced? evt seconds)
  (and (sync/timeout seconds evt) #t))
