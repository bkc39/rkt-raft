#lang scribble/manual
@(require "../utils.rkt")

@(define ev (make-raft-eval))

@title[#:tag "ref-array"]{Device arrays: @racketmodname[raft/array]}

@defmodule[raft/array]

A @deftech{device array} is a matrix or a vector whose elements live in GPU
memory: one native RMM allocation, its @tech{buffer}, read through a shape,
@tech{strides}, an offset and a @tech{dtype}. Four element types exist:
@racket['float32], @racket['float64], @racket['int32] and @racket['int64].
A matrix is @tech{row-major} or @tech{column-major}. @racketmodname[raft]
re-exports this module, and the guide chapter @secref["arrays"] uses it in
one program.

The examples below share these values:

@examples[#:eval ev #:label #f
(define samples
  '((5.1 3.5 1.4 0.2)
    (4.9 3.0 1.4 0.2)
    (7.0 3.2 4.7 1.4)
    (6.4 3.2 4.5 1.5)))
(define X (list*->device-matrix samples #:dtype 'float32))
]

@bold{Memory.} Every array allocates through the @tech{resources} it is
given, @racket[(current-device-resources)] unless @racket[#:resources] says
otherwise, on their device and from RMM's current memory resource, and its
work is queued on their @tech{stream}. The buffer keeps that stream and the
resources' handle alive, so an array outlives the resources object it was
made with. When the array becomes unreachable, the garbage collector runs the
buffer's finalizer, which returns the memory on that stream. Each buffer
registers its size as @tech{phantom bytes}, so device memory held counts
towards Racket's memory use, and collections come sooner the more of it is
held.

@bold{Printing.} An array prints its element type, shape, layout and device,
then its values, as NumPy does: whole up to 1000 elements, and beyond that
the first and last three along each axis. A @racket['float32] value prints as
the shortest decimal that reads back as the same @racket['float32]. Printing
copies the values it shows to the host, so it waits for the array's stream.
Printing never raises: if the values cannot be read, the array prints its
header and @tt{<values unavailable: ...>} with the reason, so an error
message that shows an array keeps its own meaning.

@bold{Errors.} The native library refuses what it cannot handle safely, such
as an unknown element type or layout, or a negative extent, and the refusal
raises @racket[exn:fail:raft] of kind @racket['logic], named after the
procedure that was called. There are no contracts yet, so an argument of the
wrong kind may raise a different error.

@section[#:tag "ref-array-make"]{Making arrays}

@defproc[(device-matrix [rows exact-nonnegative-integer?]
                        [cols exact-nonnegative-integer?]
                        [#:dtype dtype (or/c 'float32 'float64 'int32 'int64) 'float32]
                        [#:layout layout (or/c 'row-major 'col-major) 'row-major]
                        [#:resources resources device-resources?
                                     (current-device-resources)])
         device-matrix?]{

Allocates a @racket[rows]-by-@racket[cols] matrix of @racket[dtype] in
@racket[layout], without initialising its elements: they hold whatever the
memory held before, as with NumPy's @tt{np.empty}. It is
@tt{raft::make_device_matrix} in RAFT and
@tt{device_ndarray.empty((rows, cols), dtype, order)} in pylibraft, whose
defaults, @tt{float32} and C order, are the same. Use it for an operation's
output, and read it only after something has written it.

@examples[#:eval ev
(define out (device-matrix 1000 128))
(list (shape out) (dtype out) (layout out))
]

An output shaped after its input, here the distances from each sample to each
of three centroids:

@examples[#:eval ev #:label #f
(define (distance-matrix data k)
  (match-define (list n _) (shape data))
  (device-matrix n k #:dtype (dtype data)))
(define distances (distance-matrix X 3))
(list (shape distances) (dtype distances))
]

A column-major output for a Fortran-order consumer, allocated through
resources of its own: least-squares coefficients for three features and two
targets.

@examples[#:eval ev #:label #f
(with-device-resources ([r (device-resources)])
  (define coefficients (device-matrix 3 2 #:dtype 'float64 #:layout 'col-major
                                      #:resources r))
  (list (layout coefficients) (strides coefficients)))
]

An element type the native library does not support is refused:

@examples[#:eval ev #:label #f
(eval:error (device-matrix 2 2 #:dtype 'float16))
]}

@defproc[(device-vector [n exact-nonnegative-integer?]
                        [#:dtype dtype (or/c 'float32 'float64 'int32 'int64) 'float32]
                        [#:resources resources device-resources?
                                     (current-device-resources)])
         device-vector?]{

Allocates a vector of @racket[n] elements of @racket[dtype], without
initialising them. It is @tt{raft::make_device_vector} and
@tt{device_ndarray.empty((n,), dtype)}. A vector's stride is 1, or 0 when it
has no elements, and it is in both layouts.

A label per sample, the way cuML's k-means writes them:

@examples[#:eval ev
(define labels (device-vector (first (shape X)) #:dtype 'int32))
(list (shape labels) (dtype labels) (strides labels))
]

Per-sample weights in double precision:

@examples[#:eval ev #:label #f
(define weights (device-vector 4 #:dtype 'float64))
(list (numel weights) (dtype weights))
]

A vector with one element for each column of a matrix, such as a column sum:

@examples[#:eval ev #:label #f
(define (per-column m)
  (device-vector (second (shape m)) #:dtype (dtype m)))
(shape (per-column X))
]}

@section[#:tag "ref-array-inspect"]{Inspecting arrays}

@defproc[(device-array? [v any/c]) boolean?]{

Returns @racket[#t] if @racket[v] is a @tech{device array}, a matrix or a
vector, and @racket[#f] otherwise.

@examples[#:eval ev
(device-array? X)
(device-array? labels)
(device-array? samples)
]

A procedure that takes data on either side, copying it to the device only
when it is not there already:

@examples[#:eval ev #:label #f
(define (on-device data)
  (if (device-array? data)
      data
      (list*->device-matrix data #:dtype 'float32)))
(eq? (on-device X) X)
(shape (on-device '((1.0 2.0))))
]

Counting the inputs of a pipeline that are already on the GPU:

@examples[#:eval ev #:label #f
(count device-array? (list X labels samples))
]}

@defproc[(device-matrix? [v any/c]) boolean?]{

Returns @racket[#t] if @racket[v] is a @tech{device array} with two axes.

@examples[#:eval ev
(device-matrix? X)
(device-matrix? labels)
]

Checking an input the way cuML's k-means wants it, a floating-point
row-major matrix:

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

Bringing either kind back to Racket data:

@examples[#:eval ev #:label #f
(define (->racket a)
  (if (device-vector? a)
      (device-vector->list a)
      (device-matrix->list* a)))
(->racket (list->device-vector '(1 2 3)))
(->racket (list*->device-matrix '((1 2) (3 4))))
]

Checking that sample weights match the samples:

@examples[#:eval ev #:label #f
(define (weights-fit? w m)
  (and (device-vector? w)
       (= (first (shape w)) (first (shape m)))))
(weights-fit? weights X)
(weights-fit? labels (device-matrix 5 2))
]}

@defproc[(shape [a device-array?]) (listof exact-nonnegative-integer?)]{

Returns the extents of @racket[a]: @racket[(list rows cols)] for a matrix,
@racket[(list n)] for a vector. It is NumPy's and pylibraft's @tt{.shape}, as
a list instead of a tuple.

@examples[#:eval ev
(shape X)
(shape labels)
]

Destructuring the shape to size the outputs of an algorithm:

@examples[#:eval ev #:label #f
(match-define (list n d) (shape X))
(define centroids (device-matrix 3 d))
(list n d (shape centroids))
]

Checking that two matrices can be combined element by element:

@examples[#:eval ev #:label #f
(define (same-shape? a b)
  (equal? (shape a) (shape b)))
(same-shape? X (contiguous X #:layout 'col-major))
(same-shape? X centroids)
]}

@defproc[(dtype [a device-array?]) (or/c 'float32 'float64 'int32 'int64)]{

Returns the element type of @racket[a]. It is pylibraft's @tt{.dtype}, as a
symbol.

@examples[#:eval ev
(dtype X)
(dtype labels)
]

An output of the same element type as its input:

@examples[#:eval ev #:label #f
(define (scratch-like a)
  (match-define (list rows cols) (shape a))
  (device-matrix rows cols #:dtype (dtype a)))
(dtype (scratch-like (list*->device-matrix '((1 2)) #:dtype 'int32)))
]

The element types the conversions infer from Racket data:

@examples[#:eval ev #:label #f
(map dtype (list (list->device-vector '(1 2 3))
                 (list->device-vector '(1 2.5))
                 (list->device-vector '(1/2))))
]}

@defproc[(layout [a device-array?]) (or/c 'row-major 'col-major)]{

Returns how the elements of @racket[a] are ordered in memory, read from its
strides: @racket['row-major] if each row is contiguous, as in C and NumPy's
default; @racket['col-major] if each column is, as in Fortran and BLAS. As
in NumPy, an axis of extent 1 does not constrain the layout, so a vector, a
matrix with one row or one column, and a matrix with no elements are laid out
both ways at once; for these @racket[layout] answers @racket['row-major], as
pylibraft's @tt{c_contiguous} answers @tt{True}.

@examples[#:eval ev
(layout X)
(layout (contiguous X #:layout 'col-major))
]

Arrays that are in both layouts report @racket['row-major]; to ask whether
an array is in a given layout, use @racket[contiguous?], which answers
@racket[#t] for both:

@examples[#:eval ev #:label #f
(define column (device-matrix 5 1 #:layout 'col-major))
(list (strides column) (layout column) (layout labels))
(contiguous? column #:layout 'col-major)
]

A log line for each input of a pipeline:

@examples[#:eval ev #:label #f
(for ([a (list X labels)])
  (printf "~a ~a ~a\n" (dtype a) (shape a) (layout a)))
]}

@defproc[(strides [a device-array?]) (listof exact-nonnegative-integer?)]{

Returns, for each axis of @racket[a], how many elements apart two neighbours
along that axis are in memory. Strides count elements, as RAFT, DLPack and
PyTorch do. NumPy and CuPy count bytes, so their strides are these multiplied
by the element size; pylibraft reports @tt{None} for a C-contiguous array.
A matrix with no elements has all strides 0, as in NumPy.

@examples[#:eval ev
(strides X)
(strides (contiguous X #:layout 'col-major))
(strides (device-matrix 0 4))
]

Where element (i, j) sits in the buffer, counted in elements:

@examples[#:eval ev #:label #f
(define (element-index a i j)
  (+ (* i (first (strides a))) (* j (second (strides a)))))
(element-index X 2 1)
(element-index (contiguous X #:layout 'col-major) 2 1)
]

NumPy's byte strides for the same matrix:

@examples[#:eval ev #:label #f
(define (byte-strides a)
  (define size (if (memq (dtype a) '(float32 int32)) 4 8))
  (map (lambda (s) (* s size)) (strides a)))
(byte-strides X)
]}

@defproc[(numel [a device-array?]) exact-nonnegative-integer?]{

Returns the number of elements of @racket[a], the product of its extents.
NumPy calls it @tt{size}; this library uses rktorch's name.

@examples[#:eval ev
(numel X)
(numel labels)
]

The device memory an array's elements take:

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

Returns @racket[#t] if the elements of @racket[a] are laid out in
@racket[layout], so that a consumer reading that order can take @racket[a]
as it is. As in NumPy's @tt{flags.c_contiguous} and @tt{flags.f_contiguous},
an axis of extent 1 does not constrain the layout: a vector, a matrix with
one row or one column, and a matrix with no elements are contiguous in both
layouts. @racket[contiguous] returns its argument exactly when this answers
@racket[#t].

@examples[#:eval ev
(contiguous? X)
(contiguous? X #:layout 'col-major)
(contiguous? (contiguous X #:layout 'col-major) #:layout 'col-major)
]

A single feature column is in both layouts, so a least-squares solver can
take it without a copy:

@examples[#:eval ev #:label #f
(define one-feature (list*->device-matrix '((5.1) (4.9) (7.0)) #:dtype 'float32))
(list (contiguous? one-feature) (contiguous? one-feature #:layout 'col-major))
(eq? (contiguous one-feature #:layout 'col-major) one-feature)
]

Refusing a matrix in the wrong order before a call that assumes one:

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

Returns a matrix holding the same rows and columns as @racket[a], in
@racket[layout]. If @racket[(contiguous? a #:layout layout)], the result is
@racket[a] itself and nothing is copied; otherwise it is a new matrix, copied
on the GPU by RAFT's copy between a row-major and a column-major view (cuBLAS
for @racket['float32] and @racket['float64], a RAFT kernel for the integer
types), queued on @racket[a]'s stream and allocated with its resources. It is
@tt{cp.ascontiguousarray} with the default @racket[layout] and
@tt{cp.asfortranarray} with @racket['col-major]. A vector is already in both
layouts, so @racket[contiguous] returns it unchanged.

@examples[#:eval ev
(define Xf (contiguous X #:layout 'col-major))
(list (layout Xf) (strides Xf))
(equal? (device-matrix->list* Xf) (device-matrix->list* X))
]

Calling it when the layout is already right costs nothing:

@examples[#:eval ev #:label #f
(eq? (contiguous Xf #:layout 'col-major) Xf)
(eq? (contiguous X) X)
]

Back to row-major for a consumer that reads rows, such as k-means:

@examples[#:eval ev #:label #f
(define Xr (contiguous Xf))
(list (layout Xr) (kmeans-input? Xr))
]

Integer matrices change layout too:

@examples[#:eval ev #:label #f
(contiguous (list*->device-matrix '((1 2 3) (4 5 6)) #:dtype 'int32)
            #:layout 'col-major)
]}

@section[#:tag "ref-array-convert"]{Converting Racket data}

These conversions copy between Racket values and the device. Going to the
device, the element type is inferred as NumPy infers it unless
@racket[#:dtype] gives one: all exact integers give @racket['int64], any other
real numbers @racket['float64], and an empty list @racket['float64]. Exact
rationals become floats. An integer type truncates other numbers toward zero,
as NumPy's casts do. A value the element type cannot hold, such as a complex
number, an infinity or NaN for an integer type, an integer out of the
type's range, or a finite number too large for a float type (where NumPy
would store an infinity), raises @racket[exn:fail:raft] naming the
procedure. Infinities and NaN themselves pass into float types. A
matrix's @racket[#:layout] decides the order the values are packed in on the
host, so no copy runs on the GPU to change it. Coming back, the conversions
wait for the work queued on the array's stream, as @racket[resources-sync!]
does, then copy; floating-point elements become flonums and integer elements
exact integers. @racketmodname[raft/compat] adds vectors and nested vectors,
@racket[f32vector]s, @racket[f64vector]s, byte strings, and
@racketmodname[math/matrix] and @racketmodname[math/array] values, by these
same rules (@secref["ref-compat"]).

@defproc[(list->device-vector [xs (listof real?)]
                              [#:dtype dtype (or/c #f 'float32 'float64 'int32 'int64) #f]
                              [#:resources resources device-resources?
                                           (current-device-resources)])
         device-vector?]{

Returns a vector holding @racket[xs], of @racket[dtype], or of the inferred
type when @racket[dtype] is @racket[#f]. It is
@tt{device_ndarray(np.array(xs, dtype))}.

@examples[#:eval ev
(list->device-vector '(3 1 4 1 5))
(list->device-vector '(0.25 0.5) #:dtype 'float32)
]

Exact rationals become floats; values the type cannot hold are refused:

@examples[#:eval ev #:label #f
(device-vector->list (list->device-vector '(1/2 1/4 3)))
(eval:error (list->device-vector '(1 2+3i)))
(eval:error (list->device-vector '(3000000000) #:dtype 'int32))
]

Cluster labels from Racket, in the type cuML writes them:

@examples[#:eval ev #:label #f
(define assigned (list->device-vector '(0 2 1 2) #:dtype 'int32))
(list (dtype assigned) (shape assigned))
]}

@defproc[(device-vector->list [v device-vector?]) (listof real?)]{

Returns the elements of @racket[v] as a list, after the work queued on its
stream has finished. It is @tt{v.copy_to_host().tolist()}.

@examples[#:eval ev
(device-vector->list assigned)
]

Counting the samples in each cluster from a vector of labels:

@examples[#:eval ev #:label #f
(define (cluster-sizes labels k)
  (define all (device-vector->list labels))
  (for/list ([c (in-range k)])
    (count (lambda (l) (= l c)) all)))
(cluster-sizes assigned 3)
]

A @racket['float32] element comes back as the nearest flonum, as NumPy's
@tt{tolist} gives it:

@examples[#:eval ev #:label #f
(device-vector->list (list->device-vector '(0.1 0.5) #:dtype 'float32))
]}

@defproc[(list*->device-matrix [rows (listof (listof real?))]
                               [#:dtype dtype (or/c #f 'float32 'float64 'int32 'int64) #f]
                               [#:layout layout (or/c 'row-major 'col-major) 'row-major]
                               [#:resources resources device-resources?
                                            (current-device-resources)])
         device-matrix?]{

Returns a matrix whose rows are @racket[rows], of @racket[dtype], or of the
inferred type, packed in @racket[layout]. Every row must have the same length;
a ragged row raises @racket[exn:fail:raft] naming the row. It is
@tt{device_ndarray(np.array(rows, dtype))}, or with @racket['col-major],
@tt{device_ndarray(np.asfortranarray(np.array(rows, dtype)))}.

@examples[#:eval ev
(list*->device-matrix '((1 2) (3 4)))
(list*->device-matrix samples #:dtype 'float32 #:layout 'col-major)
]

Rows parsed from comma-separated lines:

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

Returns the rows of @racket[m] as a list of lists, whatever its layout, after
the work queued on its stream has finished. It is
@tt{m.copy_to_host().tolist()}.

@examples[#:eval ev
(device-matrix->list* (list*->device-matrix '((1 2) (3 4))))
]

A column-major matrix still comes back as rows:

@examples[#:eval ev #:label #f
(device-matrix->list* (list*->device-matrix '((1 2) (3 4)) #:layout 'col-major))
]

A table of centroids, one line per cluster:

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

Returns a vector holding the elements of @racket[xs], of @racket[dtype]. For
@racket['float64] the flvector's storage is copied to the device directly, in
one call, with no packing; other types are packed first, an integer type
truncating toward zero.

@examples[#:eval ev
(flvector->device-vector (flvector 0.5 1.5 2.5))
]

Results of numeric code, sent as @racket['float32] for cuML:

@examples[#:eval ev #:label #f
(define roots
  (for/flvector ([i (in-range 5)])
    (flsqrt (->fl i))))
(flvector->device-vector roots #:dtype 'float32)
]

Bucket numbers from measurements, truncated:

@examples[#:eval ev #:label #f
(device-vector->list (flvector->device-vector (flvector 0.7 2.2 -1.5) #:dtype 'int64))
]}

@defproc[(device-vector->flvector [v device-vector?]) flvector?]{

Returns the elements of @racket[v] as an @racket[flvector], after the work
queued on its stream has finished. A @racket['float64] vector is copied
straight into the new flvector; other types are converted element by element.

@examples[#:eval ev
(device-vector->flvector (flvector->device-vector (flvector 1.0 2.0)))
]

@racket['float32] and integer vectors widen to flonums:

@examples[#:eval ev #:label #f
(device-vector->flvector (list->device-vector '(0.1) #:dtype 'float32))
(device-vector->flvector (list->device-vector '(1 2 3)))
]

Handing GPU results to flonum code:

@examples[#:eval ev #:label #f
(define v (device-vector->flvector (list->device-vector '(3.0 4.0))))
(flsqrt (for/fold ([sum 0.0]) ([x (in-flvector v)]) (fl+ sum (fl* x x))))
]}
