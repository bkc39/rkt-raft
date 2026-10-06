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

Data reaches a GPU program in whatever form the rest of the program keeps it:
rows read from a text file, a matrix computed with @racketmodname[math/matrix],
numbers a C library wrote into an @racket[f64vector]. This chapter follows one
program that gathers its inputs from each of those places and puts them on the
GPU in the form cuML takes: it reads a table, chooses the element type cuML
works in, sends a covariance matrix it computed on the host, adds per-sample
weights from foreign code, lays the features out for a least-squares solver,
and brings arrays back in the forms the rest of the program uses. The last
section measures what each form costs.

The cuML calls themselves belong to a separate package built on this library,
through the interface @secref["downstream"] describes; this chapter covers the
hand-off, the arrays those calls take.

Every conversion here comes from @racketmodname[raft/compat], which the
program requires beside @racketmodname[raft], with the Racket libraries it
reads and writes its data with:

@racketblock[
(require raft raft/compat
         math/matrix math/array ffi/vector
         racket/file racket/list racket/port racket/string)
]

@section[#:tag "moving-data-rows"]{Rows from a text file}

The measurements are six iris flowers in comma-separated text, four numbers
and a species name per line. The program reads the lines, splits them, and
keeps the numbers as a list of rows. Here a string port stands for the file:

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

@racket[list*->device-array] reads the rank from the nesting: a list of lists
is a matrix, a list of numbers a vector. Every row must have as many numbers
as the first, or the conversion names the row that does not.

The species become the labels a classifier is scored against, one
@racket['int32] per flower, numbered in order of appearance. The labels are
built as a vector, so they go up with @racket[vector->device-vector]:

@examples[#:eval ev #:label #f
(define species (map last table))
(define names (remove-duplicates species))
(define labels
  (vector->device-vector (for/vector ([s (in-list species)])
                           (index-of names s))
                         #:dtype 'int32))
labels
]

@python|{
import io

import numpy as np
from pylibraft.common import device_ndarray

csv = (
    "sepal_length,sepal_width,petal_length,petal_width,species\n"
    "5.1,3.5,1.4,0.2,setosa\n"
    "4.9,3.0,1.4,0.2,setosa\n"
    "7.0,3.2,4.7,1.4,versicolor\n"
    "6.4,3.2,4.5,1.5,versicolor\n"
    "6.3,3.3,6.0,2.5,virginica\n"
    "5.8,2.7,5.1,1.9,virginica\n"
)
table = np.loadtxt(io.StringIO(csv), delimiter=",", skiprows=1,
                   usecols=range(4), dtype=np.float32)
X = device_ndarray(table)
species = np.loadtxt(io.StringIO(csv), delimiter=",", skiprows=1,
                     usecols=4, dtype=str)
names, codes = np.unique(species, return_inverse=True)
labels = device_ndarray(codes.astype(np.int32))
labels.copy_to_host()      # array([0, 0, 1, 1, 2, 2], dtype=int32)
}|

NumPy parses the text in C and builds the array in one step; the Racket
program parses with Racket's string functions and hands the rows to the
conversion. @tt{np.unique} numbers the names in sorted order, which here is
also their order of appearance.

@section[#:tag "moving-data-dtype"]{Choosing float32 for cuML}

Left to itself, a conversion infers the element type as NumPy does: decimal
numbers give @racket['float64], and exact integers @racket['int64]:

@examples[#:eval ev #:label #f
(dtype (list*->device-array rows))
(dtype (list*->device-array '((1 2) (3 4))))
]

cuML's estimators take @racket['float32] or @racket['float64]. A consumer
GPU such as the RTX 3090 Ti runs @racket['float64] arithmetic at a small
fraction of its @racket['float32] rate, and a @racket['float32] matrix takes
half the memory, so the program asked for @racket['float32] with
@racket[#:dtype]. A
@racket['float32] cannot hold most decimals exactly, so what comes back is the
nearest @racket['float32] value, widened to a flonum:

@examples[#:eval ev #:label #f
(first (device-array->list* X))
]

@python|{
np.asarray([[5.1, 3.5], [4.9, 3.0]]).dtype    # dtype('float64')
np.asarray([[1, 2], [3, 4]]).dtype            # dtype('int64')
X.copy_to_host()[0].tolist()
# [5.099999904632568, 3.5, 1.399999976158142, 0.20000000298023224]
}|

The inference and the rounding are NumPy's. NumPy's @tt{loadtxt} took the
type up front, as @racket[#:dtype] does here.

@section[#:tag "moving-data-matrix"]{A matrix computed on the host}

The program also computes the features' covariance on the host with
@racketmodname[math/matrix]: it is small, four by four, and the program wants
it as a matrix to inspect as well as on the GPU, where a whitening step can
use it.

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

Brought back, the matrix is a @racketmodname[math/array] flonum array, so the
host algebra applies to it directly. Its entries differ from the
@racket['float64] originals only by the @racket['float32] rounding:

@examples[#:eval ev #:label #f
(define C* (device-matrix->matrix C))
(array-shape C*)
(< (array-all-max (array-abs (array- C* covariance))) 1e-6)
]

@python|{
cov = np.cov(np.loadtxt(io.StringIO(csv), delimiter=",", skiprows=1,
                        usecols=range(4)), rowvar=False)
C = device_ndarray(cov.astype(np.float32))
np.abs(C.copy_to_host() - cov).max() < 1e-6     # True
}|

NumPy has @tt{np.cov}; @racketmodname[math/matrix] has the operations it is
built from. A @racketmodname[math/array] array also carries a cost NumPy's do
not: it is Typed Racket, and untyped code reads each element through a
contract. The covariance, a result of @racket[matrix*], is neither a flonum
array nor a mutable array, so the conversion read its sixteen elements that
way, about a microsecond each. On the way back the conversion builds a flonum
array, whose storage a later conversion hands over in one step.

@section[#:tag "moving-data-ffi"]{Weights from foreign code}

Each flower gets a weight from a C routine that the program calls through the
FFI. The program allocates the @racket[f64vector] and passes its storage,
@racket[(f64vector->cpointer weights)], to the routine, which fills it; a loop
stands for that call here. cuML wants the weights in the type of the data:

@examples[#:eval ev #:label #f
(define weights (make-f64vector n))
(for ([i (in-range n)])
  (f64vector-set! weights i (if (< i 2) 2.0 1.0)))
(define w (f64vector->device-vector weights #:dtype 'float32))
w
]

@python|{
import ctypes

weights = np.empty(6)
fill_weights(weights.ctypes.data_as(ctypes.POINTER(ctypes.c_double)), 6)
w = device_ndarray(weights.astype(np.float32))
}|

Here @tt{fill_weights} is the C routine, loaded with @tt{ctypes}. A NumPy
array is its own foreign buffer, so @tt{ctypes} hands its storage to C
directly; in Racket the @racket[f64vector] plays that part. Sent as
@racket['float64], an @racket[f64vector] is copied as it is; narrowing it to
@racket['float32] converts each element, and a value too large for
@racket['float32] raises instead of becoming an infinity.

@section[#:tag "moving-data-layout"]{A layout for the solver}

The same features also go to a least-squares model, and every solver behind
cuML's @tt{LinearRegression} reads column-major input. Since the features are still
on the host, the program packs them column by column on the way up, and no
transpose runs on the GPU; the matrix from @racketmodname[math/matrix] packs
the same way:

@examples[#:eval ev #:label #f
(define F (list*->device-array rows #:dtype 'float32 #:layout 'col-major))
(list (contiguous? F #:layout 'col-major) (strides F))
(define F* (matrix->device-matrix M #:dtype 'float32 #:layout 'col-major))
(equal? (device-array->list* F) (device-array->list* F*))
]

@python|{
F = device_ndarray(np.asfortranarray(table))
F.f_contiguous, F.strides        # (True, (4, 24))
}|

@tt{np.asfortranarray} makes a column-major copy on the host before the
transfer, as @racket[#:layout] does. Strides count elements here and bytes in
NumPy. When the data is already on the device, @racket[contiguous] changes
the layout there instead (@secref["arrays-layout"]).

@section[#:tag "moving-data-back"]{Results back in Racket}

Results come back in whatever form the next step of the program wants. The
features as a @racketmodname[math/array] array, to compute each column's mean
on the host:

@examples[#:eval ev #:label #f
(define X* (device-array->array X))
(array-scale (array-axis-sum X* 0) (/ 1.0 n))
]

The labels as a vector, to count the flowers of each species:

@examples[#:eval ev #:label #f
(define counts (make-vector (length names) 0))
(for ([label (in-vector (device-vector->vector labels))])
  (vector-set! counts label (add1 (vector-ref counts label))))
counts
]

The weights as raw bytes, saved for a later run, which reads them straight
back:

@examples[#:eval ev #:label #f
(define saved (make-temporary-file))
(display-to-file (device-vector->bytes w) saved #:exists 'truncate)
(file-size saved)
(device-vector->list (bytes->device-vector (file->bytes saved) #:dtype 'float32))
]

@examples[#:eval ev #:hidden
(delete-file saved)
]

@python|{
X.copy_to_host().mean(axis=0)
# array([5.9166665, 3.1499999, 3.8500001, 1.2833334], dtype=float32)
np.bincount(labels.copy_to_host())              # array([2, 2, 2])
path = "weights.bin"
w.copy_to_host().tofile(path)
np.fromfile(path, dtype=np.float32)             # array([2., 2., 1., 1., 1., 1.], dtype=float32)
}|

@tt{copy_to_host} always gives a NumPy array, which Python code converts
further if it needs to, and NumPy keeps the means in @tt{float32}, where
@racketmodname[math/array] computes them in flonums. Here each conversion names the Racket form it makes,
so the program asks for the one it needs. Every one of them waits for the
work queued on the array's stream before it copies.

@section[#:tag "moving-data-speed"]{What each form costs}

A conversion either copies a block of storage as it is or packs the elements
one at a time. The table measures both directions for every form, at a
million elements, as the median of five runs after a warm-up; it is
@tt{bench/conversions.rkt} in the repository, run on the lab host (RTX 3090
Ti, Racket 9.3 CS) on 2026-10-05. Times are milliseconds.

@(define speed-rows
   '(("list" "34.9" "34.0" "54.2" "52.3")
     ("vector" "33.9" "32.9" "35.8" "31.8")
     ("flvector" "1.0" "38.2" "4.1" "63.4")
     ("f64vector" "4.3" "47.4" "13.0" "54.9")
     ("f32vector" "46.6" "2.0" "54.2" "3.6")
     ("bytes" "0.8" "0.4" "3.9" "2.0")
     ("math FlArray" "1.1" "32.1" "4.3" "59.1")
     ("math mutable array" "34.0" "32.6" "4.1" "59.0")
     ("math array from build-array" "604.4" "594.2" "4.2" "58.2")
     ("nested list, 1000×1000" "49.8" "51.0" "52.9" "55.4")
     ("nested vector, 1000×1000" "36.0" "38.7" "44.2" "42.6")
     ("math FlArray, 1000×1000" "1.2" "31.6" "4.1" "59.9")
     ("math mutable array, 1000×1000" "35.2" "36.8" "4.1" "61.7")))

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

What it says, for a program that moves a lot of data:

@itemlist[
 @item{A form whose storage matches the element type crosses in one copy:
       an @racket[flvector] or a flonum array as @racket['float64], and bytes
       as anything, in 1 to 4 milliseconds per million elements each way. An
       @racket[f32vector] as @racket['float32] and an @racket[f64vector] as
       @racket['float64] take one more copy on the host.}
 @item{Lists and vectors cost about 35 nanoseconds an element going up and
       35 to 55 coming back. Up to some hundred thousand elements that is
       negligible next to GPU work; beyond that, build an @racket[flvector]
       or an @racket[f32vector] in the first place.}
 @item{Changing the element type on the way costs a pass over the elements,
       30 to 60 milliseconds per million, so keep the data in the type it
       will be used in: for cuML, an @racket[f32vector], or bytes from a file
       of @tt{float32}.}
 @item{A @racketmodname[math/array] array that is neither a flonum array nor
       a mutable array, such as one made by @racket[build-array] or returned
       by @racketmodname[math/matrix], is read element by element through
       Typed Racket's contract, about 0.6 microseconds each. Convert it with
       @racket[array->flarray] inside Typed Racket code, where no contract
       applies, or keep data that will go to the GPU in flonum arrays.}]

@python|{
xs = [i / 2 for i in range(1_000_000)]
device_ndarray(np.asarray(xs))                     # 35 ms, nearly all np.asarray
device_ndarray(np.asarray(xs, dtype=np.float32))   # 28 ms
arr = np.asarray(xs)
d = device_ndarray(arr)                            # 2.3 ms
d.copy_to_host().tolist()                          # 37 ms back to a list
}|

The same split exists in Python, measured the same way on the same host:
building a NumPy array from a list visits every element, and a NumPy array
already in the right type crosses in one copy. A list costs about the same on
either side.
