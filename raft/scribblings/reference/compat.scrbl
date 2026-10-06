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

This module converts between @tech{device arrays} and the data Racket programs
already hold. It holds the whole conversion table in one place: it re-exports
the list and @racket[flvector] conversions of @racketmodname[raft/array] and
adds vectors, nested vectors, @racket[f32vector]s, @racket[f64vector]s, byte
strings, and @racketmodname[math/matrix] and @racketmodname[math/array]
values. It is the only module of the library that requires @tt{math-lib}, so
@racketmodname[raft] does not re-export it and @racket[(require raft)] stays
light. The guide chapter @secref["moving-data"] uses it in one program.

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

@bold{The rules.} Every conversion here follows the rules of
@secref["ref-array-convert"], through the same packer. Going to the device,
the element type is inferred as NumPy infers it unless @racket[#:dtype] gives
one: all exact integers give @racket['int64], any other real numbers
@racket['float64], and no elements at all @racket['float64]. An
@racket[flvector], an @racket[f64vector] and a flonum array hold flonums, so
they give @racket['float64]; an @racket[f32vector] gives @racket['float32].
Exact rationals become floats, and an integer type truncates toward zero. A
value the element type cannot hold, such as a complex number, an infinity or
NaN for an integer type, or a number out of the type's range, raises
@racket[exn:fail:raft] naming the procedure. A matrix's @racket[#:layout]
decides the order its values are packed in on the host, so no copy runs on
the GPU to change it. Nested data must be rectangular: a ragged row raises
@racket[exn:fail:raft] naming the row. Coming back, the conversions wait for
the work queued on the array's stream, then copy; floating-point elements
become flonums and integer elements exact integers.

@bold{Rank.} Device arrays have one or two axes for now. A conversion that
infers the rank, from a nesting or from a @racketmodname[math/array] array,
refuses any other rank with @racket[exn:fail:raft]; arrays of any rank arrive
later @status{L3}.

@bold{Speed.} Packing goes element by element. An @racket[flvector] or a
flonum array sent as @racket['float64] and a byte string skip it: their
storage is copied to the device as it is. An @racket[f32vector] sent as
@racket['float32] and an @racket[f64vector] sent as @racket['float64] skip
it too, after one copy of their storage on the host.
@secref["moving-data-speed"] measures every representation.

@section[#:tag "ref-compat-nested"]{Vectors and nested data}

@defproc[(vector->device-vector [xs (vectorof real?)]
                                [#:dtype dtype (or/c #f 'float32 'float64 'int32 'int64) #f]
                                [#:resources resources device-resources?
                                             (current-device-resources)])
         device-vector?]{

Returns a vector holding the elements of @racket[xs], of @racket[dtype], or of
the inferred type when @racket[dtype] is @racket[#f]. It is
@tt{device_ndarray(np.asarray(xs, dtype))}.

@examples[#:eval ev
(vector->device-vector #(3 1 4 1 5))
(vector->device-vector #(0.5 1.5 2.5) #:dtype 'float32)
]

Weights computed by Racket code, sent in the type cuML takes:

@examples[#:eval ev #:label #f
(define weights
  (for/vector ([i (in-range 6)])
    (/ 1.0 (add1 i))))
(vector->device-vector weights #:dtype 'float32)
]

One column of a table whose rows are vectors:

@examples[#:eval ev #:label #f
(define flowers
  (vector #("setosa" 5.1 3.5)
          #("versicolor" 7.0 3.2)
          #("virginica" 6.3 3.3)))
(define lengths (vector-map (lambda (row) (vector-ref row 1)) flowers))
(device-vector->list (vector->device-vector lengths))
]

A string is refused, and the error names it:

@examples[#:eval ev #:label #f
(eval:error (vector->device-vector (vector-map (lambda (row) (vector-ref row 0)) flowers)))
]}

@defproc[(device-vector->vector [v device-vector?]) (vectorof real?)]{

Returns the elements of @racket[v] as a new mutable vector. The nearest
Python is @tt{v.copy_to_host().tolist()}; a vector also indexes in constant
time.

@examples[#:eval ev
(device-vector->vector (vector->device-vector #(2 7 1 8)))
]

Counting how many samples fall in each cluster from a vector of labels:

@examples[#:eval ev #:label #f
(define labels (vector->device-vector #(0 2 1 2 2 0) #:dtype 'int32))
(define counts (make-vector 3 0))
(for ([label (in-vector (device-vector->vector labels))])
  (vector-set! counts label (add1 (vector-ref counts label))))
counts
]

The best score and where it is, read on the host:

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

Returns a matrix whose rows are the vectors in @racket[rows], of
@racket[dtype] or the inferred type, packed in @racket[layout]. Every row must
have the same length. It is @racket[list*->device-matrix] for vectors.

@examples[#:eval ev
(vector*->device-matrix #(#(1 2 3) #(4 5 6)))
]

A grid built by @racket[for/vector], laid out by column for a solver that
reads Fortran order:

@examples[#:eval ev #:label #f
(define grid
  (for/vector ([x (in-range 3)])
    (for/vector ([y (in-range 2)])
      (+ (* 0.5 x) y))))
(define G (vector*->device-matrix grid #:dtype 'float32 #:layout 'col-major))
(list (shape G) (contiguous? G #:layout 'col-major) (strides G))
]

A ragged row is named, as a vector:

@examples[#:eval ev #:label #f
(eval:error (vector*->device-matrix #(#(1.0 2.0) #(3.0))))
]}

@defproc[(device-matrix->vector* [m device-matrix?]) (vectorof (vectorof real?))]{

Returns the rows of @racket[m] as a vector of vectors, whatever its layout.

@examples[#:eval ev
(device-matrix->vector* (vector*->device-matrix #(#(1 2) #(3 4))))
]

Looking up one centroid of several:

@examples[#:eval ev #:label #f
(define centroids (vector*->device-matrix #(#(5.0 3.4) #(6.6 3.0) #(5.9 2.8))))
(vector-ref (device-matrix->vector* centroids) 1)
]

A column-major matrix still comes back as rows:

@examples[#:eval ev #:label #f
(device-matrix->vector* G)
]}

@defproc[(list*->device-array [xs (or/c (listof real?) (listof (listof real?)))]
                              [#:dtype dtype (or/c #f 'float32 'float64 'int32 'int64) #f]
                              [#:layout layout (or/c 'row-major 'col-major) 'row-major]
                              [#:resources resources device-resources?
                                           (current-device-resources)])
         device-array?]{

Returns a vector if @racket[xs] is a list of numbers and a matrix if it is a
list of lists, as @tt{device_ndarray(np.asarray(xs, dtype))} does. The rank is
read from the nesting: if the first element of @racket[xs] is a list, every
element must be one. The empty list is an empty vector, as
@tt{np.asarray([])} is. A deeper nesting is refused; @racket[layout] applies to
a matrix and is ignored for a vector.

@examples[#:eval ev
(list*->device-array '(1.0 2.0 3.0))
(list*->device-array '((1 2) (3 4)))
]

A loader that takes one series or a table of them, with the same call:

@examples[#:eval ev #:label #f
(define (upload data)
  (list*->device-array data #:dtype 'float32))
(map shape (list (upload '(0.5 1.5)) (upload '((0.5 1.5) (2.5 3.5) (4.5 5.5)))))
]

The empty list is an empty vector:

@examples[#:eval ev #:label #f
(shape (list*->device-array '()))
]

A nesting that is not one or two deep, or that mixes depths, is refused:

@examples[#:eval ev #:label #f
(eval:error (list*->device-array '(((1 2) (3 4)))))
(eval:error (list*->device-array '(1.0 (2.0 3.0))))
]}

@defproc[(vector*->device-array [xs (or/c (vectorof real?) (vectorof (vectorof real?)))]
                                [#:dtype dtype (or/c #f 'float32 'float64 'int32 'int64) #f]
                                [#:layout layout (or/c 'row-major 'col-major) 'row-major]
                                [#:resources resources device-resources?
                                             (current-device-resources)])
         device-array?]{

Like @racket[list*->device-array], for vectors and vectors of vectors.

@examples[#:eval ev
(vector*->device-array #(1 2 3))
(vector*->device-array #(#(1 2) #(3 4)))
]

Data saved as a Racket literal and read back with @racket[read]:

@examples[#:eval ev #:label #f
(define saved (read (open-input-string "#(#(0.1 0.2) #(0.3 0.4) #(0.5 0.6))")))
(shape (vector*->device-array saved #:dtype 'float32))
]

A row that is not a vector is named:

@examples[#:eval ev #:label #f
(eval:error (vector*->device-array (vector #(1 2) 3)))
]}

@defproc[(device-array->list* [a device-array?])
         (or/c (listof real?) (listof (listof real?)))]{

Returns the elements of @racket[a] as a list for a vector and as a list of
rows for a matrix: @tt{a.copy_to_host().tolist()} for either rank.

@examples[#:eval ev
(device-array->list* (list*->device-array '(1 2 3)))
(device-array->list* (list*->device-array '((1 2) (3 4)) #:layout 'col-major))
]

Results sent to a web client as JSON, whatever their rank:

@examples[#:eval ev #:label #f
(define (results->json a)
  (jsexpr->string (hasheq 'shape (shape a) 'values (device-array->list* a))))
(results->json (list*->device-array '((1 2) (3 4)) #:dtype 'int32))
(results->json (vector->device-vector #(0.5 0.25)))
]

A summary that works on both ranks, by flattening the rows:

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

Indexing an element of a result directly:

@examples[#:eval ev #:label #f
(define table (device-array->vector* centroids))
(vector-ref (vector-ref table 2) 0)
]

Sorting a copy of a result on the host, leaving the device array as it was:

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

Returns a vector holding the elements of @racket[xs], of @racket[dtype]. For
@racket['float32] the storage is copied as it is, with no packing; other types
are converted element by element. It is
@tt{device_ndarray(np.asarray(xs, dtype))} for an @tt{xs} of type
@tt{np.float32}.

@examples[#:eval ev
(f32vector->device-vector (f32vector 0.5 1.5 2.5))
]

Samples from an audio decoder, which hands back single-precision floats:

@examples[#:eval ev #:label #f
(define samples (make-f32vector 4 0.25))
(f32vector-set! samples 2 -0.75)
(define on-gpu (f32vector->device-vector samples))
(list (dtype on-gpu) (device-vector->list on-gpu))
]

Widened to double precision or truncated to integers on the way:

@examples[#:eval ev #:label #f
(device-vector->list (f32vector->device-vector (f32vector 0.1 2.7) #:dtype 'float64))
(device-vector->list (f32vector->device-vector (f32vector 0.1 2.7) #:dtype 'int32))
]}

@defproc[(f64vector->device-vector [xs f64vector?]
                                   [#:dtype dtype (or/c 'float32 'float64 'int32 'int64) 'float64]
                                   [#:resources resources device-resources?
                                                (current-device-resources)])
         device-vector?]{

Returns a vector holding the elements of @racket[xs], of @racket[dtype]. For
@racket['float64] the storage is copied as it is; other types are converted
element by element, and a value too large for @racket['float32] is refused.

@examples[#:eval ev
(f64vector->device-vector (f64vector 1.0 2.0 3.0))
]

Readings in an @racket[f64vector], the form a C library fills through the
FFI, narrowed to @racket['float32] for cuML:

@examples[#:eval ev #:label #f
(define readings (list->f64vector '(21.5 21.75 22.0 22.5)))
(f64vector->device-vector readings #:dtype 'float32)
]

Counts that arrived as doubles, sent as integers:

@examples[#:eval ev #:label #f
(dtype (f64vector->device-vector (f64vector 3.0 0.0 12.0) #:dtype 'int64))
]}

@defproc[(device-vector->f32vector [v device-vector?]) f32vector?]{

Returns the elements of @racket[v] as a new @racket[f32vector]. A
@racket['float32] vector is copied as it is; other types are converted, and a
@racket['float64] value too large for @racket['float32] is refused.

@examples[#:eval ev
(f32vector->list (device-vector->f32vector (f32vector->device-vector (f32vector 0.5 1.5))))
]

Results narrowed for a C library that takes @tt{float*}:

@examples[#:eval ev #:label #f
(define out (device-vector->f32vector (vector->device-vector #(0.1 0.2))))
(list (f32vector-length out) (f32vector-ref out 0))
]

Integer labels as floats:

@examples[#:eval ev #:label #f
(f32vector->list (device-vector->f32vector labels))
]}

@defproc[(device-vector->f64vector [v device-vector?]) f64vector?]{

Returns the elements of @racket[v] as a new @racket[f64vector]. A
@racket['float64] vector is copied as it is; other types are widened.

@examples[#:eval ev
(f64vector->list (device-vector->f64vector (f64vector->device-vector readings)))
]

A @racket['float32] vector widens to the nearest doubles:

@examples[#:eval ev #:label #f
(f64vector->list (device-vector->f64vector (vector->device-vector #(0.1) #:dtype 'float32)))
]

A result handed to code that takes a @tt{double*}, here summed in Racket:

@examples[#:eval ev #:label #f
(define totals (device-vector->f64vector (vector->device-vector #(1.5 2.5 3.0))))
(for/sum ([i (in-range (f64vector-length totals))]) (f64vector-ref totals i))
]}

@defproc[(bytes->device-vector [bs bytes?]
                               [#:dtype dtype (or/c 'float32 'float64 'int32 'int64)]
                               [#:resources resources device-resources?
                                            (current-device-resources)])
         device-vector?]{

Returns a vector whose storage is the bytes of @racket[bs], read as elements of
@racket[dtype] in the machine's byte order (little-endian on x86-64), with no
conversion. The element type must be given, since bytes do not carry one, and
the length of @racket[bs] must be a whole number of elements. It is
@tt{device_ndarray(np.frombuffer(bs, dtype))}.

@examples[#:eval ev
(define raw (bytes-append (real->floating-point-bytes 0.5 4)
                          (real->floating-point-bytes 1.5 4)))
(bytes->device-vector raw #:dtype 'float32)
]

Labels stored as 32-bit integers in a binary file:

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

A length that is not a whole number of elements is refused:

@examples[#:eval ev #:label #f
(eval:error (bytes->device-vector (make-bytes 6) #:dtype 'float32))
]}

@defproc[(device-vector->bytes [v device-vector?]) bytes?]{

Returns the storage of @racket[v] as a new byte string, in the machine's byte
order: @racket[numel] times the element size bytes. It is
@tt{v.copy_to_host().tobytes()}.

@examples[#:eval ev
(device-vector->bytes (vector->device-vector #(1 2) #:dtype 'int32))
]

Saving a result to a binary file and reading it back:

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

The same bytes read as another element type, as @tt{view} does in NumPy:

@examples[#:eval ev #:label #f
(define one (device-vector->bytes (vector->device-vector #(1.0) #:dtype 'float32)))
(device-vector->list (bytes->device-vector one #:dtype 'int32))
]}

@section[#:tag "ref-compat-math"]{@racketmodname[math/matrix] and @racketmodname[math/array]}

@racketmodname[math/array] is written in Typed Racket, and every array that
reaches untyped code carries a contract that checks each element as it is
read. These conversions read an array's elements once: a flonum array hands
over its @racket[flvector] in one step (@racket[flarray-data]), a mutable
array its vector (@racket[mutable-array-data]), and any other array is read by
@racket[array->vector], which pays that check on every element. Arrays come
back as flonum arrays (@racket[FlArray]) from @racket['float32] and
@racket['float64] device arrays and as mutable arrays from integer ones.

@defproc[(matrix->device-matrix [m matrix?]
                                [#:dtype dtype (or/c #f 'float32 'float64 'int32 'int64) #f]
                                [#:layout layout (or/c 'row-major 'col-major) 'row-major]
                                [#:resources resources device-resources?
                                             (current-device-resources)])
         device-matrix?]{

Returns a device matrix holding @racket[m], a matrix of real numbers, of
@racket[dtype] or the inferred type, packed in @racket[layout]. Like any @racketmodname[math/matrix] value,
@racket[m] is an array with two axes. It is
@tt{device_ndarray(np.asarray(m, dtype))}.

@examples[#:eval ev
(matrix->device-matrix (matrix [[1.0 2.0] [3.0 4.0]]))
]

A Gram matrix computed on the host, sent in single precision:

@examples[#:eval ev #:label #f
(define A (matrix [[1.0 2.0] [3.0 4.0] [5.0 6.0]]))
(define gram (matrix* (matrix-transpose A) A))
(matrix->device-matrix gram #:dtype 'float32)
]

@racket[identity-matrix] has exact entries, so the inferred type is
@racket['int64]; ask for the type the consumer needs, and the layout:

@examples[#:eval ev #:label #f
(dtype (matrix->device-matrix (identity-matrix 3)))
(define I (matrix->device-matrix (identity-matrix 3) #:dtype 'float64 #:layout 'col-major))
(list (dtype I) (contiguous? I #:layout 'col-major))
]}

@defproc[(device-matrix->matrix [m device-matrix?]) array?]{

Returns the rows and columns of @racket[m] as a @racketmodname[math/array]
array with two axes, whatever its layout: a flonum array for a floating-point
matrix, a mutable array of exact integers for an integer one. A matrix with an
extent of 0 comes back as an empty array, which @racket[matrix?] does not
accept.

@examples[#:eval ev
(device-matrix->matrix (matrix->device-matrix (matrix [[1.0 2.0] [3.0 4.0]])))
]

The result is a @racketmodname[math/matrix] matrix, ready for the host-side
algebra:

@examples[#:eval ev #:label #f
(define back (device-matrix->matrix (matrix->device-matrix gram)))
(list (matrix-trace back) (matrix-determinant back))
]

Integer matrices come back exact, so the algebra stays exact:

@examples[#:eval ev #:label #f
(define counts-matrix (device-matrix->matrix (list*->device-matrix '((2 1) (1 3)) #:dtype 'int32)))
(matrix-inverse counts-matrix)
]}

@defproc[(matrix->device-vector [m matrix?]
                                [#:dtype dtype (or/c #f 'float32 'float64 'int32 'int64) #f]
                                [#:resources resources device-resources?
                                             (current-device-resources)])
         device-vector?]{

Returns a device vector holding the elements of @racket[m], a row matrix
(one row) or a column matrix (one column). Any other shape raises
@racket[exn:fail:raft].

@examples[#:eval ev
(matrix->device-vector (col-matrix [1 2 3]))
(matrix->device-vector (row-matrix [0.5 1.5]))
]

The solution of a linear system, computed on the host and sent as a vector:

@examples[#:eval ev #:label #f
(define x (matrix-solve (matrix [[2.0 1.0] [1.0 3.0]]) (col-matrix [3.0 5.0])))
(matrix->device-vector x #:dtype 'float32)
]

A matrix with several rows and columns is not a vector:

@examples[#:eval ev #:label #f
(eval:error (matrix->device-vector gram))
]}

@defproc[(device-vector->col-matrix [v device-vector?]) array?]{

Returns the elements of @racket[v] as a column matrix, an array of shape
@racket[(vector n 1)].

@examples[#:eval ev
(device-vector->col-matrix (vector->device-vector #(1.0 2.0 3.0)))
]

Checking a GPU result on the host, by multiplying @racket[A] by it:

@examples[#:eval ev #:label #f
(define coefficients (vector->device-vector #(1.0 -1.0)))
(matrix* A (device-vector->col-matrix coefficients))
]

The Euclidean norm of a result vector, by @racketmodname[math/matrix]:

@examples[#:eval ev #:label #f
(matrix-norm (device-vector->col-matrix (vector->device-vector #(3.0 4.0))))
]}

@defproc[(device-vector->row-matrix [v device-vector?]) array?]{

Returns the elements of @racket[v] as a row matrix, an array of shape
@racket[(vector 1 n)].

@examples[#:eval ev
(device-vector->row-matrix (vector->device-vector #(1 2 3)))
]

Stacking several result vectors into one host matrix, one row each:

@examples[#:eval ev #:label #f
(define runs (list (vector->device-vector #(0.25 0.5)) (vector->device-vector #(0.75 1.0))))
(matrix-stack (map device-vector->row-matrix runs))
]

A dot product on the host, as a row times a column:

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

Returns a device vector for an array of real numbers with one axis and a
device matrix for an array with two, of @racket[dtype] or the inferred type; @racket[layout] applies
to a matrix. Another rank is refused. A flonum array sent as
@racket['float64] in row-major order is copied straight from its
@racket[flvector].

@examples[#:eval ev
(array->device-array (flarray #[#[1.0 2.0] #[3.0 4.0]]))
(array->device-array (array #[1 2 3]))
]

A table computed by @racket[build-array], which is neither a flonum array nor
a mutable array, so its elements are read one by one:

@examples[#:eval ev #:label #f
(define distances-table
  (build-array #(3 3) (lambda (js) (abs (- (vector-ref js 0) (vector-ref js 1))))))
(array->device-array distances-table #:dtype 'float32)
]

Selecting columns on the host before sending, since device arrays cannot be
sliced yet @status{L3}:

@examples[#:eval ev #:label #f
(define measurements (flarray #[#[5.1 3.5 1.4] #[7.0 3.2 4.7] #[6.3 3.3 6.0]]))
(define first-two (array-slice-ref measurements (list (::) (:: 0 2))))
(device-array->list* (array->device-array first-two))
]

An array with three axes is refused:

@examples[#:eval ev #:label #f
(eval:error (array->device-array (array #[#[#[1 2]]])))
]}

@defproc[(device-array->array [a device-array?]) array?]{

Returns the elements of @racket[a] as a @racketmodname[math/array] array of
the same shape: a flonum array for a floating-point device array, and a
mutable array of exact integers for an integer one. A @racket['float64]
row-major array is read straight into the result's @racket[flvector].

@examples[#:eval ev
(device-array->array (vector->device-vector #(1.5 2.5)))
(device-array->array (list*->device-matrix '((1 2) (3 4)) #:dtype 'int32))
]

Summing a result with @racketmodname[math/array]:

@examples[#:eval ev #:label #f
(array-all-sum (device-array->array (vector->device-vector #(0.5 1.5 2.0))))
]

Element-wise arithmetic on the host, and the result sent back:

@examples[#:eval ev #:label #f
(define scaled (array-scale (device-array->array (vector->device-vector #(1.0 2.0 3.0))) 10.0))
(array->device-array scaled)
]}

@section[#:tag "ref-compat-reexports"]{From @racketmodname[raft/array]}

These are @racketmodname[raft/array]'s conversions, re-exported so that the
whole table above can be required from one module. Each is documented in
@secref["ref-array-convert"].

@itemlist[
 @item{@racket[list->device-vector] and @racket[device-vector->list]}
 @item{@racket[list*->device-matrix] and @racket[device-matrix->list*]}
 @item{@racket[flvector->device-vector] and @racket[device-vector->flvector]}
]
