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
headers match (@racket[raft-abi]).

To see the GPU and the driver, ask the driver:

@commandline{nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv}

Racket's @racket[device-count] and @racket[device-properties] @status{L2}
arrive with the rest of the core module.

@section[#:tag "gs-examples"]{How the examples in this manual run}

Every Racket example is evaluated when the manual is built, on the GPU, and a
test pins what each one shows.

@section[#:tag "gs-license"]{License}

This package is distributed under @bold{Apache-2.0} (see @tt{LICENSE} at the
root of the repository). The repository holds only its own code and does not
redistribute what it builds on.

@itemlist[
  @item{RAFT and RMM, from NVIDIA's RAPIDS wheels on PyPI, and
        @tt{rapids-logger}, which they use: Apache-2.0.}
  @item{CCCL (Thrust, CUB and libcu++), whose headers come inside the RAFT
        wheel: Apache-2.0, libcu++ with LLVM exceptions, with some parts
        under other permissive licences.}
  @item{The CUDA toolkit and libraries (the runtime, cuBLAS, cuSOLVER,
        cuSPARSE and the rest): NVIDIA's CUDA Toolkit End User
        License Agreement, which is not an open-source licence.}
]

@section[#:tag "gs-acknowledgements"]{Acknowledgements}

This library is a thin layer over the work of NVIDIA's RAPIDS teams: RAFT,
RMM, cuML and cuVS. Its tests check results against @tt{pylibraft} and
CuPy.

@section[#:tag "gs-ai-disclosure"]{AI disclosure}

This package was built with substantial help from AI coding agents. Claude, by
Anthropic, running in Claude Code, wrote most of the code, the tests and this
manual under the maintainer's direction, and most commits in the repository's
history credit Claude as a co-author.

Every change goes through a pull request, reviewed by independent AI reviewer
agents, and the maintainer decides what is merged. The numbers do not rest
on the agents' word: automated tests check them against @tt{pylibraft} and
CuPy built from the same RAPIDS release.
