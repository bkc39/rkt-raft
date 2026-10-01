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

This is the first leg of the first milestone. What exists today is the
scaffold: the native library, its build, the version and ABI tag, and the
design the next legs implement, which @secref["concepts"] explains. Names that
arrive in a later leg are marked with the leg (@status{L1a}, @status{L1b},
@status{L1c}) and are described in prose, not called.

The manual has two parts: the @secref["guide"] works through the library by
example, with the equivalent Python beside the Racket, and the
@secref["reference"] documents every exported name.

@local-table-of-contents[]

@include-section["guide.scrbl"]
@include-section["reference.scrbl"]
