#lang typed/racket/base
(require math/array)
(provide typed-table
         typed-flonums)

(: typed-table (-> Index FlArray))
(define (typed-table n)
  (array->flarray (build-array (vector n n)
                               (lambda ([js : Indexes])
                                 (exact->inexact (+ (* 1000 (vector-ref js 0)) (vector-ref js 1)))))))

(: typed-flonums (-> (Array Real) FlArray))
(define (typed-flonums arr)
  (array->flarray arr))
