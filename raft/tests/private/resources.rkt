#lang racket/base

(require (only-in "../../core.rkt" device-resources with-device-resources))

(provide released-resources)

(define (released-resources)
  (with-device-resources ([r (device-resources)]) r))
