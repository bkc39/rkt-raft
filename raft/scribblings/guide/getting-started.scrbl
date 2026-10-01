#lang scribble/manual
@(require "../utils.rkt")

@(define ev (make-raft-eval))

@title[#:tag "getting-started"]{Getting started}

This chapter takes you from a fresh checkout to a Racket program that has
loaded RAFT and checked that it matches the GPU stack underneath it.

@section[#:tag "gs-requirements"]{What you need}

@itemlist[
 @item{@bold{Linux on x86-64.} There is no macOS or Windows build, and no CPU
       fallback: every array lives on a GPU.}
 @item{@bold{An NVIDIA GPU.} Development builds compile kernels for compute
       capability 8.6 only (the RTX 30 series and the A10/A40 class); a
       release build will cover RAPIDS' own list, 7.5 to 12.0.}
 @item{@bold{An NVIDIA driver for CUDA 13}, that is, release 580 or newer.
       The CUDA toolkit itself comes from Nix; nothing else needs installing.}
 @item{@bold{Nix with flakes enabled.} The flake pins Racket 9.3, CUDA 13.2,
       and the RAPIDS 26.08 wheels that carry RAFT and RMM.}]

@section[#:tag "gs-shell"]{Entering the shell}

@commandline{git clone https://github.com/bkc39/rkt-raft && cd rkt-raft}
@commandline{nix develop}

The first entry takes a while. The shell compiles the native library,
@tt{libraftrkt}, with @tt{nvcc}, copies it into @filepath{raft/native-libs},
and installs the @tt{raft} collection into a Racket user directory of its own
under @filepath{~/.cache/rkt-raft-devshell}, so two checkouts never share
installed code. It also links your driver's @tt{libcuda.so.1} into
@filepath{.cuda-driver} and removes any @filepath{/usr/local/cuda} directory
from @tt{LD_LIBRARY_PATH}, where an older CUDA would shadow the libraries RAFT
was built against. Later entries reuse all of this and take seconds.

The shell also provides a @tt{python3} with @tt{pylibraft}, @tt{rmm}, CuPy and
NumPy, built from the same RAPIDS release. That is the Python this manual
compares against, and the one the parity tests run.

@section[#:tag "gs-first-program"]{A first program}

Put this in @filepath{hello.rkt} and run it with @exec{racket hello.rkt}:

@codeblock|{
#lang racket/base
(require raft)
(printf "RAFT ~a\n" (raft-version))
}|

The call answers the RAFT release the native library was compiled against:

@examples[#:eval ev #:label #f
(raft-version)
]

@python|{
import pylibraft
pylibraft.__version__        # '26.08.00'
}|

Both sides print the same string, because both load the same RAFT build. In
Racket the version is a function, as @racket[version] is; in Python it is a
module attribute.

@section[#:tag "gs-checking"]{Checking the stack}

A GPU program depends on four things agreeing: the driver, the CUDA runtime,
RAFT and RMM, and CCCL, the CUDA C++ template libraries RAFT's headers build
on. @racket[raft-abi] reports what @tt{libraftrkt} was compiled against:

@examples[#:eval ev #:label #f
(define abi (raft-abi))
(hash-ref abi 'raft)
(hash-ref abi 'rmm)
(hash-ref abi 'cuda-runtime)
]

A short report is a good first line in a bug report:

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

Python has no single ABI tag: each package reports its own version, and a
mismatch between, say, the RMM that pylibraft was built against and the one
that is installed shows up as an import error or a crash. The tag exists on
the Racket side because a second native library, the cuML binding, will
compile against the same headers and has to check at load time that they
match; see @racket[raft-abi].

To see the GPU itself, ask the driver:

@commandline{nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv}

@python|{
import cupy as cp
cp.cuda.runtime.getDeviceCount()                         # 1
cp.cuda.runtime.getDeviceProperties(0)["name"]           # b'NVIDIA GeForce RTX 3090 Ti'
}|

Racket has no device query yet: @racketidfont{device-count} and
@racketidfont{device-properties} arrive with the rest of the core module in a
later leg.

@section[#:tag "gs-tests"]{Running the tests}

@commandline{raco test raft}
@commandline{scripts/gpu-suite.sh}

The first runs the Racket tests; the second runs everything that needs the
GPU: the native library's own tests, a load of @tt{libraftrkt} with every
symbol resolved, the Racket tests and the parity checks against Python. A test
that cannot run where it is (no GPU, or no @tt{pylibraft}) prints a line
starting with @tt{SKIP:} and the reason. A green run with SKIP lines has not
tested what was skipped; the GitHub build, which has no GPU, prints one for
every GPU case.

@section[#:tag "gs-examples"]{How the examples in this manual run}

Every Racket example in this manual is evaluated when the manual is built,
against the real library, and its output is what you see; nothing is pasted
by hand. Once arrays arrive, that means building the manual needs a GPU, so
the manual is built on a GPU host rather than in GitHub's CI. The behaviour
each example shows is also pinned by a test, so an example cannot drift from
the library without a test failing.

The Python blocks are not evaluated. They show the closest equivalent in
@tt{pylibraft}, @tt{rmm}, CuPy or NumPy, with the output in a comment, and
the text after them says where the two sides differ. The parity tests are
where the two sides are compared by machine.
