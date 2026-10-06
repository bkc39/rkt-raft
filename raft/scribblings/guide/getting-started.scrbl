#lang scribble/manual
@(require "../utils.rkt")

@(define ev (make-raft-eval))

@title[#:tag "getting-started"]{Getting started}

From installing the package to a Racket program that has loaded RAFT and
checked the GPU stack under it.

@section[#:tag "gs-requirements"]{What you need}

@itemlist[
 @item{@bold{Linux on x86-64.} No macOS or Windows build, and no CPU
       fallback.}
 @item{@bold{An NVIDIA GPU of compute capability 8.6 or a later 8.x}: RTX 30
       and 40 series, A10, A40, L4, L40. The native library is built for 8.6
       only; RAPIDS itself supports 7.5 and newer.}
 @item{@bold{An NVIDIA driver for CUDA 13}, release 580 or newer.}
 @item{@bold{Racket 9.3} or later.}]

@section[#:tag "gs-installing"]{Installing}

@commandline{raco pkg install raft}

@section[#:tag "gs-first-program"]{A first program}

Put this in @filepath{hello.rkt} and run it with @exec{racket hello.rkt}:

@codeblock|{
#lang racket/base
(require raft)
(printf "RAFT ~a\n" (raft-version))
}|

@examples[#:eval ev #:label #f
(raft-version)
]

The version is a function, as @racket[version] is.

@section[#:tag "gs-checking"]{Checking the stack}

@racket[raft-abi] reports what the library was compiled against: RAFT, RMM,
CCCL and the CUDA runtime. A short report is a good first line in a bug
report:

@examples[#:eval ev #:label #f
(match-define (raft-abi #:raft raft #:rmm rmm #:cccl cccl #:cuda-runtime cuda-runtime)
  (raft-abi))
(printf "raft ~a\nrmm ~a\ncccl ~a\ncuda-runtime ~a\n" raft rmm cccl cuda-runtime)
]

The pattern names only the fields it needs.

@racket['cuda-runtime] is the CUDA runtime the library was compiled with. A
native binding built on this one, such as cuML's, checks at load that its
headers match (@racket[raft-abi]).

To see the GPU and the driver, ask the driver:

@commandline{nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv}

Racket's @racket[device-count] and @racket[device-properties] @status{L2}
arrive with the rest of the core module.

@section[#:tag "gs-examples"]{How the examples in this manual run}

Every Racket example is evaluated when the manual is built, on the GPU, and a
test pins what each one shows.
