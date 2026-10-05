#lang racket/base

(require (only-in rackunit check-equal? check-exn test-case)
         (only-in "../private/pack.rkt"
                  element-converter
                  infer-dtype
                  matrix-shape
                  pack-matrix
                  pack-vector
                  unpack-matrix
                  unpack-vector)
         (only-in "private/raft-error.rkt" check-raft-error))

(test-case "inference: exact integers give int64, other reals float64, an empty list float64"
  (check-equal? (infer-dtype 'f '(1 2 -3)) 'int64)
  (check-equal? (infer-dtype 'f '(1 2.0)) 'float64)
  (check-equal? (infer-dtype 'f '(1/3)) 'float64)
  (check-equal? (infer-dtype 'f '()) 'float64)
  (check-raft-error 'logic
                    "f: cannot infer a dtype: \"x\" is not a real number"
                    (lambda () (infer-dtype 'f '(1 "x")))))

(test-case "a matrix's shape comes from its rows, and a ragged row is named"
  (check-equal? (matrix-shape 'f '((1 2 3) (4 5 6))) '(2 3))
  (check-equal? (matrix-shape 'f '()) '(0 0))
  (check-equal? (matrix-shape 'f '(() ())) '(2 0))
  (check-raft-error 'logic
                    "f: row 1 has 3 elements, but row 0 has 2: '(3 4 5)"
                    (lambda () (matrix-shape 'f '((1 2) (3 4 5))))))

(test-case "elements convert as NumPy casts them"
  (check-equal? ((element-converter 'float32) 1/4) 0.25)
  (check-equal? ((element-converter 'float64) 3) 3.0)
  (check-equal? ((element-converter 'int32) -2.9) -2)
  (check-equal? ((element-converter 'int64) 7) 7))

(test-case "packing follows the strides, and unpacking reads them back"
  (define rows '((1 2 3) (4 5 6)))
  (for ([dtype (in-list '(float32 float64 int32 int64))])
    (define converted
      (for/list ([row (in-list rows)])
        (map (element-converter dtype) row)))
    (define col (pack-matrix dtype '(2 3) '(1 2) rows))
    (check-equal? (unpack-vector dtype 6 col) (apply append (apply map list converted)))
    (check-equal? (unpack-matrix dtype '(2 3) '(1 2) col) converted)
    (define row (pack-matrix dtype '(2 3) '(3 1) rows))
    (check-equal? (unpack-matrix dtype '(2 3) '(3 1) row) converted)))

(test-case "the packers never write past the shape they were given"
  (define host (pack-vector 'int64 2 '(1 2 3 4)))
  (check-equal? (unpack-vector 'int64 2 host) '(1 2))
  (define m (pack-matrix 'int32 '(1 2) '(2 1) '((1 2 3) (4 5 6))))
  (check-equal? (unpack-matrix 'int32 '(1 2) '(2 1) m) '((1 2))))

(test-case "a value an integer dtype cannot hold raises instead of being written"
  (check-exn exn:fail? (lambda () (pack-vector 'int32 1 (list (expt 2 40))))))
