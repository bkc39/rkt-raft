#lang scribble/manual
@(require "../utils.rkt")

@(define ev (make-raft-eval))

@title[#:tag "arrays"]{Device arrays}

A @tech{device array} is a matrix or a vector whose elements live in GPU
memory. This chapter prepares a small dataset for two cuML algorithms, the way
a program does before it calls them. It puts the measurements on the GPU,
checks what it made, allocates the arrays k-means will write its answers
into, lays the data out in the order a least-squares solver reads it, brings
values back to Racket, and lets the memory go. Each section adds to the one
before.

The cuML calls themselves are not part of this library. A cuML binding is a
separate package built on it, through an interface that arrives later
@status{L1d}; what this chapter prepares is exactly what those calls take.

@section[#:tag "arrays-upload"]{A dataset on the GPU}

The data is six flowers from Fisher's iris measurements: sepal length, sepal
width, petal length and petal width, in centimetres, two flowers from each
species. cuML works in @racket['float32], so the program asks for it:

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

@racket[list*->device-matrix] checks that every row has the same length,
packs the numbers into a host buffer in the element type and order the
matrix will have, and copies that buffer to the device in one call. Printing
@racket[X] copies the values back to show them, so it waits for the GPU; the
header says what the matrix is and where it lives.

@python|{
import numpy as np
from pylibraft.common import device_ndarray

samples = [
    [5.1, 3.5, 1.4, 0.2],
    [4.9, 3.0, 1.4, 0.2],
    [7.0, 3.2, 4.7, 1.4],
    [6.4, 3.2, 4.5, 1.5],
    [6.3, 3.3, 6.0, 2.5],
    [5.8, 2.7, 5.1, 1.9],
]
X = device_ndarray(np.array(samples, dtype=np.float32))
X        # <pylibraft.common.device_ndarray.device_ndarray object at 0x7f…>
}|

In Python the packing is NumPy's: @tt{np.array} builds the host buffer and
@tt{device_ndarray} copies it. The Racket conversion is one step, and it
takes the element type as @racket[#:dtype]. A @tt{device_ndarray} prints as
an object; to see its values, copy it back with @tt{X.copy_to_host()} or hand
it to CuPy with @tt{cp.asarray(X)}.

@section[#:tag "arrays-inspect"]{What the program made}

Before handing @racket[X] to a library, the program checks it. Its
@racket[shape] is the number of rows and columns, its @racket[dtype] the
element type, its @racket[layout] the order the elements sit in memory, and
its @racket[strides] how many elements apart neighbours are along each axis:

@examples[#:eval ev #:label #f
(shape X)
(dtype X)
(layout X)
(strides X)
(numel X)
]

@racket['row-major] means each row is stored contiguously, so the next
element along a row is 1 away and the next row is 4 away, as the strides say.

@python|{
X.shape                                       # (6, 4)
X.dtype                                       # dtype('float32')
X.c_contiguous                                # True
X.strides                                     # None
np.array(samples, dtype=np.float32).strides   # (16, 4)
X.copy_to_host().size                         # 24
}|

The two sides count strides differently. Racket counts them in elements, as
RAFT, DLPack and PyTorch do; NumPy and CuPy count bytes, so a
@racket['float32] row of four is 16 bytes, not 4. And pylibraft reports
@tt{None} for the strides of a C-contiguous array, which is what
@tt{__array_interface__} does, rather than computing them. pylibraft has no
element count of its own; NumPy calls it @tt{size}, and this library calls
it @racket[numel], as rktorch does.

@section[#:tag "arrays-outputs"]{Room for k-means' answers}

RAFT and cuML do not allocate their results: the caller passes arrays for
them to write into. k-means with three clusters writes one label per sample,
an @racket['int32], and three centroids with as many columns as the data:

@examples[#:eval ev #:label #f
(define k 3)
(match-define (list n d) (shape X))
(define labels (device-vector n #:dtype 'int32))
(define centroids (device-matrix k d))
(list (shape labels) (dtype labels))
(list (shape centroids) (dtype centroids) (layout centroids))
]

@racket[device-vector] and @racket[device-matrix] allocate without
initialising, the way @tt{np.empty} does: the elements hold whatever the
memory held before, so the program reads them only after the algorithm has
written them. @racket[device-matrix] makes @racket['float32],
@racket['row-major] matrices unless told otherwise, the layout cuML's k-means
reads.

@python|{
k = 3
n, d = X.shape
labels = device_ndarray.empty((n,), dtype=np.int32)
centroids = device_ndarray.empty((k, d))
labels.shape, labels.dtype                       # ((6,), dtype('int32'))
centroids.shape, centroids.dtype, centroids.c_contiguous
# ((3, 4), dtype('float32'), True)
}|

The defaults match: @tt{device_ndarray.empty} also makes @tt{float32} in C
order unless told otherwise.

@section[#:tag "arrays-layout"]{Column-major for the solver}

The second algorithm predicts petal width from the other measurements by
least squares. Every solver behind cuML's @tt{LinearRegression} reads its
input in column-major (Fortran) order; cuML's own Python wrapper converts
with @tt{cp.array(X, order="F")} before it calls them. So before such a call
the program lays its features out column by column with
@racket[contiguous]. The features are the first three measurements; taking
columns of a device matrix arrives later @status{L3}, so the program takes
them from @racket[samples]:

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

@racket[F] is the same matrix as @racket[features], with the same rows and
columns; only the order of its elements in memory has changed. Now the next
element down a column is 1 away and the next column is 6 away. This is why
layout matters: a library reads memory, not rows and columns, and it assumes
an order. Handed the row-major buffer, a column-major solver would read the
wrong numbers into every column, and nothing would raise an error.

The copy runs on the GPU, through RAFT's copy between a row-major and a
column-major view. @racket[contiguous] copies only when it has to, so a
program can call it before every solver without paying twice:

@examples[#:eval ev #:label #f
(eq? (contiguous F #:layout 'col-major) F)
(eq? (contiguous X) X)
]

When the data starts out in Racket, it can be packed column by column on the
host instead, and no copy runs on the GPU at all:

@examples[#:eval ev #:label #f
(define F* (list*->device-matrix feature-rows #:dtype 'float32 #:layout 'col-major))
(strides F*)
(equal? (device-matrix->list* F*) (device-matrix->list* F))
]

@python|{
import cupy as cp

feature_rows = [row[:3] for row in samples]
features = device_ndarray(np.array(feature_rows, dtype=np.float32))
F = cp.asfortranarray(cp.asarray(features))
F.flags.f_contiguous, F.strides         # (True, (4, 24))
cp.asfortranarray(F) is F               # True

F_ = device_ndarray(np.asfortranarray(np.array(feature_rows, dtype=np.float32)))
F_.f_contiguous, F_.strides             # (True, (4, 24))
}|

pylibraft cannot change an array's layout on the device; CuPy can, through
@tt{__cuda_array_interface__}, so the Python side reaches for it.
@tt{cp.asfortranarray} is @racket[contiguous] with @racket[#:layout
'col-major], and @tt{cp.ascontiguousarray} is its default,
@racket['row-major]. Packing on the host is @tt{np.asfortranarray} before the
copy.

@section[#:tag "arrays-back"]{Bringing values back}

The solver's targets are the petal widths, the last column. They are a
vector, and they come from an @racket[flvector], the form numeric Racket code
often produces:

@examples[#:eval ev #:label #f
(define widths
  (for/flvector ([row (in-list samples)])
    (last row)))
(define y (flvector->device-vector widths #:dtype 'float32))
y
(device-vector->flvector y)
]

Values come back as flonums from @racket['float32] and @racket['float64]
arrays and as exact integers from @racket['int32] and @racket['int64] ones.
A @racket['float32] cannot hold 0.2 or 1.9 exactly, so the flonums that come
back are the nearest @racket['float32] values, widened; the printed vector
shows the shortest decimal for each, as NumPy does. The features in
@racket[F] widen the same way. When the exact values matter on the way back,
keep them in @racket['float64], the type the conversion infers for
@racket[samples]:

@examples[#:eval ev #:label #f
(first (device-matrix->list* F))
(first (device-matrix->list* (list*->device-matrix samples)))
]

Reading back waits for the work queued on the array's stream to finish,
polling as @racket[resources-sync!] does, then copies.

@python|{
y = device_ndarray(np.array([row[-1] for row in samples], dtype=np.float32))
y.copy_to_host()           # array([0.2, 0.2, 1.4, 1.5, 2.5, 1.9], dtype=float32)
y.copy_to_host().tolist()
# [0.20000000298023224, 0.20000000298023224, 1.399999976158142, 1.5, 2.5,
#  1.899999976158142]
F.get().tolist()[0]        # [5.099999904632568, 3.5, 1.399999976158142]
}|

NumPy's @tt{tolist} widens @tt{float32} the same way. Unlike
@tt{copy_to_host}, which always makes a NumPy array of the array's own type,
the Racket conversions choose the Racket form: a list, a list of lists or an
@racket[flvector].

@section[#:tag "arrays-memory"]{Letting go}

The program never frees an array. When an array becomes unreachable, the
garbage collector runs its buffer's finalizer, which returns the memory to
RMM on the stream the array was allocated on. The collector cannot see GPU
memory, so each buffer also registers its size as @tech{phantom bytes}: a
4 MiB matrix makes Racket's memory use 4 MiB larger while it is reachable,
and collections come as often as if that memory were on the host.

@examples[#:eval ev #:label #f
(collect-garbage)
(define before (current-memory-use))
(define scratch (device-matrix 1024 1024))
(quotient (- (current-memory-use) before) (* 1024 1024))
(set! scratch #f)
(collect-garbage)
(< (- (current-memory-use) before) (* 1024 1024))
]

@python|{
scratch = device_ndarray.empty((1024, 1024))
del scratch                 # CPython frees it now, through the reference count
}|

CPython frees an array the moment its last reference goes; Racket frees it at
the next collection that finds it unreachable, and the phantom bytes make
that collection come sooner the more GPU memory is held. A form that frees an
array at a known point arrives later @status{L3}.
