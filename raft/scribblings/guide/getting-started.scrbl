#lang scribble/manual
@(require "../utils.rkt")

@(define ev (make-raft-eval "guide-getting-started"))

@title[#:tag "getting-started"]{Getting started}

From installing the package to a Racket program that has loaded RAFT and
checked the GPU stack under it.

@section[#:tag "gs-requirements"]{What you need}

@itemlist[
 @item{@bold{Linux on x86-64.} No macOS or Windows build, and no CPU
       fallback.}
 @item{@bold{An NVIDIA GPU of compute capability 7.5 or newer}, the
       architectures RAPIDS supports.}
 @item{@bold{An NVIDIA driver for CUDA 13}, release 580 or newer.}
 @item{@bold{glibc 2.28} or later.}
 @item{@bold{Racket 9.3} or later.}]

@section[#:tag "gs-installing"]{Installing}

@commandline{raco pkg install raft}

This also installs @tt{raft-x86_64-linux}, the package that holds the native
library, @tt{libraftrkt}, and the RAPIDS libraries it loads.

The install also fetches cuBLAS from CUDA 13, NVIDIA's @tt{nvidia-cublas}
wheel from PyPI (a 405 MB download, 560 MB installed, about 1 GB free needed
while it unpacks), unless @envvar{RAFT_CUDA_LIB_PATH} names a directory holding
@tt{libcublas.so.13} and @tt{libcublasLt.so.13} or the system loader finds
them. If the fetch failed, rerun @exec{raco setup --pkgs raft}, which fetches
into the right place for the install's scope, or run
@exec{racket -l- raft/fetch-cuda} for a copy of your own.

cuBLAS is under NVIDIA's licence; raft does not redistribute it.

If @racket[(require raft)] then fails, the message says what is wrong with the
native library and where it looked.

An executable made with @exec{raco exe} does not find @tt{raft-x86_64-linux};
run it with @envvar{RAFT_NATIVE_LIB_PATH} set to a directory whose
@filepath{lib/} holds @tt{libraftrkt} and the libraries beside it.

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

Last, @racket[device-count] checks that the driver sees a GPU:

@examples[#:eval ev #:label #f
(device-count)
]

If it raises @racket[exn:fail:raft] instead (no driver, too old a driver, or
no device; the message says which), nothing else in this manual will run. To
name the GPU, ask the driver:

@commandline{nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv}
