#lang racket/base

(require (only-in rackunit check-true)
         (only-in "../main.rkt" contiguous device-matrix device-resources with-device-resources)
         (only-in "../private/array.rkt" release-array!)
         (only-in "../private/foreign/memory.rkt" resources-drop-count)
         (only-in "../private/resources.rkt" resources-sync!)
         (only-in "private/busy.rkt" call-with-busy-device)
         (only-in "private/collect.rkt" collect-until drain-finalizers!)
         (only-in "private/probe.rkt" test-probe)
         (only-in "private/ticker.rkt" call-with-ticker))

(define busy-seconds 2)
(define watched-seconds 0.3)
(define tick-ms 10)

(define (now)
  (current-inexact-monotonic-milliseconds))

(define (made-cublas! r)
  (define m (device-matrix 64 64 #:layout 'col-major #:resources r))
  (define c (contiguous m))
  (resources-sync! r)
  (release-array! c)
  (release-array! m))

(define (watch thunk)
  (define start (now))
  (define-values (ticks result) (call-with-ticker thunk))
  (values (>= ticks (/ (- (now) start) tick-ms 2)) ticks result))

(test-probe "releasing resources whose handle made cuBLAS returns while the device is busy"
  (define cublas (device-resources))
  (made-cublas! cublas)
  (define-values (ticking? ticks exit-ms)
    (call-with-busy-device (device-resources)
                           busy-seconds
                           (lambda ()
                             (watch (lambda ()
                                      (define start (now))
                                      (with-device-resources ([r cublas])
                                        (void))
                                      (begin0 (- (now) start)
                                        (sleep watched-seconds)))))))
  (check-true (< exit-ms 100) (format "the release took ~a ms" exit-ms))
  (check-true ticking? (format "the ticker advanced ~a times" ticks)))

(test-probe "finalizing resources whose handle made cuBLAS does not freeze the place"
  (drain-finalizers!)
  (define before (resources-drop-count))
  (define kept (box (device-resources)))
  (made-cublas! (unbox kept))
  (define-values (ticking? ticks _)
    (call-with-busy-device (device-resources)
                           busy-seconds
                           (lambda ()
                             (watch (lambda ()
                                      (set-box! kept #f)
                                      (collect-garbage 'major)
                                      (sleep watched-seconds))))))
  (check-true ticking? (format "the ticker advanced ~a times" ticks))
  (check-true (collect-until (lambda () (> (resources-drop-count) before)))))
