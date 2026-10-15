#lang racket/base

(require (only-in racket/place place place-channel-get place-channel-put)
         (only-in "../../private/resources.rkt" resources-handle resources-sync!)
         (only-in "probe.rkt" probe-hold!))

(provide call-with-busy-device)

(define (start-releaser)
  (define releaser
    (place ch
           (define release! (dynamic-require 'raft/tests/private/probe 'probe-release!))
           (place-channel-put ch 'ready)
           (sleep (place-channel-get ch))
           (release!)
           (place-channel-put ch 'released)))
  (place-channel-get releaser)
  releaser)

(define (call-with-busy-device r seconds thunk)
  (define releaser (start-releaser))
  (unless (probe-hold! (resources-handle 'call-with-busy-device r))
    (error 'call-with-busy-device "the probe could not hold the stream"))
  (place-channel-put releaser seconds)
  (begin0 (thunk)
    (place-channel-get releaser)
    (resources-sync! r)))
