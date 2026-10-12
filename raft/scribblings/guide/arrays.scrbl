#lang scribble/manual
@(require "../utils.rkt")

@(define ev (make-raft-eval))

@title[#:tag "arrays"]{Device arrays}

A @tech{device array} is a matrix or a vector in GPU memory. This chapter
loads a dataset, puts it on the GPU, inspects it, changes its layout, moves
other forms of Racket data, brings values back and lets it go.

@section[#:tag "arrays-upload"]{A dataset on the GPU}

The @tt{datasets} package loads Fisher's iris flowers as a Polars
dataframe:

@examples[#:eval ev #:hidden
(putenv "POLARS_TABLE_WIDTH" "100")
]

@examples[#:eval ev #:label #f
(require datasets
         (only-in polars in-dataframe-columns series->list))
(define iris (load-iris))
iris
]

The four measurement columns, as a list of rows:

@examples[#:eval ev #:label #f
(define measurements '("sepal-length" "sepal-width" "petal-length" "petal-width"))
(define rows
  (apply map
         list
         (for/list ([column (in-dataframe-columns iris #:columns measurements)])
           (series->list column))))
(length rows)
(take rows 3)
]

On the GPU, as a @racket['float32] matrix:

@examples[#:eval ev #:label #f
(define X (list*->device-matrix rows #:dtype 'float32))
X
]

Printing copies the values back, so it waits for the GPU. The matrix knows
its shape, element type, layout and strides:

@examples[#:eval ev #:label #f
(shape X)
(dtype X)
(layout X)
(strides X)
(numel X)
]

Each row is contiguous: the next element along a row is 1 away, the next row
4 away. Strides count elements, not bytes.

@section[#:tag "arrays-layout"]{Changing the layout}

@racket[contiguous] copies a matrix into the other layout on the GPU:

@examples[#:eval ev #:label #f
(define F (contiguous X #:layout 'col-major))
(layout F)
(strides F)
(contiguous? F #:layout 'col-major)
(equal? (device-matrix->list* F) (device-matrix->list* X))
]

Same values, different memory order. @racket[contiguous] copies only when it
has to:

@examples[#:eval ev #:label #f
(eq? (contiguous F #:layout 'col-major) F)
(eq? (contiguous X) X)
]

Data from Racket can be packed column-major on the host instead:

@examples[#:eval ev #:label #f
(define F* (list*->device-matrix rows #:dtype 'float32 #:layout 'col-major))
(strides F*)
(equal? (device-matrix->list* F*) (device-matrix->list* F))
]

@section[#:tag "moving-data"]{Other forms of Racket data}

@racketmodname[raft/compat] converts the other forms Racket keeps numbers in,
by the same dtype and layout rules:

@examples[#:eval ev #:label #f
(require raft/compat
         ffi/vector
         math/array
         math/matrix
         racket/file)
]

@racket[list*->device-array] reads the rank from the nesting:

@examples[#:eval ev #:label #f
(shape (list*->device-array rows))
(shape (list*->device-array (first rows)))
]

A vector: the species, numbered in order of appearance, as
@racket['int32] labels:

@examples[#:eval ev #:label #f
(define species
  (for/first ([column (in-dataframe-columns iris #:columns '("species"))])
    (series->list column)))
(define names (remove-duplicates species))
(define labels
  (vector->device-vector (for/vector ([s (in-list species)])
                           (index-of names s))
                         #:dtype 'int32))
labels
]

A @racketmodname[math/matrix] matrix: the measurements' covariance, computed on
the host:

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

An @racket[f64vector], as foreign code fills one; a loop stands in for it:

@examples[#:eval ev #:label #f
(define weights (make-f64vector n 1.0))
(f64vector-set! weights 0 2.0)
(define w (f64vector->device-vector weights #:dtype 'float32))
w
]

Narrowing to @racket['float32] raises on a value too large rather than giving
an infinity.

@section[#:tag "arrays-back"]{Bringing values back}

The petal widths, from an @racket[flvector]:

@examples[#:eval ev #:label #f
(define widths
  (for/flvector ([row (in-list rows)])
    (last row)))
(define y (flvector->device-vector widths #:dtype 'float32))
y
(take (device-vector->list y) 4)
]

Float elements come back as flonums, integer elements as exact integers. A
@racket['float32] cannot hold 0.2 exactly, so what comes back is the nearest
@racket['float32], widened; keep exact values in @racket['float64], the type
inferred for @racket[rows]:

@examples[#:eval ev #:label #f
(first (device-matrix->list* X))
(first (device-matrix->list* (list*->device-matrix rows)))
]

Each conversion names the Racket form it makes. The covariance comes back as
a @racketmodname[math/array] flonum array, off only by the @racket['float32]
rounding; column means through @racketmodname[math/array]; species counts from
a vector; the weights as raw bytes, through a file:

@examples[#:eval ev #:label #f
(< (array-all-max (array-abs (array- (device-matrix->matrix C) covariance))) 1e-6)
(array-scale (array-axis-sum (device-array->array X) 0) (/ 1.0 n))
(define counts (make-vector (length names) 0))
(for ([label (in-vector (device-vector->vector labels))])
  (vector-set! counts label (add1 (vector-ref counts label))))
counts
(define saved (make-temporary-file))
(display-to-file (device-vector->bytes w) saved #:exists 'truncate)
(file-size saved)
(take (device-vector->list (bytes->device-vector (file->bytes saved) #:dtype 'float32)) 3)
]

@examples[#:eval ev #:hidden
(delete-file saved)
]

@section[#:tag "arrays-memory"]{Letting go}

The program never frees an array: when one becomes unreachable, its
finalizer returns the memory. Each buffer counts its size as @tech{phantom
bytes}, so GPU memory held brings collections sooner:

@examples[#:eval ev #:label #f
(collect-garbage)
(define before (current-memory-use))
(define scratch (device-matrix 1024 1024))
(quotient (- (current-memory-use) before) (* 1024 1024))
(set! scratch #f)
(collect-garbage)
(< (- (current-memory-use) before) (* 1024 1024))
]

The memory comes back at a collection after the last use.
