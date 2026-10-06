#lang scribble/manual
@(require "../utils.rkt")

@(define ev (make-raft-eval))

@title[#:tag "arrays"]{Device arrays}

A @tech{device array} is a matrix or a vector in GPU memory. This chapter
prepares a small dataset for two cuML algorithms, k-means and least squares;
each section adds to the one before. The cuML calls live in a separate
package, through an interface that arrives later @status{L1d}.

@section[#:tag "arrays-upload"]{A dataset on the GPU}

Six of Fisher's iris flowers, four measurements each, in the
@racket['float32] cuML works in:

@examples[#:eval ev #:label #f
(define samples
  '((5.1 3.5 1.4 0.2)
    (4.9 3.0 1.4 0.2)
    (7.0 3.2 4.7 1.4)
    (6.4 3.2 4.5 1.5)
    (6.3 3.3 6.0 2.5)
    (5.8 2.7 5.1 1.9)))
(define X (list*->device-matrix samples #:dtype 'float32))
X
]

Printing copies the values back, so it waits for the GPU.

@section[#:tag "arrays-inspect"]{What the program made}

Before handing @racket[X] to a library, the program checks it:

@examples[#:eval ev #:label #f
(shape X)
(dtype X)
(layout X)
(strides X)
(numel X)
]

Each row is contiguous: the next element along a row is 1 away, the next
row 4 away.

Strides count elements, not bytes.

@section[#:tag "arrays-outputs"]{Room for k-means' answers}

RAFT and cuML write into arrays the caller allocates. k-means with three
clusters writes an @racket['int32] label per sample and three centroids:

@examples[#:eval ev #:label #f
(define k 3)
(match-define (list n d) (shape X))
(define labels (device-vector n #:dtype 'int32))
(define centroids (device-matrix k d))
(list (shape labels) (dtype labels))
(list (shape centroids) (dtype centroids) (layout centroids))
]

@racket[device-vector] and @racket[device-matrix] allocate without
initialising.

@section[#:tag "arrays-layout"]{Column-major for the solver}

Least squares predicts petal width from the first three measurements, and
cuML's solvers read column-major input. Taking columns of a device matrix
arrives later @status{L3}, so the features come from @racket[samples]:

@examples[#:eval ev #:label #f
(define feature-rows (map (lambda (row) (take row 3)) samples))
(define features (list*->device-matrix feature-rows #:dtype 'float32))
(define F (contiguous features #:layout 'col-major))
F
(layout F)
(strides F)
(contiguous? F #:layout 'col-major)
(equal? (device-matrix->list* F) (device-matrix->list* features))
]

Same matrix, different memory order. A column-major solver handed the
row-major buffer would silently read wrong numbers. @racket[contiguous]
copies on the GPU, and only when it has to:

@examples[#:eval ev #:label #f
(eq? (contiguous F #:layout 'col-major) F)
(eq? (contiguous X) X)
]

Data from Racket can be packed column-major on the host instead:

@examples[#:eval ev #:label #f
(define F* (list*->device-matrix feature-rows #:dtype 'float32 #:layout 'col-major))
(strides F*)
(equal? (device-matrix->list* F*) (device-matrix->list* F))
]

@section[#:tag "arrays-back"]{Bringing values back}

The solver's targets, the petal widths, come from an @racket[flvector]:

@examples[#:eval ev #:label #f
(define widths
  (for/flvector ([row (in-list samples)])
    (last row)))
(define y (flvector->device-vector widths #:dtype 'float32))
y
(device-vector->flvector y)
]

Float elements come back as flonums, integer elements as exact integers.
A @racket['float32] cannot hold 0.2 exactly, so what comes back is the
nearest @racket['float32], widened; keep exact values in
@racket['float64], the type inferred for @racket[samples]:

@examples[#:eval ev #:label #f
(first (device-matrix->list* F))
(first (device-matrix->list* (list*->device-matrix samples)))
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

The memory comes back at a collection after the last use. A form that frees
an array at a known point arrives later @status{L3}.
