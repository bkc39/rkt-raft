#lang racket/base

(provide call-with-ticker)

(define (call-with-ticker thunk)
  (define ticker
    (thread (lambda ()
              (let loop ([ticks 0])
                (if (sync/timeout 0.01 (thread-receive-evt))
                    ticks
                    (loop (add1 ticks)))))
            #:keep 'results))
  (call-with-values thunk
                    (lambda results
                      (thread-send ticker 'stop)
                      (apply values (thread-wait ticker) results))))
