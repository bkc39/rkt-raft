#lang scribble/manual
@(require "../utils.rkt")

@(define ev (make-raft-eval))

@examples[#:eval ev #:hidden
(require ffi/vector
         math/array
         math/matrix
         racket/file
         racket/port
         raft/compat)
]

@title[#:tag "moving-data"]{Moving data between Racket and the GPU}

This chapter follows one program that puts its inputs on the GPU in the form
cuML takes, from a text file, a @racketmodname[math/matrix] matrix and an
@racket[f64vector], and brings results back. The cuML calls themselves come
later @status{L1d}. The conversions come from @racketmodname[raft/compat]:

@racketblock[
(require raft raft/compat
         math/matrix math/array ffi/vector
         racket/file racket/list racket/port racket/string)
]

@section[#:tag "moving-data-rows"]{Rows from a text file}

Six iris flowers, four numbers and a species per line; a string port stands
for the file:

@examples[#:eval ev #:label #f
(define csv
  (string-append "sepal_length,sepal_width,petal_length,petal_width,species\n"
                 "5.1,3.5,1.4,0.2,setosa\n"
                 "4.9,3.0,1.4,0.2,setosa\n"
                 "7.0,3.2,4.7,1.4,versicolor\n"
                 "6.4,3.2,4.5,1.5,versicolor\n"
                 "6.3,3.3,6.0,2.5,virginica\n"
                 "5.8,2.7,5.1,1.9,virginica\n"))
(define table
  (for/list ([line (in-list (cdr (port->lines (open-input-string csv))))])
    (string-split line ",")))
(define rows
  (for/list ([fields (in-list table)])
    (map string->number (take fields 4))))
(define X (list*->device-array rows #:dtype 'float32))
X
]

@racket[list*->device-array] reads the rank from the nesting: a list of rows
is a matrix. The species become @racket['int32] labels, numbered in order of
appearance:

@examples[#:eval ev #:label #f
(define species (map last table))
(define names (remove-duplicates species))
(define labels
  (vector->device-vector (for/vector ([s (in-list species)])
                           (index-of names s))
                         #:dtype 'int32))
labels
]

@section[#:tag "moving-data-dtype"]{Choosing float32 for cuML}

Without @racket[#:dtype], the element type is inferred: @racket['int64] for
exact integers, @racket['float64] otherwise:

@examples[#:eval ev #:label #f
(dtype (list*->device-array rows))
(dtype (list*->device-array '((1 2) (3 4))))
]

The program asked for @racket['float32], which consumer GPUs run far faster
than @racket['float64], in half the memory. Values come back
as the nearest @racket['float32], widened to a flonum:

@examples[#:eval ev #:label #f
(first (device-array->list* X))
]

@section[#:tag "moving-data-matrix"]{A matrix computed on the host}

The features' covariance, computed on the host with
@racketmodname[math/matrix]:

@examples[#:eval ev #:label #f
(define M (list*->matrix rows))
(define n (matrix-num-rows M))
(define means (matrix-scale (matrix* (make-matrix 1 n 1) M) (/ 1.0 n)))
(define centered (matrix- M (matrix* (make-matrix n 1 1) means)))
(define covariance
  (matrix-scale (matrix* (matrix-transpose centered) centered) (/ 1.0 (sub1 n))))
(define C (matrix->device-matrix covariance #:dtype 'float32))
C
]

It comes back as a @racketmodname[math/array] flonum array, off only by the
@racket['float32] rounding:

@examples[#:eval ev #:label #f
(define C* (device-matrix->matrix C))
(array-shape C*)
(< (array-all-max (array-abs (array- C* covariance))) 1e-6)
]

A @racket[matrix*] result is read element by element through a Typed Racket contract (@secref["moving-data-speed"]).

@section[#:tag "moving-data-ffi"]{Weights from foreign code}

Per-flower weights come from a C routine that fills an @racket[f64vector]
through the FFI; a loop stands in for it. cuML wants them in the data's type:

@examples[#:eval ev #:label #f
(define weights (make-f64vector n))
(for ([i (in-range n)])
  (f64vector-set! weights i (if (< i 2) 2.0 1.0)))
(define w (f64vector->device-vector weights #:dtype 'float32))
w
]

Narrowing to @racket['float32] raises on a value too large rather than giving
an infinity.

@section[#:tag "moving-data-layout"]{A layout for the solver}

cuML's @tt{LinearRegression} reads column-major input, so the features are
packed by column on the way up, from a list or a matrix:

@examples[#:eval ev #:label #f
(define F (list*->device-array rows #:dtype 'float32 #:layout 'col-major))
(list (contiguous? F #:layout 'col-major) (strides F))
(define F* (matrix->device-matrix M #:dtype 'float32 #:layout 'col-major))
(equal? (device-array->list* F) (device-array->list* F*))
]

Strides count elements. On the device,
@racket[contiguous] changes the layout (@secref["arrays-layout"]).

@section[#:tag "moving-data-back"]{Results back in Racket}

Each conversion names the Racket form it makes, and waits for the work queued
on the array's stream. Column means through @racketmodname[math/array]:

@examples[#:eval ev #:label #f
(define X* (device-array->array X))
(array-scale (array-axis-sum X* 0) (/ 1.0 n))
]

Species counts from a vector:

@examples[#:eval ev #:label #f
(define counts (make-vector (length names) 0))
(for ([label (in-vector (device-vector->vector labels))])
  (vector-set! counts label (add1 (vector-ref counts label))))
counts
]

Weights saved as raw bytes and read back:

@examples[#:eval ev #:label #f
(define saved (make-temporary-file))
(display-to-file (device-vector->bytes w) saved #:exists 'truncate)
(file-size saved)
(device-vector->list (bytes->device-vector (file->bytes saved) #:dtype 'float32))
]

@examples[#:eval ev #:hidden
(delete-file saved)
]

@section[#:tag "moving-data-speed"]{What each form costs}

Milliseconds per million elements, median of five runs
(@tt{bench/conversions.rkt}, RTX 3090 Ti, Racket 9.3 CS, 2026-10-05):

@(define speed-rows
   '(("list" "33.5" "32.6" "51.0" "49.6")
     ("list, by list*->device-array" "38.2" "35.4" "48.4" "50.7")
     ("vector" "32.2" "30.6" "35.1" "30.1")
     ("flvector" "0.8" "35.9" "3.8" "63.2")
     ("f64vector" "4.0" "44.3" "12.2" "52.2")
     ("f32vector" "44.3" "1.8" "51.3" "3.3")
     ("bytes" "0.8" "0.4" "3.8" "1.9")
     ("math FlArray" "1.1" "31.3" "4.1" "55.9")
     ("math mutable array" "32.4" "30.7" "—" "—")
     ("math array from build-array" "558.8" "567.2" "—" "—")
     ("nested list, 1000×1000" "49.3" "50.0" "52.7" "52.7")
     ("nested vector, 1000×1000" "36.1" "38.2" "42.5" "41.1")
     ("math FlArray, 1000×1000" "1.0" "31.0" "3.9" "57.1")
     ("math mutable array, 1000×1000" "33.6" "35.1" "—" "—")))

@tabular[#:style 'boxed
         #:sep @hspace[2]
         #:column-properties '(left right right right right)
         #:row-properties '(bottom-border ())
         (cons (list @bold{Racket value}
                     @bold{to float64}
                     @bold{to float32}
                     @bold{back from float64}
                     @bold{back from float32})
               speed-rows)]

Every @racketmodname[math/array] array comes back through
@racket[device-array->array]; a dash means the same time as the flonum array.

@itemlist[
 @item{Storage that matches the element type crosses in one copy, 1 to 4 ms:
       an @racket[flvector] or flonum array as @racket['float64], bytes as
       anything; an @racket[f32vector] or @racket[f64vector] in its own type
       takes one more host copy.}
 @item{Lists and vectors cost 35 to 55 ns an element; for large data, build
       an @racket[flvector] or @racket[f32vector] in the first place.}
 @item{Changing the element type on the way costs 30 to 60 ms, so keep data
       in the type it is used in: for cuML, @racket['float32].}
 @item{Any other @racketmodname[math/array] array, such as one from
       @racket[build-array] or @racketmodname[math/matrix], is read through
       a Typed Racket contract, about 0.6 µs an element. To avoid it, build
       the array in Typed Racket and call @racket[array->flarray] there:
       80 ms for 1000×1000 against 710 (@tt{bench/typed-arrays.rkt}).}]
