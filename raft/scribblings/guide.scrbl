#lang scribble/manual
@(require "utils.rkt")

@title[#:tag "guide" #:style 'toc]{Guide}

Each chapter is one program, with the same steps in Python (@tt{pylibraft},
@tt{rmm}, CuPy or NumPy) after the key Racket blocks. Names link to the
@secref["reference"].

@local-table-of-contents[]

@include-section["guide/getting-started.scrbl"]
@include-section["guide/concepts.scrbl"]
@include-section["guide/resources.scrbl"]
@include-section["guide/arrays.scrbl"]
@include-section["guide/moving-data.scrbl"]
@include-section["guide/downstream.scrbl"]
