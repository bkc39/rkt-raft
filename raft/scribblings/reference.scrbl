#lang scribble/manual
@(require "utils.rkt")

@title[#:tag "reference" #:style 'toc]{Reference}

One section per module. Every example below is evaluated when the manual is
built, and the behaviour it shows is pinned by a test in
@filepath{raft/tests/docs-test.rkt}.

@local-table-of-contents[]

@include-section["reference/raft.scrbl"]
