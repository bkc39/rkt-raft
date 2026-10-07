#lang scribble/manual
@(require "../utils.rkt")

@(define ev (make-raft-eval))

@title[#:tag "concepts"]{Concepts}

This library runs work on CUDA devices through @deftech{resources}: a
@tt{raft::handle_t} on one GPU, owning a CUDA @deftech{stream} (an ordered
queue of GPU work) and the cuBLAS, cuSOLVER and cuSPARSE handles. Every
operation runs on resources, by default the thread's.

How do they differ from Racket values?

@itemlist[
 @item{@bold{Work is asynchronous.} Operations queue on the stream and return;
       @racket[resources-sync!] waits for them.}
 @item{@bold{The collector cannot see what they hold.} A stream and library
       handles are GPU and driver state. The finalizer releases resources at
       some collection after the last use; @racket[with-device-resources]
       releases them when its body returns, raises, escapes or yields.}]

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
