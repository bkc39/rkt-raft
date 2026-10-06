#lang racket/base

(require (only-in racket/match match-define)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path
         (only-in rackunit check-equal?)
         (only-in "../compat.rkt" list*->device-array vector->device-vector)
         (only-in "../main.rkt" dtype list*->device-matrix shape)
         (only-in "private/arrays.rkt" storage)
         (only-in "private/python-env.rkt" run-twin test-twin)
         (only-in "private/representations.rkt"
                  sink-back
                  sink-holds
                  sink-name
                  sink-rank
                  sink-rows
                  sinks
                  source-holds
                  source-name
                  source-rank
                  source-send
                  sources))

(define-runtime-path twin "python/compat.py")

(define all-dtypes '(float32 float64 int32 int64))
(define orders (hasheq 'row-major "C" 'col-major "F"))

(define float-rows '((1.5 -2.25 3.0 0.1) (1e10 -0.5 7.0 123456.789) (8.0 -9.5 10.25 1e-3)))
(define integer-rows '((1 -2 3 4) (2147483647 -2147483648 0 7) (8 9 10 11)))
(define truncating-rows '((1.7 -1.7 2.5 -2.5) (0.9 -0.9 100.25 -3.0) (6.0 7.5 8.0 -9.99)))

(define (rows-for src d)
  (define rows
    (cond
      [(memq d '(float32 float64)) float-rows]
      [(memq (source-name src) '(flarray flvector f64vector f32vector)) truncating-rows]
      [else integer-rows]))
  (define held
    (for/list ([row (in-list rows)])
      (map (source-holds src) row)))
  (if (= (source-rank src) 1)
      (list (car held))
      held))

(define (twin-data src rows)
  (if (= (source-rank src) 1)
      (car rows)
      rows))

(define (results cases)
  (hash-ref (run-twin twin (hasheq 'cases cases)) 'results))

(define plans
  (for*/list ([src (in-list sources)]
              [d (in-list all-dtypes)]
              [order (in-list '(row-major col-major))])
    (list src d order (rows-for src d))))

(test-twin "every source packs what np.asarray(nested, dtype) then device_ndarray holds"
  (define cases
    (for/list ([plan (in-list plans)])
      (match-define (list src d order rows) plan)
      (hasheq 'data (twin-data src rows) 'dtype (symbol->string d) 'order (hash-ref orders order))))
  (for ([plan (in-list plans)]
        [result (in-list (results cases))])
    (match-define (list src d order rows) plan)
    (define label (format "~a ~a ~a" (source-name src) d order))
    (define a ((source-send src) rows (length (car rows)) d order))
    (check-equal? (shape a) (hash-ref result 'shape) label)
    (check-equal? (symbol->string (dtype a)) (hash-ref result 'dtype) label)
    (check-equal? (storage a) (hash-ref result 'storage) label)))

(test-twin "every sink brings back what copy_to_host().tolist() does"
  (define (rows-for-sink snk d)
    (define rows (if (memq d '(float32 float64)) float-rows integer-rows))
    (if (= (sink-rank snk) 1)
        (list (car rows))
        rows))
  (define sink-plans
    (for*/list ([snk (in-list sinks)]
                [d (in-list all-dtypes)]
                [order (in-list '(row-major col-major))])
      (list snk d order (rows-for-sink snk d))))
  (define cases
    (for/list ([plan (in-list sink-plans)])
      (match-define (list snk d order rows) plan)
      (hasheq 'data rows 'dtype (symbol->string d) 'order (hash-ref orders order))))
  (for ([plan (in-list sink-plans)]
        [result (in-list (results cases))])
    (match-define (list snk d order rows) plan)
    (define label (format "~a ~a ~a" (sink-name snk) d order))
    (define a
      (if (= (sink-rank snk) 1)
          (vector->device-vector (list->vector (car rows)) #:dtype d)
          (list*->device-matrix rows #:dtype d #:layout order)))
    (define twin-values
      (for/list ([row (in-list (hash-ref result 'values))])
        (map (sink-holds snk) row)))
    (check-equal? ((sink-rows snk) ((sink-back snk) a) d) twin-values label)))

(test-twin "inference and rank match np.asarray"
  (define inputs '((1 2 3) (1 2.5) ((1 2) (3 4)) ((1.0 2.0)) () (() ())))
  (define cases
    (for/list ([data (in-list inputs)])
      (hasheq 'data data 'dtype 'null 'order "C")))
  (for ([data (in-list inputs)]
        [result (in-list (results cases))])
    (define a (list*->device-array data))
    (check-equal? (shape a) (hash-ref result 'shape) (format "~a" data))
    (check-equal? (symbol->string (dtype a)) (hash-ref result 'dtype) (format "~a" data))))
