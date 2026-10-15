#lang racket/base

(require (only-in rackunit check-equal? test-case)
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
  (check-equal? ((element-converter 'f 'float32) 1/4) 0.25)
  (check-equal? ((element-converter 'f 'float64) 3) 3.0)
  (check-equal? ((element-converter 'f 'int32) -2.9) -2)
  (check-equal? ((element-converter 'f 'int64) 7) 7))

(test-case "packing follows the strides, and unpacking reads them back"
  (define rows '((1 2 3) (4 5 6)))
  (for ([dtype (in-list '(float32 float64 int32 int64))])
    (define converted
      (for/list ([row (in-list rows)])
        (map (element-converter 'f dtype) row)))
    (define col (pack-matrix 'f dtype '(2 3) '(1 2) rows))
    (check-equal? (unpack-vector dtype 6 col) (apply append (apply map list converted)))
    (check-equal? (unpack-matrix dtype '(2 3) '(1 2) col) converted)
    (define row (pack-matrix 'f dtype '(2 3) '(3 1) rows))
    (check-equal? (unpack-matrix dtype '(2 3) '(3 1) row) converted)))

(test-case "the packers never write past the shape they were given"
  (define host (pack-vector 'f 'int64 2 '(1 2 3 4)))
  (check-equal? (unpack-vector 'int64 2 host) '(1 2))
  (define m (pack-matrix 'f 'int32 '(1 2) '(2 1) '((1 2 3) (4 5 6))))
  (check-equal? (unpack-matrix 'int32 '(1 2) '(2 1) m) '((1 2))))

(test-case "a finite value that overflows a float type raises; an infinite one passes"
  (check-raft-error 'logic
                    "f: 1e+300 does not fit float32"
                    (lambda () ((element-converter 'f 'float32) 1e300)))
  (check-equal? ((element-converter 'f 'float32) +inf.0) +inf.0)
  (check-equal? ((element-converter 'f 'float64) 1e300) 1e300)
  (check-equal? ((element-converter 'f 'float32) 0.1) 0.10000000149011612))

(test-case "a value the dtype cannot hold raises, naming the caller"
  (check-raft-error 'logic
                    "f: 1099511627776 does not fit int32"
                    (lambda () (pack-vector 'f 'int32 1 (list (expt 2 40)))))
  (check-raft-error 'logic
                    "f: 2147483648 does not fit int32"
                    (lambda () ((element-converter 'f 'int32) (expt 2 31))))
  (check-equal? ((element-converter 'f 'int32) (- (expt 2 31))) (- (expt 2 31)))
  (check-raft-error 'logic
                    "f: +nan.0 is not a finite number"
                    (lambda () ((element-converter 'f 'int64) +nan.0)))
  (check-raft-error 'logic
                    "f: -inf.0 is not a finite number"
                    (lambda () ((element-converter 'f 'int64) -inf.0)))
  (check-raft-error 'logic
                    "f: 1+2i is not a real number"
                    (lambda () ((element-converter 'f 'float64) 1+2i)))
  (check-raft-error 'logic
                    "f: \"x\" is not a real number"
                    (lambda () ((element-converter 'f 'int32) "x"))))
