#lang scribble/manual
@(require "utils.rkt")

@title{RAFT: CUDA primitives for Racket}
@author{bkc}

This library binds @hyperlink["https://github.com/rapidsai/raft"]{NVIDIA
RAFT} and provides a low-level interface for working with arrays on the GPU.
It needs Linux, an NVIDIA GPU and Racket 9.3 (@secref["getting-started"]).

The manual has two parts: the @secref["guide"] works through the library by
example, with the equivalent Python beside the Racket, and the
@secref["reference"] documents every exported name.

The package's @secref["gs-license"], @secref["gs-acknowledgements"] and
@secref["gs-ai-disclosure"] are at the end of @secref["getting-started"].

@local-table-of-contents[]

@include-section["guide.scrbl"]
@include-section["reference.scrbl"]
