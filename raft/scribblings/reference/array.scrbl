#lang scribble/manual
@(require "../utils.rkt")

@(define ev (make-raft-eval "reference-array"))

@title[#:tag "ref-array"]{Device arrays: @racketmodname[raft/array]}

@defmodule[raft/array]

A @deftech{device array} is a matrix or a vector in GPU memory: a
@tech{buffer} read through a shape, @tech{strides}, an offset and a
@tech{dtype}, one of @racket['float32], @racket['float64], @racket['int32]
and @racket['int64]. A matrix is @tech{row-major} or @tech{column-major}.
@racketmodname[raft] re-exports this module; @secref["arrays"] is its guide.

The examples below share these values:

@examples[#:eval ev #:label #f
(define samples
  '((5.1 3.5 1.4 0.2)
    (4.9 3.0 1.4 0.2)
    (7.0 3.2 4.7 1.4)
    (6.4 3.2 4.5 1.5)))
(define X (list*->device-matrix samples #:dtype 'float32))
]

@bold{Memory.} An array allocates through its @racket[#:resources],
@racket[(current-device-resources)] by default, and queues its work on their
@tech{stream}; it keeps them alive. Its finalizer frees the memory, and its
size counts as @tech{phantom bytes}.

@bold{Printing.} An array prints its dtype, shape, layout and device, then
its values, waiting for its stream. An axis longer than 20, and every axis of
an array over 1000 elements, shows its first and last three entries around
@tt{...}.
Printing never raises; unreadable values print as
@tt{<values unavailable: ...>}.

@bold{Errors.} An unknown dtype or layout, or a negative extent, raises
@racket[exn:fail:raft] of kind @racket['logic]. An argument of the wrong
kind may raise a different error.

@section[#:tag "ref-array-make"]{Making arrays}

@defproc[(device-matrix [rows exact-nonnegative-integer?]
                        [cols exact-nonnegative-integer?]
                        [#:dtype dtype (or/c 'float32 'float64 'int32 'int64) 'float32]
                        [#:layout layout (or/c 'row-major 'col-major) 'row-major]
                        [#:resources resources device-resources?
                                     (current-device-resources)])
         device-matrix?]{

Allocates a @racket[rows]-by-@racket[cols] matrix of @racket[dtype] in
@racket[layout], uninitialised.

@examples[#:eval ev
(define out (device-matrix 1000 128))
(list (shape out) (dtype out) (layout out))
]

An output shaped after its input:

@examples[#:eval ev #:label #f
(define (distance-matrix data k)
  (match-define (list n _) (shape data))
  (device-matrix n k #:dtype (dtype data)))
(define distances (distance-matrix X 3))
(list (shape distances) (dtype distances))
]

Column-major, with resources of its own:

@examples[#:eval ev #:label #f
(with-device-resources ([r (device-resources)])
  (define coefficients (device-matrix 3 2 #:dtype 'float64 #:layout 'col-major
                                      #:resources r))
  (list (layout coefficients) (strides coefficients)))
]

An unsupported element type raises:

@examples[#:eval ev #:label #f
(eval:error (device-matrix 2 2 #:dtype 'float16))
]}

@defproc[(device-vector [n exact-nonnegative-integer?]
                        [#:dtype dtype (or/c 'float32 'float64 'int32 'int64) 'float32]
                        [#:resources resources device-resources?
                                     (current-device-resources)])
         device-vector?]{

Allocates an uninitialised vector of @racket[n] elements of @racket[dtype].
Its stride is 1, or 0 when
empty, and it is in both layouts.

@examples[#:eval ev
(define labels (device-vector (first (shape X)) #:dtype 'int32))
(list (shape labels) (dtype labels) (strides labels))
]

Per-sample weights:

@examples[#:eval ev #:label #f
(define weights (device-vector 4 #:dtype 'float64))
(list (numel weights) (dtype weights))
]

One element per column of a matrix:

@examples[#:eval ev #:label #f
(define (per-column m)
  (device-vector (second (shape m)) #:dtype (dtype m)))
(shape (per-column X))
]}

@section[#:tag "ref-array-inspect"]{Inspecting arrays}

@defproc[(device-array? [v any/c]) boolean?]{

Returns @racket[#t] if @racket[v] is a @tech{device array}.

@examples[#:eval ev
(device-array? X)
(device-array? labels)
(device-array? samples)
]

Copying data to the device only when it is not there:

@examples[#:eval ev #:label #f
(define (on-device data)
  (if (device-array? data)
      data
      (list*->device-matrix data #:dtype 'float32)))
(eq? (on-device X) X)
(shape (on-device '((1.0 2.0))))
]

Counting inputs already on the GPU:

@examples[#:eval ev #:label #f
(count device-array? (list X labels samples))
]}

@defproc[(device-matrix? [v any/c]) boolean?]{

Returns @racket[#t] if @racket[v] is a @tech{device array} with two axes.

@examples[#:eval ev
(device-matrix? X)
(device-matrix? labels)
]

Checking an input for k-means:

@examples[#:eval ev #:label #f
(define (kmeans-input? v)
  (and (device-matrix? v)
       (eq? (layout v) 'row-major)
       (memq (dtype v) '(float32 float64))
       #t))
(kmeans-input? X)
(kmeans-input? (contiguous X #:layout 'col-major))
]

A row count that treats a vector as one row:

@examples[#:eval ev #:label #f
(define (row-count a)
  (if (device-matrix? a) (first (shape a)) 1))
(map row-count (list X labels))
]}

@defproc[(device-vector? [v any/c]) boolean?]{

Returns @racket[#t] if @racket[v] is a @tech{device array} with one axis.

@examples[#:eval ev
(device-vector? labels)
(device-vector? X)
]

Either kind back to Racket data:

@examples[#:eval ev #:label #f
(define (->racket a)
  (if (device-vector? a)
      (device-vector->list a)
      (device-matrix->list* a)))
(->racket (list->device-vector '(1 2 3)))
(->racket (list*->device-matrix '((1 2) (3 4))))
]

Weights that match the samples:

@examples[#:eval ev #:label #f
(define (weights-fit? w m)
  (and (device-vector? w)
       (= (first (shape w)) (first (shape m)))))
(weights-fit? weights X)
(weights-fit? labels (device-matrix 5 2))
]}

@defproc[(shape [a (or/c device-array? device-csr-matrix?)])
         (listof exact-nonnegative-integer?)]{

Returns the extents of @racket[a]: @racket[(list rows cols)] or
@racket[(list n)]. A @tech{CSR matrix} answers its @racket[(list rows cols)].

@examples[#:eval ev
(shape X)
(shape labels)
(shape (triplets->device-csr-matrix '(0 2) '(1 3) '(1.5 -3.0) #:shape '(3 4)))
]

Sizing an algorithm's outputs:

@examples[#:eval ev #:label #f
(match-define (list n d) (shape X))
(define centroids (device-matrix 3 d))
(list n d (shape centroids))
]

Comparing shapes:

@examples[#:eval ev #:label #f
(define (same-shape? a b)
  (equal? (shape a) (shape b)))
(same-shape? X (contiguous X #:layout 'col-major))
(same-shape? X centroids)
]}

@defproc[(dtype [a (or/c device-array? device-csr-matrix?)])
         (or/c 'float32 'float64 'int32 'int64)]{

Returns the element type of @racket[a]. A @tech{CSR matrix} answers the type
of its values.

@examples[#:eval ev
(dtype X)
(dtype labels)
(dtype (list*->device-csr-matrix '((0 1.5)) #:dtype 'float32))
]

An output of its input's type:

@examples[#:eval ev #:label #f
(define (scratch-like a)
  (match-define (list rows cols) (shape a))
  (device-matrix rows cols #:dtype (dtype a)))
(dtype (scratch-like (list*->device-matrix '((1 2)) #:dtype 'int32)))
]

The types inferred from Racket data:

@examples[#:eval ev #:label #f
(map dtype (list (list->device-vector '(1 2 3))
                 (list->device-vector '(1 2.5))
                 (list->device-vector '(1/2))))
]}

@defproc[(layout [a device-array?]) (or/c 'row-major 'col-major)]{

Returns @racket['row-major] if each row of @racket[a] is contiguous in
memory, @racket['col-major] if each column is. An array in both layouts (a
vector, one row or column, or no elements) answers @racket['row-major].

@examples[#:eval ev
(layout X)
(layout (contiguous X #:layout 'col-major))
]

To ask whether an array is in a given layout, use @racket[contiguous?]:

@examples[#:eval ev #:label #f
(define column (device-matrix 5 1 #:layout 'col-major))
(list (strides column) (layout column) (layout labels))
(contiguous? column #:layout 'col-major)
]

A log line per input:

@examples[#:eval ev #:label #f
(for ([a (list X labels)])
  (printf "~a ~a ~a\n" (dtype a) (shape a) (layout a)))
]}

@defproc[(strides [a device-array?]) (listof exact-nonnegative-integer?)]{

Returns, for each axis of @racket[a], how many elements apart neighbours
along it are in memory, not bytes apart. An empty matrix has strides 0.

@examples[#:eval ev
(strides X)
(strides (contiguous X #:layout 'col-major))
(strides (device-matrix 0 4))
]

Where element (i, j) sits:

@examples[#:eval ev #:label #f
(define (element-index a i j)
  (+ (* i (first (strides a))) (* j (second (strides a)))))
(element-index X 2 1)
(element-index (contiguous X #:layout 'col-major) 2 1)
]

Strides in bytes, for an interface that counts bytes:

@examples[#:eval ev #:label #f
(define (byte-strides a)
  (define size (if (memq (dtype a) '(float32 int32)) 4 8))
  (map (lambda (s) (* s size)) (strides a)))
(byte-strides X)
]}

@defproc[(numel [a device-array?]) exact-nonnegative-integer?]{

Returns the number of elements of @racket[a].

@examples[#:eval ev
(numel X)
(numel labels)
]

Device memory taken:

@examples[#:eval ev #:label #f
(define (megabytes a)
  (define size (if (memq (dtype a) '(float32 int32)) 4 8))
  (/ (* (numel a) size) (* 1024 1024.0)))
(megabytes out)
]

Skipping work on an empty input:

@examples[#:eval ev #:label #f
(define (mean-of v)
  (if (zero? (numel v))
      +nan.0
      (/ (apply + (device-vector->list v)) (numel v))))
(mean-of (list->device-vector '(1.0 2.0 4.5)))
(mean-of (list->device-vector '()))
]}

@section[#:tag "ref-array-layout"]{Changing the layout}

@defproc[(contiguous? [a device-array?]
                      [#:layout layout (or/c 'row-major 'col-major) 'row-major])
         boolean?]{

Returns @racket[#t] if @racket[a] is laid out in @racket[layout]. A vector,
a matrix with one row or one column, and an empty matrix are in both. Any
other @racket[layout] symbol answers @racket[#f].

@examples[#:eval ev
(contiguous? X)
(contiguous? X #:layout 'col-major)
(contiguous? (contiguous X #:layout 'col-major) #:layout 'col-major)
]

A single column needs no copy:

@examples[#:eval ev #:label #f
(define one-feature (list*->device-matrix '((5.1) (4.9) (7.0)) #:dtype 'float32))
(list (contiguous? one-feature) (contiguous? one-feature #:layout 'col-major))
(eq? (contiguous one-feature #:layout 'col-major) one-feature)
]

Refusing the wrong order:

@examples[#:eval ev #:label #f
(define (require-fortran-order m)
  (unless (contiguous? m #:layout 'col-major)
    (error 'least-squares "expected a col-major matrix, given ~a" (layout m)))
  m)
(shape (require-fortran-order (contiguous X #:layout 'col-major)))
(shape (require-fortran-order one-feature))
(eval:error (require-fortran-order X))
]}

@defproc[(contiguous [a device-matrix?]
                     [#:layout layout (or/c 'row-major 'col-major) 'row-major])
         device-matrix?]{

Returns @racket[a] in @racket[layout]: @racket[a] itself if
@racket[(contiguous? a #:layout layout)], otherwise a copy made on the GPU
on @racket[a]'s stream and resources.

@examples[#:eval ev
(define Xf (contiguous X #:layout 'col-major))
(list (layout Xf) (strides Xf))
(equal? (device-matrix->list* Xf) (device-matrix->list* X))
]

Already in layout, no copy:

@examples[#:eval ev #:label #f
(eq? (contiguous Xf #:layout 'col-major) Xf)
(eq? (contiguous X) X)
]

Back to row-major:

@examples[#:eval ev #:label #f
(define Xr (contiguous Xf))
(list (layout Xr) (kmeans-input? Xr))
]

Integer matrices:

@examples[#:eval ev #:label #f
(contiguous (list*->device-matrix '((1 2 3) (4 5 6)) #:dtype 'int32)
            #:layout 'col-major)
]}

@section[#:tag "ref-array-convert"]{Converting Racket data}

Without @racket[#:dtype], the element type is inferred: all
exact integers give @racket['int64], anything else (or an empty list)
@racket['float64]. An integer type truncates toward zero. A value the type
cannot hold (a complex number, an out-of-range integer, a non-finite value
for an integer type, a finite value too large for a float type) raises
@racket[exn:fail:raft]. Coming back, the conversions wait for the array's
stream; float elements become flonums, integer elements exact integers.
@racketmodname[raft/compat] adds other Racket containers by the same rules
(@secref["ref-compat"]).

@defproc[(list->device-vector [xs (listof real?)]
                              [#:dtype dtype (or/c #f 'float32 'float64 'int32 'int64) #f]
                              [#:resources resources device-resources?
                                           (current-device-resources)])
         device-vector?]{

Returns a vector holding @racket[xs], of @racket[dtype] or the inferred
type.

@examples[#:eval ev
(list->device-vector '(3 1 4 1 5))
(list->device-vector '(0.25 0.5) #:dtype 'float32)
]

Rationals become floats; values the type cannot hold raise:

@examples[#:eval ev #:label #f
(device-vector->list (list->device-vector '(1/2 1/4 3)))
(eval:error (list->device-vector '(1 2+3i)))
(eval:error (list->device-vector '(3000000000) #:dtype 'int32))
]

Cluster labels:

@examples[#:eval ev #:label #f
(define assigned (list->device-vector '(0 2 1 2) #:dtype 'int32))
(list (dtype assigned) (shape assigned))
]}

@defproc[(device-vector->list [v device-vector?]) (listof real?)]{

Returns the elements of @racket[v] as a list.

@examples[#:eval ev
(device-vector->list assigned)
]

Cluster sizes from labels:

@examples[#:eval ev #:label #f
(define (cluster-sizes labels k)
  (define all (device-vector->list labels))
  (for/list ([c (in-range k)])
    (count (lambda (l) (= l c)) all)))
(cluster-sizes assigned 3)
]

@racket['float32] elements widen:

@examples[#:eval ev #:label #f
(device-vector->list (list->device-vector '(0.1 0.5) #:dtype 'float32))
]}

@defproc[(list*->device-matrix [rows (listof (listof real?))]
                               [#:dtype dtype (or/c #f 'float32 'float64 'int32 'int64) #f]
                               [#:layout layout (or/c 'row-major 'col-major) 'row-major]
                               [#:resources resources device-resources?
                                            (current-device-resources)])
         device-matrix?]{

Returns a matrix whose rows are @racket[rows], of @racket[dtype] or the
inferred type, packed in @racket[layout] on the host. A ragged row raises
@racket[exn:fail:raft].

@examples[#:eval ev
(list*->device-matrix '((1 2) (3 4)))
(list*->device-matrix samples #:dtype 'float32 #:layout 'col-major)
]

Rows parsed from CSV lines:

@examples[#:eval ev #:label #f
(define lines '("5.1,3.5,1.4,0.2" "7.0,3.2,4.7,1.4"))
(define parsed
  (for/list ([line (in-list lines)])
    (map string->number (string-split line ","))))
(shape (list*->device-matrix parsed #:dtype 'float32))
]

A ragged row is named:

@examples[#:eval ev #:label #f
(eval:error (list*->device-matrix '((1 2 3) (4 5 6) (7 8))))
]}

@defproc[(device-matrix->list* [m device-matrix?]) (listof (listof real?))]{

Returns the rows of @racket[m] as a list of lists, whatever its layout.

@examples[#:eval ev
(device-matrix->list* (list*->device-matrix '((1 2) (3 4))))
]

Column-major:

@examples[#:eval ev #:label #f
(device-matrix->list* (list*->device-matrix '((1 2) (3 4)) #:layout 'col-major))
]

A table of centroids:

@examples[#:eval ev #:label #f
(define found (list*->device-matrix '((5.0 3.4) (6.6 3.0)) #:dtype 'float64))
(for ([row (in-list (device-matrix->list* found))]
      [c (in-naturals)])
  (printf "cluster ~a: ~a\n" c (string-join (map ~a row) " ")))
]}

@defproc[(flvector->device-vector [xs flvector?]
                                  [#:dtype dtype (or/c 'float32 'float64 'int32 'int64) 'float64]
                                  [#:resources resources device-resources?
                                               (current-device-resources)])
         device-vector?]{

Returns a vector holding the elements of @racket[xs], of @racket[dtype]. An
integer type truncates toward zero.

@examples[#:eval ev
(flvector->device-vector (flvector 0.5 1.5 2.5))
]

As @racket['float32]:

@examples[#:eval ev #:label #f
(define roots
  (for/flvector ([i (in-range 5)])
    (flsqrt (->fl i))))
(flvector->device-vector roots #:dtype 'float32)
]

Truncated to integers:

@examples[#:eval ev #:label #f
(device-vector->list (flvector->device-vector (flvector 0.7 2.2 -1.5) #:dtype 'int64))
]}

@defproc[(device-vector->flvector [v device-vector?]) flvector?]{

Returns the elements of @racket[v] as an @racket[flvector].

@examples[#:eval ev
(device-vector->flvector (flvector->device-vector (flvector 1.0 2.0)))
]

Other types widen to flonums:

@examples[#:eval ev #:label #f
(device-vector->flvector (list->device-vector '(0.1) #:dtype 'float32))
(device-vector->flvector (list->device-vector '(1 2 3)))
]

Into flonum code:

@examples[#:eval ev #:label #f
(define v (device-vector->flvector (list->device-vector '(3.0 4.0))))
(flsqrt (for/fold ([sum 0.0]) ([x (in-flvector v)]) (fl+ sum (fl* x x))))
]}

@section[#:tag "ref-array-csr"]{Sparse matrices}

A @deftech{CSR matrix} is a sparse matrix in compressed sparse row form: three
@tech{device array} vectors and a shape. @racket[csr-indptr] has one element
more than rows; row @racket[i]'s entries sit at the positions from element
@racket[i] of @racket[(csr-indptr m)] up to element @racket[(add1 i)].
@racket[csr-indices] holds their columns and @racket[csr-data] their values.
The two index vectors are both @racket['int32] or both @racket['int64]; the
data is @racket['float32] or @racket['float64].

A row's columns may come in any order and repeat; a repeated entry stands for
the sum of its values.

@examples[#:eval ev #:label #f
(define G (list*->device-csr-matrix '((0 1.5 0 0) (0 0 0 0) (2 0 0 -3)) #:dtype 'float32))
G
]

@defproc[(device-csr-matrix [indptr device-vector?]
                            [indices device-vector?]
                            [data device-vector?]
                            [#:shape shape (list/c exact-nonnegative-integer?
                                                   exact-nonnegative-integer?)])
         device-csr-matrix?]{

Makes a @tech{CSR matrix} of @racket[shape] over the three vectors without
copying them, after checking on the GPU that @racket[indptr] has rows + 1
elements, starts at 0, never decreases and ends at the length of
@racket[indices], that @racket[data] is as long as @racket[indices], and that
every index is in [0, cols). A failed check raises @racket[exn:fail:raft] of
kind @racket['logic], naming the vector and its first bad entry. The matrix
prints its dtype, shape, entry count, index type and device, then its entries
as @tt{(row col) value} in storage order, the first and last 25 of more than
50.

@examples[#:eval ev
(define indptr (list->device-vector '(0 2 2 3) #:dtype 'int32))
(define indices (list->device-vector '(3 0 1) #:dtype 'int32))
(define vals (list->device-vector '(0.5 1.0 2.0) #:dtype 'float32))
(define A (device-csr-matrix indptr indices vals #:shape '(3 4)))
(device-csr-matrix->list* A)
(eq? (csr-indices A) indices)
(eval:error (device-csr-matrix (list->device-vector '(0 3 2 3) #:dtype 'int32)
                               indices
                               vals
                               #:shape '(3 4)))
]}

@defproc[(device-csr-matrix? [v any/c]) boolean?]{

Returns @racket[#t] if @racket[v] is a @tech{CSR matrix}.

@examples[#:eval ev
(device-csr-matrix? G)
(device-csr-matrix? X)
(device-array? G)
]}

@deftogether[(@defproc[(csr-indptr [m device-csr-matrix?]) device-vector?]
              @defproc[(csr-indices [m device-csr-matrix?]) device-vector?]
              @defproc[(csr-data [m device-csr-matrix?]) device-vector?])]{

Return the vectors @racket[m] was made of, not copies.

@examples[#:eval ev
(device-vector->list (csr-indptr G))
(device-vector->list (csr-indices G))
(device-vector->list (csr-data G))
]}

@defproc[(nnz [m device-csr-matrix?]) exact-nonnegative-integer?]{

Returns the number of stored entries, repeats and explicit zeros included.

@examples[#:eval ev
(nnz G)
(nnz (triplets->device-csr-matrix '(0 0) '(1 1) '(1.0 -1.0) #:shape '(1 2)))
]}

@defproc[(list*->device-csr-matrix [rows (or/c (listof (or/c list? vector?))
                                               (vectorof (or/c list? vector?)))]
                                   [#:dtype dtype (or/c 'float32 'float64) 'float64]
                                   [#:index-dtype index-dtype (or/c 'int32 'int64) 'int32]
                                   [#:resources resources device-resources?
                                                (current-device-resources)])
         device-csr-matrix?]{

Makes a @tech{CSR matrix} of the entries of @racket[rows] that are not zero,
columns ascending in each row. @racket[rows] is rows as for
@racket[list*->device-matrix]; a value that converts to zero is not stored.

@examples[#:eval ev
(device-csr-matrix->list* G)
(list*->device-csr-matrix '((0 1) (2 0)) #:index-dtype 'int64)
(eval:error (list*->device-csr-matrix '((1 2) (3))))
]}

@defproc[(device-csr-matrix->list* [m device-csr-matrix?]) (listof (listof flonum?))]{

Returns @racket[m] as rows of flonums; repeated entries are summed. The rows
must fit in host memory: a 1 × 3,000,000,000 matrix converts by
@racket[device-csr-matrix->triplets].

@examples[#:eval ev
(device-csr-matrix->list* G)
]}

@defproc[(triplets->device-csr-matrix [rows (listof exact-nonnegative-integer?)]
                                      [cols (listof exact-nonnegative-integer?)]
                                      [vals (listof real?)]
                                      [#:shape shape (list/c exact-nonnegative-integer?
                                                             exact-nonnegative-integer?)]
                                      [#:dtype dtype (or/c 'float32 'float64) 'float64]
                                      [#:index-dtype index-dtype (or/c 'int32 'int64) 'int32]
                                      [#:resources resources device-resources?
                                                   (current-device-resources)])
         device-csr-matrix?]{

Makes a @tech{CSR matrix} with value @racket[(list-ref vals i)] at row
@racket[(list-ref rows i)], column @racket[(list-ref cols i)]; entries are
sorted by row and column and repeats are summed. Zeros, and repeats that sum
to zero, are stored.

An edge list to an adjacency matrix:

@examples[#:eval ev
(define edges '((0 1) (1 2) (2 0) (2 1)))
(define adjacency
  (triplets->device-csr-matrix (map first edges)
                               (map second edges)
                               (make-list (length edges) 1.0)
                               #:shape '(3 3)))
(device-csr-matrix->list* adjacency)
(eval:error (triplets->device-csr-matrix '(0 3) '(0 1) '(1.0 2.0) #:shape '(3 3)))
]}

@defproc[(device-csr-matrix->triplets [m device-csr-matrix?])
         (values (listof exact-nonnegative-integer?)
                 (listof exact-nonnegative-integer?)
                 (listof flonum?))]{

Returns the rows, columns and values of @racket[m]'s stored entries, in
storage order.

@examples[#:eval ev
(device-csr-matrix->triplets G)
]}

@(close-eval ev)
