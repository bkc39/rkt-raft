#lang scribble/manual
@(require "utils.rkt")

@title{RAFT: CUDA primitives for Racket}
@author{bkc}

This library binds @hyperlink["https://github.com/rapidsai/raft"]{NVIDIA
RAFT} and provides a low-level interface for working with arrays on the GPU.
It needs Linux, an NVIDIA GPU and Racket 9.3 (@secref["getting-started"]).

The manual has two parts: the @secref["guide"] works through the library by
example, and the @secref["reference"] documents every exported name.

@bold{License.} This package is distributed under @bold{Apache-2.0}.

@bold{Acknowledgements.} RAFT and the libraries it builds on are the work of
NVIDIA's RAPIDS teams.

@bold{AI Disclosure.} This package and its documentation were created with the
use of AI tools.

@local-table-of-contents[]

@include-section["guide.scrbl"]
@include-section["reference.scrbl"]
