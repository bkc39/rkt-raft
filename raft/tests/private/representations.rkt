#lang racket/base

(require (only-in ffi/vector f32vector->list f64vector->list list->f32vector list->f64vector)
         (only-in math/array :: array->flarray array->list* array-axis-swap array-slice-ref build-array vector->array)
         (only-in racket/flonum flsingle for/flvector in-flvector)
         (only-in racket/list append*)
         (only-in racket/math exact-truncate)
         (only-in "../../compat.rkt"
                  array->device-array
                  bytes->device-vector
                  device-array->array
                  device-array->list*
                  device-array->vector*
                  device-matrix->list*
                  device-matrix->matrix
                  device-matrix->vector*
                  device-vector->bytes
                  device-vector->col-matrix
                  device-vector->f32vector
                  device-vector->f64vector
                  device-vector->flvector
                  device-vector->list
                  device-vector->row-matrix
                  device-vector->vector
                  f32vector->device-vector
                  f64vector->device-vector
                  flvector->device-vector
                  list*->device-array
                  list*->device-matrix
                  list->device-vector
                  matrix->device-matrix
                  matrix->device-vector
                  vector*->device-array
                  vector*->device-matrix
                  vector->device-vector))

(provide (struct-out sink)
         (struct-out source)
         bytes->numbers
         converted
         numbers->bytes
         sinks
         sources)

(struct source (name rank holds send))

(struct sink (name rank back rows holds))

(define (converted dtype x)
  (case dtype
    [(float64) (real->double-flonum x)]
    [(float32) (flsingle (real->double-flonum x))]
    [else (exact-truncate x)]))

(define itemsizes (hasheq 'float32 4 'float64 8 'int32 4 'int64 8))

