#lang racket/base
(require (only-in math/array array->vector build-array flarray-data)
         (only-in "typed-table.rkt" typed-flonums typed-table))

(define (median-ms thunk)
  (thunk)
  (define times
    (sort (for/list ([_ (in-range 5)])
            (collect-garbage 'minor)
            (define start (current-inexact-milliseconds))
            (thunk)
            (- (current-inexact-milliseconds) start))
          <))
  (list-ref times 2))

(define (untyped-table)
  (build-array (vector 1000 1000)
               (lambda (js) (exact->inexact (+ (* 1000 (vector-ref js 0)) (vector-ref js 1))))))

(printf "built and converted in Typed Racket: ~a ms\n"
        (median-ms (lambda () (flarray-data (typed-table 1000)))))
(printf "built untyped, array->vector from untyped: ~a ms\n"
        (median-ms (lambda () (array->vector (untyped-table)))))
(printf "built untyped, array->flarray in Typed Racket: ~a ms\n"
        (median-ms (lambda () (flarray-data (typed-flonums (untyped-table))))))
