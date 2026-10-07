#lang scribble/manual
@(require "../utils.rkt"
          "lifetime-diagram.rkt")

@title[#:tag "concepts"]{Concepts}

This library provides an array data structure that can run on CUDA devices.
There are two key types of objects:

@itemlist[
 @item{@deftech{resources} @status{L1a}: a @tt{raft::handle_t} on one GPU,
       owning a CUDA @deftech{stream} (an ordered queue of GPU work) and the
       cuBLAS, cuSOLVER and cuSPARSE handles. Every operation runs on one, by
       default the thread's.}
 @item{@deftech{array} @status{L1b}: a device vector or matrix of one
       @deftech{dtype} (@racket['float32], @racket['float64], @racket['int32]
       or @racket['int64]) and one layout, a view over a @deftech{buffer} in
       GPU memory.}]

How do these differ from Racket arrays or vectors?

@itemlist[
 @item{@bold{The memory is on the GPU}, managed by RMM, not in the Racket heap.
       Moving data in or out is a copy.}
 @item{@bold{Work is asynchronous.} Operations queue on the resources' stream
       and return; the program waits when a value comes back to Racket or on
       @racket[resources-sync!] @status{L1a}.}
 @item{@bold{Dtype and layout are fixed.} An array is @deftech{row-major}, each
       row contiguous, or @deftech{column-major}, each column contiguous.
       Nothing converts silently: a wrong layout raises, and
       @racket[contiguous] @status{L1b} copies.}
 @item{@bold{Strides count elements.} The @deftech{strides} of a 2-by-3 matrix
       are @racket['(3 1)] row-major and @racket['(1 2)] column-major.}
 @item{@bold{Views share a buffer.} Slicing or transposing @status{L3} makes a
       new array without a copy; the buffer lives while any view does.}
 @item{@bold{The collector cannot see device memory.} Each buffer reports its
       size as @deftech{phantom bytes}, so device memory held brings
       collections.}]

@section[#:tag "concepts-lifetime"]{How memory comes back}

@centered{@lifetime-diagram}

@centered{@italic{An array's memory, from RMM's pool through the Racket
collector and back.}}

You never free an array. The finalizer is the default and is correct on its
own: each buffer is released once, on its own device and stream, from
whatever OS thread runs it. It has no timeline, though: it runs at some
collection after the last use. The @tt{with-} forms give one.
@racket[with-device-resources] @status{L1a} releases resources when its body
returns, raises, escapes or yields, and @racket[with-array-views]
@status{L1d} holds arrays for exactly one native call. The finalizer stays the
backstop.
