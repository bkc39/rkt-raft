#lang racket/base

(module+ main
  (require (only-in racket/match match)
           (only-in "private/cublas.rkt" fetch-cublas))
  (match (fetch-cublas (find-system-path 'addon-dir))
    [#f (void)]
    [message
     (eprintf "raft: ~a\n" message)
     (exit 1)]))
