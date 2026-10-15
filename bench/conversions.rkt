#lang racket/base

(require (only-in ffi/vector list->f32vector list->f64vector)
         (only-in math/array array->flarray build-array vector->array)
         (only-in racket/flonum for/flvector)
         (only-in racket/format ~r)
         (only-in racket/list append*)
         (only-in racket/match match-define)
         (only-in raft
                  device-matrix->list*
                  device-vector->list
                  list*->device-matrix
                  list->device-vector)
         (only-in raft/compat
                  array->device-array
                  bytes->device-vector
                  device-array->array
                  device-array->list*
                  device-matrix->vector*
                  device-vector->bytes
                  device-vector->f32vector
                  device-vector->f64vector
                  device-vector->flvector
                  device-vector->vector
                  f32vector->device-vector
                  f64vector->device-vector
                  flvector->device-vector
                  list*->device-array
                  vector*->device-matrix
                  vector->device-vector))

(define n 1000000)
(define side 1000)
(define runs 5)

(define xs
  (for/list ([i (in-range n)])
    (exact->inexact (/ i 2))))
(define rows
  (for/list ([i (in-range side)])
    (for/list ([j (in-range side)])
      (exact->inexact (/ (+ (* i side) j) 2)))))

(define (median-ms thunk)
  (thunk)
  (define times
    (sort (for/list ([_ (in-range runs)])
            (collect-garbage 'minor)
            (define start (current-inexact-milliseconds))
            (thunk)
            (- (current-inexact-milliseconds) start))
          <))
  (list-ref times (quotient runs 2)))

(define (row name make send back)
  (define value (make))
  (define (to dtype)
    (median-ms (lambda () (send value dtype))))
  (define on-device (send value 'float64))
  (define on-device-32 (send value 'float32))
  (list name
        (to 'float64)
        (to 'float32)
        (median-ms (lambda () (back on-device)))
        (median-ms (lambda () (back on-device-32)))))

(define (flat-array)
  (vector->array (vector n) (list->vector xs)))

(define table
  (list
   (row "list" (lambda () xs) (lambda (v d) (list->device-vector v #:dtype d)) device-vector->list)
   (row "list, by list*->device-array"
        (lambda () xs)
        (lambda (v d) (list*->device-array v #:dtype d))
        device-array->list*)
   (row "vector"
        (lambda () (list->vector xs))
        (lambda (v d) (vector->device-vector v #:dtype d))
        device-vector->vector)
   (row "flvector"
        (lambda () (for/flvector #:length n ([x (in-list xs)]) x))
        (lambda (v d) (flvector->device-vector v #:dtype d))
        device-vector->flvector)
   (row "f64vector"
        (lambda () (list->f64vector xs))
        (lambda (v d) (f64vector->device-vector v #:dtype d))
        device-vector->f64vector)
   (row "f32vector"
        (lambda () (list->f32vector xs))
        (lambda (v d) (f32vector->device-vector v #:dtype d))
        device-vector->f32vector)
   (row "bytes"
        (lambda ()
          (define (packed size)
            (apply bytes-append (map (lambda (x) (real->floating-point-bytes x size)) xs)))
          (hasheq 'float64 (packed 8) 'float32 (packed 4)))
        (lambda (v d) (bytes->device-vector (hash-ref v d) #:dtype d))
        device-vector->bytes)
   (row "math FlArray"
        (lambda () (array->flarray (flat-array)))
        (lambda (v d) (array->device-array v #:dtype d))
        device-array->array)
   (row "math mutable array"
        flat-array
        (lambda (v d) (array->device-array v #:dtype d))
        device-array->array)
   (row "math array from build-array"
        (lambda ()
          (define data (list->vector xs))
          (build-array (vector n) (lambda (js) (vector-ref data (vector-ref js 0)))))
        (lambda (v d) (array->device-array v #:dtype d))
        device-array->array)
   (row "nested list 1000×1000"
        (lambda () rows)
        (lambda (v d) (list*->device-matrix v #:dtype d))
        device-matrix->list*)
   (row "nested vector 1000×1000"
        (lambda ()
          (for/vector ([r (in-list rows)])
            (list->vector r)))
        (lambda (v d) (vector*->device-matrix v #:dtype d))
        device-matrix->vector*)
   (row "math FlArray 1000×1000"
        (lambda () (array->flarray (vector->array (vector side side) (list->vector (append* rows)))))
        (lambda (v d) (array->device-array v #:dtype d))
        device-array->array)
   (row "math mutable array 1000×1000"
        (lambda () (vector->array (vector side side) (list->vector (append* rows))))
        (lambda (v d) (array->device-array v #:dtype d))
        device-array->array)))

(define (ms x)
  (~r x #:precision 1))

(displayln
 "| Racket value | to device, float64 | to device, float32 | back, float64 | back, float32 |")
(displayln "|---|---:|---:|---:|---:|")
(for ([r (in-list table)])
  (match-define (cons name times) r)
  (apply printf "| ~a | ~a | ~a | ~a | ~a |\n" name (map ms times)))
