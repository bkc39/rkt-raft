#lang racket/base

(require (only-in racket/string string-split)
         (only-in rackunit check-equal? check-true test-case)
         (only-in "../private/print.rkt" array-text float32->string summarised?))

(define (counting-ref)
  (define reads 0)
  (values (lambda indices
            (set! reads (add1 reads))
            (apply + indices))
          (lambda () reads)))

(test-case "float32 values print as the shortest decimal that reads back as them"
  (check-equal? (float32->string 0.10000000149011612) "0.1")
  (check-equal? (float32->string 5.099999904632568) "5.1")
  (check-equal? (float32->string 3.4028234663852886e38) "3.4028235e+38")
  (check-equal? (map float32->string (list 0.0 -0.0 +inf.0 +nan.0 1.0))
                '("0.0" "-0.0" "+inf.0" "+nan.0" "1.0")))

(test-case "arrays of up to 1000 elements print whole, larger ones by their edges"
  (check-equal? (summarised? '(10 20)) #f)
  (check-equal? (summarised? '(1001)) #t)
  (check-equal? (array-text 'int64 '(3) (lambda (i) (* 10 i))) "[ 0 10 20]")
  (check-equal? (array-text 'float64 '(2 2) (lambda (i j) (exact->inexact (+ i j))))
                "[[0.0 1.0]\n [1.0 2.0]]")
  (check-equal? (array-text 'int32 '(1001) values) "[   0    1    2 ...  998  999 1000]")
  (check-equal? (array-text 'int32 '(0 4) values) "[]"))

(test-case "an axis longer than 20 prints by its edges whatever the element count"
  (check-equal? (summarised? '(20)) #f)
  (check-equal? (summarised? '(21)) #t)
  (check-equal? (array-text 'int32 '(20) values)
                "[ 0  1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16 17 18 19]")
  (check-equal? (array-text 'int32 '(21) values) "[ 0  1  2 ... 18 19 20]")
  (check-equal? (summarised? '(1000)) #t)
  (check-equal? (array-text 'int32 '(1000) values) "[  0   1   2 ... 997 998 999]")
  (check-equal? (array-text 'int32 '(500 2) +)
                "[[  0   1]\n [  1   2]\n [  2   3]\n ...\n [497 498]\n [498 499]\n [499 500]]")
  (check-equal? (array-text 'int32 '(2 500) +)
                "[[  0   1   2 ... 497 498 499]\n [  1   2   3 ... 498 499 500]]")
  (check-equal? (summarised? '(10 100)) #t))

(test-case "a summarised array reads only the elements it shows"
  (define-values (ref reads) (counting-ref))
  (define text (array-text 'int64 '(1000 1000) ref))
  (check-true (<= (length (string-split text "\n")) 7))
  (check-equal? (reads) 36)
  (define-values (ref* reads*) (counting-ref))
  (array-text 'float32 '(500 2) ref*)
  (check-equal? (reads*) 12))
