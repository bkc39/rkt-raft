#lang scribble/manual
@(require "../utils.rkt")

@(define ev (make-raft-eval))

@title[#:tag "arrays"]{Device arrays}

A @tech{device array} is a matrix or a vector in GPU memory. This chapter
loads a dataset, puts it on the GPU, inspects it, changes its layout, brings
values back and lets it go.

@section[#:tag "arrays-upload"]{A dataset on the GPU}

The @tt{datasets} package loads Fisher's iris flowers as a Polars
dataframe:

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
