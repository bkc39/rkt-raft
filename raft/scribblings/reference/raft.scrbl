#lang scribble/manual
@(require "../utils.rkt")

@title[#:tag "ref-raft"]{The @racketmodname[raft] module}

@defmodule[raft]

@racket[(require raft)] provides the library by re-exporting its modules,
which the sections that follow document one by one:
@racketmodname[raft/core], with resources, devices, errors, and the version
and ABI tag, and @racketmodname[raft/array], with device arrays and their
conversions from lists and flvectors. The one module it leaves out is
@racketmodname[raft/compat], the conversions from every other form of Racket
data, which requires @tt{math-lib}; a program that wants them requires it as
well. A program that needs only part of the library can require that module
alone.
