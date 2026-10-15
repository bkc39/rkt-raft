#lang scribble/manual
@(require "../utils.rkt")

@title[#:tag "ref-raft"]{The @racketmodname[raft] module}

@defmodule[raft]

@racket[(require raft)] provides the library by re-exporting its modules,
which the sections that follow document one by one:
@racketmodname[raft/core], with resources, devices, errors, and the version
and ABI tag, and @racketmodname[raft/array], with device arrays and their
conversions from lists and flvectors. It leaves out two modules:
@racketmodname[raft/compat], the conversions from every other form of Racket
data, which requires @tt{math-lib}, and @racketmodname[raft/unsafe], the
interface for native bindings. A program that wants either requires it as
well. A program that needs only part of the library can require that module
alone.
