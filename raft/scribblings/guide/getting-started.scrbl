#lang scribble/manual
@(require "../utils.rkt")

@(define ev (make-raft-eval))

@title[#:tag "getting-started"]{Getting started}

From a fresh checkout to a Racket program that has loaded RAFT and checked
the GPU stack under it.

@section[#:tag "gs-requirements"]{What you need}

@itemlist[
 @item{@bold{Linux on x86-64.} No macOS or Windows build, and no CPU
       fallback.}
 @item{@bold{An NVIDIA GPU.} Development builds target compute capability
       8.6 and later 8.x devices (RTX 30 and 40 series, A10, A40, L4, L40).}
 @item{@bold{An NVIDIA driver for CUDA 13}, release 580 or newer. Nix
       supplies the CUDA toolkit.}
 @item{@bold{Nix with flakes enabled.} The flake pins Racket 9.3, CUDA 13.2
       and the RAPIDS 26.08 release.}]

@section[#:tag "gs-shell"]{Entering the shell}

@commandline{git clone https://github.com/bkc39/rkt-raft && cd rkt-raft}
@commandline{nix develop}

The first entry builds the native library and installs the @tt{raft}
collection into a Racket user directory of the checkout's own; later entries
take seconds. The shell also provides a @tt{python3} with @tt{pylibraft},
@tt{rmm}, CuPy and NumPy from the same RAPIDS release, the Python this manual
compares against.

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

@python|{
import pylibraft
pylibraft.__version__        # '26.08.00'
}|

Both load the same RAFT build. In Racket the version is a function, as
@racket[version] is.

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

@python|{
import cupy as cp, pylibraft, rmm
print("raft", pylibraft.__version__)                       # raft 26.08.00
print("rmm", rmm.__version__)                               # rmm 26.08.00
print("cuda-runtime", cp.cuda.runtime.runtimeGetVersion())  # cuda-runtime 13020
}|

CuPy reports the runtime it runs on; @racket['cuda-runtime] is the one this
library was compiled with. Python has no single tag; Racket has one because a
native binding built on this one, such as cuML's, must check at load that its
headers match (@racket[raft-abi], @secref["downstream-abi"]).

Last, @racket[device-count] checks that the driver sees a GPU:

@examples[#:eval ev #:label #f
(device-count)
]

@python|{
import cupy as cp
cp.cuda.runtime.getDeviceCount()                         # 1
cp.cuda.runtime.getDeviceProperties(0)["name"]           # b'NVIDIA GeForce RTX 3090 Ti'
}|

If it raises @racket[exn:fail:raft] instead (no driver, too old a driver, or
no device), nothing else in this manual will run. Until
@racket[device-properties] @status{L2} names the GPU, ask the driver:

@commandline{nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv}

@section[#:tag "gs-tests"]{Running the tests}

@commandline{raco test raft}
@commandline{scripts/gpu-suite.sh}

The first runs the Racket tests; the second everything that needs the GPU,
including the parity checks against Python. A test that cannot run prints a
line starting with @tt{SKIP:}; a green run with SKIP lines has not tested
what was skipped.

@section[#:tag "gs-examples"]{How the examples in this manual run}

Every Racket example is evaluated when the manual is built, on the GPU, and a
test pins what each one shows. The Python blocks are not evaluated: they show
the closest equivalent, with its output in a comment, and the parity tests
compare the two sides by machine.

@section[#:tag "gs-license"]{License}

This package is distributed under @bold{Apache-2.0} (see @tt{LICENSE} at the
root of the repository). The repository holds only its own code: the flake
fetches what it builds on and does not redistribute it.

@itemlist[
  @item{RAFT, RMM, cuML and cuVS, from NVIDIA's RAPIDS wheels on PyPI, with
        @tt{rapids-logger}, which RAFT and RMM use, and nvForest, which cuML
        loads: Apache-2.0.}
  @item{CCCL (Thrust, CUB and libcu++), whose headers come inside the RAFT
        wheel: Apache-2.0, libcu++ with LLVM exceptions, with some parts
        under other permissive licences.}
  @item{The CUDA toolkit and libraries (the runtime, cuBLAS, cuSOLVER,
        cuSPARSE and the rest), from nixpkgs: NVIDIA's CUDA Toolkit End User
        License Agreement, which is not an open-source licence. NCCL, which
        cuVS loads, comes from NVIDIA's wheel under a BSD-style licence.}
  @item{The Python twins: @tt{pylibraft}, @tt{rmm} and cuML (Apache-2.0),
        CuPy (MIT) and NumPy (BSD-3-Clause, with parts under other permissive
        licences).}
]

@section[#:tag "gs-acknowledgements"]{Acknowledgements}

This library is a thin layer over the work of NVIDIA's RAPIDS teams: RAFT,
RMM, cuML and cuVS. The Python twins and this manual's Python examples rely
on @tt{pylibraft}, CuPy and NumPy.

@section[#:tag "gs-ai-disclosure"]{AI disclosure}

This package was built with substantial help from AI coding agents. Claude, by
Anthropic, running in Claude Code, wrote most of the code, the tests and this
manual under the maintainer's direction, and most commits in the repository's
history credit Claude as a co-author.

Every change goes through a pull request, reviewed by independent AI reviewer
agents, and the maintainer decides what is merged. The numbers do not rest
on the agents' word: the GPU suite checks them against @tt{pylibraft}, CuPy
and cuML twins built from the same RAPIDS release.
