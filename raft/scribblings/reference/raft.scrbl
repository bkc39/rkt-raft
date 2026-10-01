#lang scribble/manual
@(require "../utils.rkt")

@title[#:tag "ref-raft"]{The @racketmodname[raft] module}

@defmodule[raft]

@racket[(require raft)] provides the whole library by re-exporting each of its
modules, which the sections that follow document one by one. Today that is
@racketmodname[raft/core]: resources, devices, errors, and the version and ABI
tag. Device arrays @status{L1b} and conversions from Racket data
@status{L1c} join it as their modules land. A program that needs only part of
the library can require that module alone.
