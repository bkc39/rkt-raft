#lang scribble/manual
@(require "../utils.rkt"
          "lifetime-diagram.rkt")

@(define ev (make-raft-eval))

@title[#:tag "concepts"]{Concepts}

This library provides an array data structure that can run on CUDA devices.
There are three key types of objects:

@itemlist[
 @item{@deftech{buffer}: one RMM allocation in GPU memory, with its
       device, byte size and @deftech{phantom bytes}. It owns the memory, and
       its finalizer frees it.}
 @item{@deftech{array}: a device vector or matrix, a typed and shaped
       view of a buffer (@deftech{dtype}, shape, @deftech{strides}, offset).
       Several arrays can share one buffer.}
 @item{@deftech{resources}: a @tt{raft::handle_t} on one GPU, owning a
       CUDA @deftech{stream} (an ordered queue of GPU work) and the cuBLAS,
       cuSOLVER and cuSPARSE handles. Every array and every operation runs on
       resources, by default the thread's.}]

How do these differ from Racket arrays or vectors?

@itemlist[
 @item{@bold{The memory is on the GPU}, managed by RMM, not in the Racket heap.
       Moving data in or out is a copy.}
 @item{@bold{Work is asynchronous.} Operations queue on the resources' stream
       and return; the program waits when a value comes back to Racket or on
       @racket[resources-sync!].}
 @item{@bold{Dtype and layout are fixed.} The dtype is @racket['float32],
       @racket['float64], @racket['int32] or @racket['int64]; the layout is
       @deftech{row-major}, each row contiguous, or @deftech{column-major}, each
       column contiguous. Nothing converts silently: a wrong layout raises,
       and @racket[contiguous] copies.}
 @item{@bold{Strides count elements.} A 2-by-3 matrix has strides
       @racket['(3 1)] row-major and @racket['(1 2)] column-major.}
 @item{@bold{Views share a buffer.} Slicing or transposing @status{L3} makes a
       new array without a copy; the buffer lives while any array over it
       does.}
 @item{@bold{The collector cannot see device memory.} A buffer's phantom bytes
       make the device memory it holds bring collections.}]

@centered{@lifetime-diagram}

@centered{@italic{An array's memory, from RMM's pool through the Racket
collector and back.}}

You never free an array. The finalizer is the default and is correct on its
own: each buffer is released once, on its own device and stream, from
whatever OS thread runs it. It has no timeline, though: it runs at some
collection after the last use. The @tt{with-} forms give one.
@racket[with-device-resources] releases resources when its body
returns, raises, escapes or yields, and @racket[with-array-views] @status{L1d} holds
arrays for exactly one native call. The finalizer stays the backstop.

@section[#:tag "concepts-using"]{Using Arrays}

A conversion from Racket data infers the dtype, @racket['int64] for exact
integers and @racket['float64] otherwise, unless @racket[#:dtype] names one,
and packs it in @racket[#:layout]. An array prints its dtype, shape, layout,
device and values:

@examples[#:eval ev #:label #f
(list->device-vector '(1.5 -2.25 0.0))
(list->device-vector '(3 1 4) #:dtype 'int32)
(list*->device-matrix '((1 2 3) (4 5 6)))
(define m (list*->device-matrix '((1 2 3) (4 5 6)) #:dtype 'float32 #:layout 'col-major))
m
]

@racket[device-matrix] and @racket[device-vector] allocate without
initialising, for a library to write into:

@examples[#:eval ev #:label #f
(define out (device-matrix 1000 128 #:dtype 'float64))
(list (shape out) (dtype out) (layout out))
(define labels (device-vector 1000 #:dtype 'int32))
(list (shape labels) (dtype labels))
]

What an array answers, and how its values come back:

@examples[#:eval ev #:label #f
(list (shape m) (dtype m) (layout m) (strides m) (numel m))
(list (contiguous? m) (contiguous? m #:layout 'col-major))
(strides (contiguous m))
(device-matrix->list* m)
(device-vector->flvector (list->device-vector '(0.5 1.5)))
]

@secref["ref-array"] documents every operation, and @secref["arrays"]
prepares a dataset with them. @racketmodname[raft/compat] converts vectors, nested
vectors, @racket[f32vector]s, @racket[f64vector]s, byte strings and
@racketmodname[math/array] arrays by the same rules (@secref["moving-data"]).

@section[#:tag "concepts-using-resources"]{Resources}

@racket[device-resources] makes resources with a stream of their own;
@racket[current-device-resources] is the thread's default for a device, which
every operation uses without @racket[#:resources]:

@examples[#:eval ev #:label #f
(define r (device-resources))
r
(resources-device r)
(eq? (current-device-resources) (current-device-resources))
(eq? r (current-device-resources))
]

@racket[with-device-resources] releases resources when its body exits, and
@racket[resources-sync!] waits for the work queued on them:

@examples[#:eval ev #:label #f
(with-device-resources ([scoped (device-resources #:device 0)])
  (resources-sync! scoped)
  (resources-device scoped))
]

@secref["ref-core"] documents every operation, and @secref["resources"]
builds a program around them.
