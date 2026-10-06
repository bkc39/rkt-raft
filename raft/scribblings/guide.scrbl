#lang scribble/manual
@(require "utils.rkt")

@title[#:tag "guide" #:style 'toc]{Guide}

The guide is a tutorial. Each chapter tells one story with client code that
runs, and after the important Racket blocks it shows the same steps in Python
with @tt{pylibraft}, @tt{rmm}, CuPy or NumPy, then says where the two sides
differ. For the definition of each name, follow its link into the
@secref["reference"].

@local-table-of-contents[]

@include-section["guide/getting-started.scrbl"]
@include-section["guide/concepts.scrbl"]
@include-section["guide/resources.scrbl"]
@include-section["guide/arrays.scrbl"]
@include-section["guide/moving-data.scrbl"]
@include-section["guide/downstream.scrbl"]
