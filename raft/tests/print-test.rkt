#lang racket/base

(require (only-in rackunit check-equal? test-case)
         (only-in "../private/print.rkt" array-text float32->string summarised?))

(test-case "float32 values print as the shortest decimal that reads back as them"
  (check-equal? (float32->string 0.10000000149011612) "0.1")
  (check-equal? (float32->string 5.099999904632568) "5.1")
  (check-equal? (float32->string 3.4028234663852886e38) "3.4028235e+38")
  (check-equal? (map float32->string (list 0.0 -0.0 +inf.0 +nan.0 1.0))
                '("0.0" "-0.0" "+inf.0" "+nan.0" "1.0")))

(test-case "arrays of up to 1000 elements print whole, larger ones by their edges"
  (check-equal? (summarised? '(10 100)) #f)
  (check-equal? (summarised? '(1001)) #t)
  (check-equal? (array-text 'int64 '(3) (lambda (i) (* 10 i))) "[ 0 10 20]")
  (check-equal? (array-text 'float64 '(2 2) (lambda (i j) (exact->inexact (+ i j))))
                "[[0.0 1.0]\n [1.0 2.0]]")
  (check-equal? (array-text 'int32 '(1001) values) "[   0    1    2 ...  998  999 1000]")
  (check-equal? (array-text 'int32 '(0 4) values) "[]"))