(define (float? dtype)
  (memq dtype '(float32 float64)))

(define (numbers->bytes dtype xs)
  (define size (hash-ref itemsizes dtype))
  (apply bytes-append
         (for/list ([x (in-list xs)])
           (if (float? dtype)
               (real->floating-point-bytes x size)
               (integer->integer-bytes x size #t)))))

(define (bytes->numbers dtype bs)
  (define size (hash-ref itemsizes dtype))
  (for/list ([start (in-range 0 (bytes-length bs) size)])
    (if (float? dtype)
        (floating-point-bytes->real bs (system-big-endian?) start (+ start size))
        (integer-bytes->integer bs #t (system-big-endian?) start (+ start size)))))

(define (rows->vector* rows)
  (for/vector ([row (in-list rows)])
    (list->vector row)))

(define (vector*->rows v)
  (for/list ([row (in-vector v)])
    (vector->list row)))

(define (mutable-array rows cols)
  (vector->array (vector (length rows) cols) (list->vector (append* rows))))

(define (lazy-array rows cols)
  (define flat (list->vector (append* rows)))
  (build-array (vector (length rows) cols)
               (lambda (js) (vector-ref flat (+ (* (vector-ref js 0) cols) (vector-ref js 1))))))

(define (sliced-array rows cols)
  (define wider
    (for/list ([row (in-list rows)])
      (append row '(-1 -2))))
  (array-slice-ref (array->flarray (mutable-array wider (+ cols 2))) (list (::) (:: 0 cols))))

(define (transposed-array rows cols)
  (if (null? rows)
      (mutable-array '() cols)
      (array-axis-swap (mutable-array (apply map list rows) (length rows)) 0 1)))

(define (flonum-array rows cols)
  (array->flarray (mutable-array rows cols)))

(define (ignoring-cols f)
  (lambda (rows _cols) (f rows)))

(define (rank-1-array xs)
  (vector->array (vector (length xs)) (list->vector xs)))

(define (row-matrix xs)
  (vector->array (vector 1 (length xs)) (list->vector xs)))

(define (col-matrix xs)
  (vector->array (vector (length xs) 1) (list->vector xs)))

(define (list->flvector xs)
  (for/flvector #:length (length xs) ([x (in-list xs)]) (real->double-flonum x)))

(define (flvector->list v)
  (for/list ([x (in-flvector v)])
    x))

(define (single x)
  (flsingle (real->double-flonum x)))

(define (send-matrix make-value send)
  (lambda (rows cols dtype layout) (send (make-value rows cols) #:dtype dtype #:layout layout)))

(define (send-vector make-value send)
  (lambda (rows _cols dtype _layout) (send (make-value (car rows)) #:dtype dtype)))

(define (send-bytes rows _cols dtype _layout)
  (define xs
    (for/list ([x (in-list (car rows))])
      (converted dtype x)))
  (bytes->device-vector (numbers->bytes dtype xs) #:dtype dtype))

(define sources
  (list
   (source 'list* 2 values (send-matrix (ignoring-cols values) list*->device-matrix))
   (source 'list*-array 2 values (send-matrix (ignoring-cols values) list*->device-array))
   (source 'vector* 2 values (send-matrix (ignoring-cols rows->vector*) vector*->device-matrix))
   (source 'vector*-array 2 values (send-matrix (ignoring-cols rows->vector*) vector*->device-array))
   (source 'matrix 2 values (send-matrix mutable-array matrix->device-matrix))
   (source 'array 2 values (send-matrix mutable-array array->device-array))
   (source 'lazy-array 2 values (send-matrix lazy-array array->device-array))
   (source 'flarray 2 real->double-flonum (send-matrix flonum-array array->device-array))
   (source 'sliced-flarray 2 real->double-flonum (send-matrix sliced-array array->device-array))
   (source 'transposed-array 2 values (send-matrix transposed-array array->device-array))
   (source 'list 1 values (send-vector values list->device-vector))
   (source 'list-array 1 values (send-vector values list*->device-array))
   (source 'vector 1 values (send-vector list->vector vector->device-vector))
   (source 'vector-array 1 values (send-vector list->vector vector*->device-array))
   (source 'flvector 1 real->double-flonum (send-vector list->flvector flvector->device-vector))
   (source 'f64vector 1 real->double-flonum (send-vector list->f64vector f64vector->device-vector))
   (source 'f32vector 1 single (send-vector list->f32vector f32vector->device-vector))
   (source 'array1 1 values (send-vector rank-1-array array->device-array))
   (source 'row-matrix 1 values (send-vector row-matrix matrix->device-vector))
   (source 'col-matrix 1 values (send-vector col-matrix matrix->device-vector))
   (source 'bytes 1 values send-bytes)))

(define (one-row f)
  (lambda (v _dtype) (list (f v))))

(define (ignoring-dtype f)
  (lambda (v _dtype) (f v)))

(define sinks
  (list
   (sink 'list* 2 device-matrix->list* (ignoring-dtype values) values)
   (sink 'list*-array 2 device-array->list* (ignoring-dtype values) values)
   (sink 'vector* 2 device-matrix->vector* (ignoring-dtype vector*->rows) values)
   (sink 'vector*-array 2 device-array->vector* (ignoring-dtype vector*->rows) values)
   (sink 'matrix 2 device-matrix->matrix (ignoring-dtype array->list*) values)
   (sink 'array 2 device-array->array (ignoring-dtype array->list*) values)
   (sink 'list 1 device-vector->list (one-row values) values)
   (sink 'list-array 1 device-array->list* (one-row values) values)
   (sink 'vector 1 device-vector->vector (one-row vector->list) values)
   (sink 'vector-array 1 device-array->vector* (one-row vector->list) values)
   (sink 'flvector 1 device-vector->flvector (one-row flvector->list) real->double-flonum)
   (sink 'f64vector 1 device-vector->f64vector (one-row f64vector->list) real->double-flonum)
   (sink 'f32vector 1 device-vector->f32vector (one-row f32vector->list) single)
   (sink 'array1 1 device-array->array (one-row array->list*) values)
   (sink 'row-matrix 1 device-vector->row-matrix (ignoring-dtype array->list*) values)
   (sink 'col-matrix
         1
         device-vector->col-matrix
         (ignoring-dtype (lambda (a) (list (map car (array->list* a)))))
         values)
   (sink 'bytes 1 device-vector->bytes (lambda (bs dtype) (list (bytes->numbers dtype bs))) values)))
