#lang scribble/manual
@(require "utils.rkt")

@title{RAFT: CUDA primitives for Racket}
@author{bkc}

This library binds @hyperlink["https://github.com/rapidsai/raft"]{NVIDIA RAFT},
the CUDA C++ library of device arrays and data-science primitives that
@hyperlink["https://github.com/rapidsai/cuml"]{cuML} is built on. It is meant
to be two things: a Racket library for moving data to a GPU and computing on
it there, and the base a later Racket binding to cuML stands on, sharing its
device handle and its arrays.

RAFT is C++ templates. The bindings reach it through a small native library
of our own, @tt{libraftrkt}, compiled with @tt{nvcc} against one pinned RAPIDS
release (26.08) and loaded through the Racket FFI. It needs Linux, an NVIDIA
GPU and the Nix toolchain described in @secref["getting-started"]; there is no
CPU fallback.

The library is young. Today it provides the native library and its build,
device resources and the devices they run on, the exception type, the
version and ABI tag, and device matrices and vectors with their conversions
from lists and flvectors; more conversions come next, and
@secref["concepts"] explains the design. A name that does not exist yet is
marked with the leg that adds it, such as @status{L1c}, and is described in
prose, not called.

The manual has two parts: the @secref["guide"] works through the library by
example, with the equivalent Python beside the Racket, and the
@secref["reference"] documents every exported name.

@local-table-of-contents[]

@include-section["guide.scrbl"]
@include-section["reference.scrbl"]
