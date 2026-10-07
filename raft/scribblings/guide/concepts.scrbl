#lang scribble/manual
@(require "../utils.rkt"
          "lifetime-diagram.rkt")

@title[#:tag "concepts"]{Concepts}

What the library provides, how it differs from Racket's own data, and how its
memory comes back. A name marked with a leg, such as @status{L3}, is not there
yet.

@section[#:tag "concepts-structures"]{Resources and arrays}

@tabular[#:sep @hspace[2]
         #:style 'boxed
         #:row-properties '(bottom-border ())
 (list (list @bold{Object} @bold{What it is})
       (list @elem{@deftech{resources} @status{L1a}}
             @elem{RAFT's @tt{raft::handle_t}: a device, a CUDA @deftech{stream}
                   (an ordered queue of GPU work), and the cuBLAS, cuSOLVER and
                   cuSPARSE handles, created on first use})
       (list @elem{@deftech{array} @status{L1b}}
             @elem{a vector or a matrix in device memory: a @deftech{buffer}, one
                   RMM allocation, and a view of it (shape, strides, offset and
                   element type)}))]

Every operation runs on resources, by default the current thread's for the
device. Each array has one element type, its @deftech{dtype}
(@racket['float32], @racket['float64], @racket['int32] or @racket['int64]),
and one layout: @deftech{row-major}, each row contiguous, or
@deftech{column-major}, each column contiguous. cuML mostly runs in
@racket['float32].

@section[#:tag "concepts-differences"]{How they differ from Racket data}

@itemlist[
 @item{@bold{The memory is on the GPU.} An array's elements live in device
       memory, managed by RMM, not in the Racket heap. Moving data between
       Racket and an array is always a copy.}
 @item{@bold{Work is asynchronous.} Operations queue on the resources' stream
       and return at once. The program waits only when a value comes back to
       Racket, by a conversion or printing, or on @racket[resources-sync!]
       @status{L1a}.}
 @item{@bold{Types and layouts are fixed.} Nothing converts silently. RAFT and
       cuML expect a layout (k-means reads row-major, the least-squares solvers
       column-major); a wrong one raises, and @racket[contiguous] @status{L1b}
       copies explicitly.}
 @item{@bold{Strides count elements.} An array's @deftech{strides} are the step
       along each axis, in elements: @racket['(3 1)] for a 2-by-3 row-major
       matrix, @racket['(1 2)] for a column-major one.}
 @item{@bold{Views share a buffer.} Slicing or transposing @status{L3} makes a
       new array over the same buffer without a copy; the buffer lives while
       any array over it does.}
 @item{@bold{The collector cannot see device memory.} Each buffer reports its
       size as @deftech{phantom bytes}, so device memory held brings
       collections as host memory does.}]

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
