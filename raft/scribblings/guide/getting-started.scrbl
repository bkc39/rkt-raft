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
(define abi (raft-abi))
(hash-ref abi 'raft)
(hash-ref abi 'rmm)
(hash-ref abi 'cuda-runtime)
]

@examples[#:eval ev #:label #f
(for ([part (in-list '(raft rmm cccl cuda-runtime))])
  (printf "~a ~a\n" (~a part #:min-width 13) (hash-ref abi part)))
]

@racket['cuda-runtime] is the CUDA runtime the library was compiled with. A
native binding built on this one, such as cuML's, checks at load that its
headers match (@racket[raft-abi], @secref["downstream-abi"]).

Last, @racket[device-count] checks that the driver sees a GPU:

@examples[#:eval ev #:label #f
(device-count)
]

If it raises @racket[exn:fail:raft] instead (no driver, too old a driver, or
no device), nothing else in this manual will run. Until
@racket[device-properties] @status{L2} names the GPU, ask the driver:

@commandline{nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv}

@section[#:tag "gs-examples"]{How the examples in this manual run}

Every Racket example is evaluated when the manual is built, on the GPU, and a
test pins what each one shows.
