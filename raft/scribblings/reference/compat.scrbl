#lang scribble/manual
@(require "../utils.rkt")

@(define ev (make-raft-eval))

@examples[#:eval ev #:hidden
(require ffi/vector
         json
         math/array
         math/matrix
         racket/file
         racket/vector
         raft/compat)
]

@title[#:tag "ref-compat"]{Conversions: @racketmodname[raft/compat]}

@defmodule[raft/compat]

Conversions between @tech{device arrays} and Racket data: the list and
@racket[flvector] conversions of @racketmodname[raft/array], plus vectors,
@racket[f32vector]s, @racket[f64vector]s, byte strings, and
@racketmodname[math/matrix] and @racketmodname[math/array] values.
@racketmodname[raft] does not re-export it, since it requires @tt{math-lib}.
See also @secref["moving-data"].

@tabular[#:style 'boxed
         #:sep @hspace[2]
         #:row-properties '(bottom-border ())
         (list (list @bold{Racket value} @bold{To the GPU} @bold{Back to Racket})
               (list "list"
                     @racket[list->device-vector]
                     @racket[device-vector->list])
               (list "nested lists"
                     @elem{@racket[list*->device-matrix], @racket[list*->device-array]}
                     @elem{@racket[device-matrix->list*], @racket[device-array->list*]})
               (list "vector"
                     @racket[vector->device-vector]
                     @racket[device-vector->vector])
               (list "nested vectors"
                     @elem{@racket[vector*->device-matrix], @racket[vector*->device-array]}
                     @elem{@racket[device-matrix->vector*], @racket[device-array->vector*]})
               (list @racket[flvector]
                     @racket[flvector->device-vector]
                     @racket[device-vector->flvector])
               (list @elem{@racket[f32vector], @racket[f64vector]}
                     @elem{@racket[f32vector->device-vector], @racket[f64vector->device-vector]}
                     @elem{@racket[device-vector->f32vector], @racket[device-vector->f64vector]})
               (list "byte string"
                     @racket[bytes->device-vector]
                     @racket[device-vector->bytes])
               (list @elem{@racketmodname[math/matrix] matrix}
                     @racket[matrix->device-matrix]
                     @racket[device-matrix->matrix])
               (list "row or column matrix"
                     @racket[matrix->device-vector]
                     @elem{@racket[device-vector->col-matrix], @racket[device-vector->row-matrix]})
               (list @elem{@racketmodname[math/array] array, rank 1 or 2}
                     @racket[array->device-array]
                     @racket[device-array->array]))]

@bold{The rules} are those of @secref["ref-array-convert"]. Without
@racket[#:dtype], the element type is inferred: exact
integers give @racket['int64], other reals and empty data @racket['float64];
an @racket[flvector], @racket[f64vector] or flonum array gives
@racket['float64], an @racket[f32vector] @racket['float32]. Exact rationals
give @racket['float64], and booleans and integers from
2@superscript{63} to 2@superscript{64}-1 are refused. Integer types truncate
toward zero. A value the type cannot hold (a complex number, an infinity or
NaN for an integer type, an out-of-range number) and a ragged row raise
@racket[exn:fail:raft]. @racket[#:layout] sets the packing order on the host.
Coming back, a conversion waits for the work queued on the array's stream;
floating-point elements become flonums, integers exact integers.

@bold{Rank.} Device arrays have one or two axes; any other inferred rank
raises @racket[exn:fail:raft]. Higher ranks arrive later @status{L3}.

@bold{Speed.} An @racket[flvector], flonum array or @racket[f64vector] sent as
@racket['float64], an @racket[f32vector] sent as @racket['float32], and a byte
string are copied as they are; everything else is packed element by element
(@secref["moving-data-speed"]).

@section[#:tag "ref-compat-nested"]{Vectors and nested data}

@defproc[(vector->device-vector [xs (vectorof real?)]
                                [#:dtype dtype (or/c #f 'float32 'float64 'int32 'int64) #f]
                                [#:resources resources device-resources?
                                             (current-device-resources)])
         device-vector?]{

Returns a vector of the elements of @racket[xs], of @racket[dtype] or the
inferred type.

@examples[#:eval ev
(vector->device-vector #(3 1 4 1 5))
(vector->device-vector #(0.5 1.5 2.5) #:dtype 'float32)
]

Weights in the type cuML takes:

@examples[#:eval ev #:label #f
(define weights
  (for/vector ([i (in-range 6)])
    (/ 1.0 (add1 i))))
(vector->device-vector weights #:dtype 'float32)
]

One column of a table of vector rows:

@examples[#:eval ev #:label #f
(define flowers
  (vector #("setosa" 5.1 3.5)
          #("versicolor" 7.0 3.2)
          #("virginica" 6.3 3.3)))
(define lengths (vector-map (lambda (row) (vector-ref row 1)) flowers))
(device-vector->list (vector->device-vector lengths))
]

A string is refused:

@examples[#:eval ev #:label #f
(eval:error (vector->device-vector (vector-map (lambda (row) (vector-ref row 0)) flowers)))
]}

@defproc[(device-vector->vector [v device-vector?]) (vectorof real?)]{

Returns the elements of @racket[v] as a new mutable vector:
@tt{v.copy_to_host().tolist()}.

@examples[#:eval ev
(device-vector->vector (vector->device-vector #(2 7 1 8)))
]

Cluster sizes from labels:

@examples[#:eval ev #:label #f
(define labels (vector->device-vector #(0 2 1 2 2 0) #:dtype 'int32))
(define counts (make-vector 3 0))
(for ([label (in-vector (device-vector->vector labels))])
  (vector-set! counts label (add1 (vector-ref counts label))))
counts
]

The best score and its index:

@examples[#:eval ev #:label #f
(define scores (device-vector->vector (vector->device-vector #(0.2 0.9 0.4))))
(define best (vector-argmax values scores))
(list best (vector-member best scores))
]}

@defproc[(vector*->device-matrix [rows (vectorof (vectorof real?))]
                                 [#:dtype dtype (or/c #f 'float32 'float64 'int32 'int64) #f]
                                 [#:layout layout (or/c 'row-major 'col-major) 'row-major]
                                 [#:resources resources device-resources?
                                              (current-device-resources)])
         device-matrix?]{

Like @racket[list*->device-matrix], for a vector of vector rows.

@examples[#:eval ev
(vector*->device-matrix #(#(1 2 3) #(4 5 6)))
]

A grid laid out by column:

@examples[#:eval ev #:label #f
(define grid
  (for/vector ([x (in-range 3)])
    (for/vector ([y (in-range 2)])
      (+ (* 0.5 x) y))))
(define G (vector*->device-matrix grid #:dtype 'float32 #:layout 'col-major))
(list (shape G) (contiguous? G #:layout 'col-major) (strides G))
]

A ragged row is refused:

@examples[#:eval ev #:label #f
(eval:error (vector*->device-matrix #(#(1.0 2.0) #(3.0))))
]}

@defproc[(device-matrix->vector* [m device-matrix?]) (vectorof (vectorof real?))]{

Returns the rows of @racket[m] as a vector of vectors, whatever its layout.

@examples[#:eval ev
(device-matrix->vector* (vector*->device-matrix #(#(1 2) #(3 4))))
]

One centroid of several:

@examples[#:eval ev #:label #f
(define centroids (vector*->device-matrix #(#(5.0 3.4) #(6.6 3.0) #(5.9 2.8))))
(vector-ref (device-matrix->vector* centroids) 1)
]

A column-major matrix still comes back as rows:

@examples[#:eval ev #:label #f
(device-matrix->vector* G)
]}

@defproc[(list*->device-array [xs (or/c (listof real?)
                                         (listof (or/c (listof real?) (vectorof real?))))]
                              [#:dtype dtype (or/c #f 'float32 'float64 'int32 'int64) #f]
                              [#:layout layout (or/c 'row-major 'col-major) 'row-major]
                              [#:resources resources device-resources?
                                           (current-device-resources)])
         device-array?]{

Returns a vector for a list of numbers and a matrix for a list of rows (lists
or vectors). If the first element is a row, every element must be one; a
deeper nesting is refused.
@racket['()] is an empty vector. @racket[layout] is ignored for a vector.

@examples[#:eval ev
(list*->device-array '(1.0 2.0 3.0))
(list*->device-array '((1 2) (3 4)))
]

One call for a series or a table:

@examples[#:eval ev #:label #f
(define (upload data)
  (list*->device-array data #:dtype 'float32))
(map shape (list (upload '(0.5 1.5)) (upload '((0.5 1.5) (2.5 3.5) (4.5 5.5)))))
]

@examples[#:eval ev #:label #f
(shape (list*->device-array '()))
]

Other nestings are refused:

@examples[#:eval ev #:label #f
(eval:error (list*->device-array '(((1 2) (3 4)))))
(eval:error (list*->device-array '(1.0 (2.0 3.0))))
]}

@defproc[(vector*->device-array [xs (or/c (vectorof real?)
                                           (vectorof (or/c (vectorof real?) (listof real?))))]
                                [#:dtype dtype (or/c #f 'float32 'float64 'int32 'int64) #f]
                                [#:layout layout (or/c 'row-major 'col-major) 'row-major]
                                [#:resources resources device-resources?
                                             (current-device-resources)])
         device-array?]{

Like @racket[list*->device-array], for a vector of numbers or of rows (vectors
or lists).

@examples[#:eval ev
(vector*->device-array #(1 2 3))
(vector*->device-array #(#(1 2) #(3 4)))
]

Data read back from a Racket literal:

@examples[#:eval ev #:label #f
(define saved (read (open-input-string "#(#(0.1 0.2) #(0.3 0.4) #(0.5 0.6))")))
(shape (vector*->device-array saved #:dtype 'float32))
]

A non-row element is refused:

@examples[#:eval ev #:label #f
(eval:error (vector*->device-array (vector #(1 2) 3)))
]}

@defproc[(device-array->list* [a device-array?])
         (or/c (listof real?) (listof (listof real?)))]{

Returns the elements of @racket[a] as a list, or a list of rows for a matrix:
@tt{a.copy_to_host().tolist()}.

@examples[#:eval ev
(device-array->list* (list*->device-array '(1 2 3)))
(device-array->list* (list*->device-array '((1 2) (3 4)) #:layout 'col-major))
]

Results as JSON, whatever their rank:

@examples[#:eval ev #:label #f
(define (results->json a)
  (jsexpr->string (hasheq 'shape (shape a) 'values (device-array->list* a))))
(results->json (list*->device-array '((1 2) (3 4)) #:dtype 'int32))
(results->json (vector->device-vector #(0.5 0.25)))
]

A sum over either rank:

@examples[#:eval ev #:label #f
(define (total a)
  (define xs (device-array->list* a))
  (apply + (if (device-matrix? a) (apply append xs) xs)))
(map total (list (list*->device-array '(1 2 3)) (list*->device-array '((1 2) (3 4)))))
]}

@defproc[(device-array->vector* [a device-array?])
         (or/c (vectorof real?) (vectorof (vectorof real?)))]{

Like @racket[device-array->list*], building vectors.

@examples[#:eval ev
(device-array->vector* (vector*->device-array #(1 2 3)))
(device-array->vector* (vector*->device-array #(#(1 2) #(3 4))))
]

Indexing a result:

@examples[#:eval ev #:label #f
(define table (device-array->vector* centroids))
(vector-ref (vector-ref table 2) 0)
]

Sorting the host copy leaves the device array unchanged:

@examples[#:eval ev #:label #f
(define distances (vector->device-vector #(2.5 0.5 1.5)))
(vector-sort (device-array->vector* distances) <)
(device-vector->list distances)
]}

@section[#:tag "ref-compat-packed"]{Packed numbers: f32vectors, f64vectors and bytes}

@defproc[(f32vector->device-vector [xs f32vector?]
                                   [#:dtype dtype (or/c 'float32 'float64 'int32 'int64) 'float32]
                                   [#:resources resources device-resources?
                                                (current-device-resources)])
         device-vector?]{

Returns a vector of the elements of @racket[xs], of @racket[dtype].

@examples[#:eval ev
(f32vector->device-vector (f32vector 0.5 1.5 2.5))
]

Single-precision samples from an audio decoder:

@examples[#:eval ev #:label #f
(define samples (make-f32vector 4 0.25))
(f32vector-set! samples 2 -0.75)
(define on-gpu (f32vector->device-vector samples))
(list (dtype on-gpu) (device-vector->list on-gpu))
]

Widened, or truncated to integers:

@examples[#:eval ev #:label #f
(device-vector->list (f32vector->device-vector (f32vector 0.1 2.7) #:dtype 'float64))
(device-vector->list (f32vector->device-vector (f32vector 0.1 2.7) #:dtype 'int32))
]}

@defproc[(f64vector->device-vector [xs f64vector?]
                                   [#:dtype dtype (or/c 'float32 'float64 'int32 'int64) 'float64]
                                   [#:resources resources device-resources?
                                                (current-device-resources)])
         device-vector?]{

Returns a vector of the elements of @racket[xs], of @racket[dtype]. A value
too large for @racket['float32] raises @racket[exn:fail:raft].

@examples[#:eval ev
(f64vector->device-vector (f64vector 1.0 2.0 3.0))
]

Readings a C library filled, narrowed for cuML:

@examples[#:eval ev #:label #f
(define readings (list->f64vector '(21.5 21.75 22.0 22.5)))
(f64vector->device-vector readings #:dtype 'float32)
]

Doubles sent as integers:

@examples[#:eval ev #:label #f
(dtype (f64vector->device-vector (f64vector 3.0 0.0 12.0) #:dtype 'int64))
]}

@defproc[(device-vector->f32vector [v device-vector?]) f32vector?]{

Returns the elements of @racket[v] as a new @racket[f32vector]. A
@racket['float64] value too large for @racket['float32] raises
@racket[exn:fail:raft].

@examples[#:eval ev
(f32vector->list (device-vector->f32vector (f32vector->device-vector (f32vector 0.5 1.5))))
]

For a C library that takes @tt{float*}:

@examples[#:eval ev #:label #f
(define out (device-vector->f32vector (vector->device-vector #(0.1 0.2))))
(list (f32vector-length out) (f32vector-ref out 0))
]

Integer labels as floats:

@examples[#:eval ev #:label #f
(f32vector->list (device-vector->f32vector labels))
]}

@defproc[(device-vector->f64vector [v device-vector?]) f64vector?]{

Returns the elements of @racket[v] as a new @racket[f64vector].

@examples[#:eval ev
(f64vector->list (device-vector->f64vector (f64vector->device-vector readings)))
]

A @racket['float32] vector widens:

@examples[#:eval ev #:label #f
(f64vector->list (device-vector->f64vector (vector->device-vector #(0.1) #:dtype 'float32)))
]

Summed on the host:

@examples[#:eval ev #:label #f
(define totals (device-vector->f64vector (vector->device-vector #(1.5 2.5 3.0))))
(for/sum ([i (in-range (f64vector-length totals))]) (f64vector-ref totals i))
]}

@defproc[(bytes->device-vector [bs bytes?]
                               [#:dtype dtype (or/c 'float32 'float64 'int32 'int64)]
                               [#:resources resources device-resources?
                                            (current-device-resources)])
         device-vector?]{

Returns a vector whose storage is @racket[bs], read as @racket[dtype] in the
machine's byte order. The
length of @racket[bs] must be a whole number of elements.

@examples[#:eval ev
(define raw (bytes-append (real->floating-point-bytes 0.5 4)
                          (real->floating-point-bytes 1.5 4)))
(bytes->device-vector raw #:dtype 'float32)
]

Labels from a binary file:

@examples[#:eval ev #:label #f
(define label-file (make-temporary-file))
(define label-bytes
  (apply bytes-append (for/list ([label (in-list '(0 2 1 1))])
                        (integer->integer-bytes label 4 #t))))
(display-to-file label-bytes label-file #:exists 'truncate)
(device-vector->list (bytes->device-vector (file->bytes label-file) #:dtype 'int32))
]

@examples[#:eval ev #:hidden
(delete-file label-file)
]

A partial element is refused:

@examples[#:eval ev #:label #f
(eval:error (bytes->device-vector (make-bytes 6) #:dtype 'float32))
]}

@defproc[(device-vector->bytes [v device-vector?]) bytes?]{

Returns the storage of @racket[v] as a new byte string in the machine's byte
order: @tt{v.copy_to_host().tobytes()}.

@examples[#:eval ev
(device-vector->bytes (vector->device-vector #(1 2) #:dtype 'int32))
]

A round trip through a file:

@examples[#:eval ev #:label #f
(define result-file (make-temporary-file))
(display-to-file (device-vector->bytes (vector->device-vector #(0.5 0.25))) result-file
                 #:exists 'truncate)
(file-size result-file)
(device-vector->list (bytes->device-vector (file->bytes result-file) #:dtype 'float64))
]

@examples[#:eval ev #:hidden
(delete-file result-file)
]

Reinterpreted as another element type:

@examples[#:eval ev #:label #f
(define one (device-vector->bytes (vector->device-vector #(1.0) #:dtype 'float32)))
(device-vector->list (bytes->device-vector one #:dtype 'int32))
]}

@section[#:tag "ref-compat-math"]{@racketmodname[math/matrix] and @racketmodname[math/array]}

A flonum array or mutable array hands over its storage in one step; any
other array is read through a Typed Racket contract per element. Results come
back as flonum arrays (@racket[FlArray]) for floating-point device arrays and
mutable arrays of exact integers for integer ones.

@defproc[(matrix->device-matrix [m matrix?]
                                [#:dtype dtype (or/c #f 'float32 'float64 'int32 'int64) #f]
                                [#:layout layout (or/c 'row-major 'col-major) 'row-major]
                                [#:resources resources device-resources?
                                             (current-device-resources)])
         device-matrix?]{

Returns a device matrix holding @racket[m], of @racket[dtype] or the inferred
type, packed in @racket[layout].

@examples[#:eval ev
(matrix->device-matrix (matrix [[1.0 2.0] [3.0 4.0]]))
]

A Gram matrix in single precision:

@examples[#:eval ev #:label #f
(define A (matrix [[1.0 2.0] [3.0 4.0] [5.0 6.0]]))
(define gram (matrix* (matrix-transpose A) A))
(matrix->device-matrix gram #:dtype 'float32)
]

Exact entries infer @racket['int64]; ask for the type you need:

@examples[#:eval ev #:label #f
(dtype (matrix->device-matrix (identity-matrix 3)))
(define I (matrix->device-matrix (identity-matrix 3) #:dtype 'float64 #:layout 'col-major))
(list (dtype I) (contiguous? I #:layout 'col-major))
]}

@defproc[(device-matrix->matrix [m device-matrix?]) array?]{

Returns @racket[m] as a two-axis @racketmodname[math/array] array, whatever
its layout. A matrix with an extent of 0 gives an empty array, which
@racket[matrix?] rejects.

@examples[#:eval ev
(device-matrix->matrix (matrix->device-matrix (matrix [[1.0 2.0] [3.0 4.0]])))
]

Host algebra on the result:

@examples[#:eval ev #:label #f
(define back (device-matrix->matrix (matrix->device-matrix gram)))
(list (matrix-trace back) (matrix-determinant back))
]

Integer matrices stay exact:

@examples[#:eval ev #:label #f
(define counts-matrix (device-matrix->matrix (list*->device-matrix '((2 1) (1 3)) #:dtype 'int32)))
(matrix-inverse counts-matrix)
]}

@defproc[(matrix->device-vector [m matrix?]
                                [#:dtype dtype (or/c #f 'float32 'float64 'int32 'int64) #f]
                                [#:resources resources device-resources?
                                             (current-device-resources)])
         device-vector?]{

Returns a device vector of the elements of @racket[m], a row or column
matrix; any other shape raises @racket[exn:fail:raft].

@examples[#:eval ev
(matrix->device-vector (col-matrix [1 2 3]))
(matrix->device-vector (row-matrix [0.5 1.5]))
]

A host-solved linear system:

@examples[#:eval ev #:label #f
(define x (matrix-solve (matrix [[2.0 1.0] [1.0 3.0]]) (col-matrix [3.0 5.0])))
(matrix->device-vector x #:dtype 'float32)
]

@examples[#:eval ev #:label #f
(eval:error (matrix->device-vector gram))
]}

@defproc[(device-vector->col-matrix [v device-vector?]) array?]{

Returns @racket[v] as a column matrix, of shape @racket[(vector n 1)].

@examples[#:eval ev
(device-vector->col-matrix (vector->device-vector #(1.0 2.0 3.0)))
]

Checking a result on the host:

@examples[#:eval ev #:label #f
(define coefficients (vector->device-vector #(1.0 -1.0)))
(matrix* A (device-vector->col-matrix coefficients))
]

A Euclidean norm:

@examples[#:eval ev #:label #f
(matrix-norm (device-vector->col-matrix (vector->device-vector #(3.0 4.0))))
]}

@defproc[(device-vector->row-matrix [v device-vector?]) array?]{

Returns @racket[v] as a row matrix, of shape @racket[(vector 1 n)].

@examples[#:eval ev
(device-vector->row-matrix (vector->device-vector #(1 2 3)))
]

Stacking results into one matrix:

@examples[#:eval ev #:label #f
(define runs (list (vector->device-vector #(0.25 0.5)) (vector->device-vector #(0.75 1.0))))
(matrix-stack (map device-vector->row-matrix runs))
]

A dot product as row times column:

@examples[#:eval ev #:label #f
(define u (vector->device-vector #(1.0 2.0)))
(matrix* (device-vector->row-matrix u) (device-vector->col-matrix u))
]}

@defproc[(array->device-array [arr array?]
                              [#:dtype dtype (or/c #f 'float32 'float64 'int32 'int64) #f]
                              [#:layout layout (or/c 'row-major 'col-major) 'row-major]
                              [#:resources resources device-resources?
                                           (current-device-resources)])
         device-array?]{

Returns a device vector for a one-axis array and a device matrix for a
two-axis one, of @racket[dtype] or the inferred type; @racket[layout] applies
to a matrix. Another rank raises @racket[exn:fail:raft].

@examples[#:eval ev
(array->device-array (flarray #[#[1.0 2.0] #[3.0 4.0]]))
(array->device-array (array #[1 2 3]))
]

A @racket[build-array] table, read element by element:

@examples[#:eval ev #:label #f
(define distances-table
  (build-array #(3 3) (lambda (js) (abs (- (vector-ref js 0) (vector-ref js 1))))))
(array->device-array distances-table #:dtype 'float32)
]

Columns sliced on the host first, since device arrays cannot be sliced yet
@status{L3}:

@examples[#:eval ev #:label #f
(define measurements (flarray #[#[5.1 3.5 1.4] #[7.0 3.2 4.7] #[6.3 3.3 6.0]]))
(define first-two (array-slice-ref measurements (list (::) (:: 0 2))))
(device-array->list* (array->device-array first-two))
]

@examples[#:eval ev #:label #f
(eval:error (array->device-array (array #[#[#[1 2]]])))
]}

@defproc[(device-array->array [a device-array?]) array?]{

Returns @racket[a] as a @racketmodname[math/array] array of the same shape.

@examples[#:eval ev
(device-array->array (vector->device-vector #(1.5 2.5)))
(device-array->array (list*->device-matrix '((1 2) (3 4)) #:dtype 'int32))
]

Summing a result:

@examples[#:eval ev #:label #f
(array-all-sum (device-array->array (vector->device-vector #(0.5 1.5 2.0))))
]

Host arithmetic, sent back:

@examples[#:eval ev #:label #f
(define scaled (array-scale (device-array->array (vector->device-vector #(1.0 2.0 3.0))) 10.0))
(array->device-array scaled)
]}

@section[#:tag "ref-compat-reexports"]{From @racketmodname[raft/array]}

Re-exported from @secref["ref-array-convert"]:

@itemlist[
 @item{@racket[list->device-vector] and @racket[device-vector->list]}
 @item{@racket[list*->device-matrix] and @racket[device-matrix->list*]}
 @item{@racket[flvector->device-vector] and @racket[device-vector->flvector]}
]
