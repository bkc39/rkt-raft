#lang scribble/manual
@(require "../utils.rkt")

@(define ev (make-raft-eval))

@title[#:tag "ref-raft"]{The @racketmodname[raft] module}

@defmodule[raft]

@racket[(require raft)] provides the whole library.

@defproc[(raft-version) string?]{

Returns the RAFT release the library was compiled against, as year, month and
patch: @racket["26.08.00"] is August 2026.

@examples[#:eval ev
(raft-version)
]

Split it to compare releases numerically:

@examples[#:eval ev #:label #f
(match-define (list year month _)
  (map string->number (string-split (raft-version) ".")))
(list year month)
(>= (+ (* 100 year) month) 2608)
]

A program that depends on one release can refuse to start on another:

@examples[#:eval ev #:label #f
(define (require-raft-release! wanted)
  (unless (string=? (raft-version) wanted)
    (error 'my-pipeline "built for RAFT ~a, but this is RAFT ~a"
           wanted (raft-version))))
(require-raft-release! "26.08.00")
(eval:error (require-raft-release! "26.10.00"))
]}

@defproc[(raft-abi) raft-abi?]{

Returns the library's ABI tag: what a second native library, such as a cuML
binding, must share with it to exchange RAFT handles and arrays. It must be
compiled against identical RAFT, RMM and CCCL headers, and compares its tag
with this one when it loads.

@examples[#:eval ev
(raft-abi)
]

In a @racket[match] pattern, @racket[raft-abi] takes the tag's fields by
keyword. Every keyword is optional and fields not named are ignored; an
unknown keyword is a syntax error.

@racketgrammar*[#:literals (raft-abi)
                [abi-pattern (raft-abi field-pattern ...)]
                [field-pattern (code:line #:version pat)
                               (code:line #:raft pat)
                               (code:line #:rmm pat)
                               (code:line #:cccl pat)
                               (code:line #:cuda-runtime pat)
                               (code:line #:resource-types pat)
                               (code:line #:handle-size pat)]]

@examples[#:eval ev #:label #f
(match-define (raft-abi #:raft raft #:cuda-runtime cuda-runtime) (raft-abi))
(list raft cuda-runtime)
]

A program tested on one release can say so on another:

@examples[#:eval ev #:label #f
(define (support-status abi)
  (match abi
    [(raft-abi #:raft "26.08.00") 'supported]
    [(raft-abi #:raft other) (list 'untested other)]))
(support-status (raft-abi))
(support-status (struct-copy raft-abi (raft-abi) [raft "26.10.00"]))
]

A tag from RAFT 26.10, or from headers whose handle has another layout,
differs from this one in the fields that must agree:

@examples[#:eval ev #:label #f
(define (abi-mismatches built-against)
  (for/list ([field (in-list (list raft-abi-version raft-abi-raft raft-abi-rmm
                                   raft-abi-cccl raft-abi-handle-size))]
             [name (in-list '(version raft rmm cccl handle-size))]
             #:unless (equal? (field built-against) (field (raft-abi))))
    name))
(abi-mismatches (raft-abi))
(abi-mismatches (struct-copy raft-abi (raft-abi) [raft "26.10.00"]))
(abi-mismatches (struct-copy raft-abi (raft-abi) [handle-size 40]))
]

A one-line support report:

@examples[#:eval ev #:label #f
(match-let ([(raft-abi #:raft raft #:rmm rmm #:cccl cccl) (raft-abi)])
  (format "raft=~a rmm=~a cccl=~a" raft rmm cccl))
]}

@deftogether[(@defproc[(raft-abi? [v any/c]) boolean?]
              @defproc[(raft-abi-version [abi raft-abi?]) exact-nonnegative-integer?]
              @defproc[(raft-abi-raft [abi raft-abi?]) string?]
              @defproc[(raft-abi-rmm [abi raft-abi?]) string?]
              @defproc[(raft-abi-cccl [abi raft-abi?]) string?]
              @defproc[(raft-abi-cuda-runtime [abi raft-abi?]) string?]
              @defproc[(raft-abi-resource-types [abi raft-abi?]) exact-nonnegative-integer?]
              @defproc[(raft-abi-handle-size [abi raft-abi?]) exact-positive-integer?])]{

The predicate and the fields of an ABI tag, a transparent structure:
@racket[equal?] compares tags field by field, and
@racket[(struct-copy raft-abi abi [field value] ...)] makes a changed copy.

@tabular[#:sep @hspace[2]
         #:style 'boxed
         #:row-properties '(bottom-border ())
 (list (list @bold{Field} @bold{Value})
       (list @racket[version]
             @elem{the version of the tag itself; it changes whenever the native
                   interface does})
       (list @racket[raft] @elem{the RAFT release, as @racket[raft-version] returns it})
       (list @racket[rmm] "the RMM release, in the same form")
       (list @racket[cccl] @elem{the CCCL release, for example @racket["3.4.3"]})
       (list @racket[cuda-runtime]
             "the CUDA runtime the native library was compiled with, major.minor")
       (list @racket[resource-types]
             "the number of resource kinds a RAFT handle can hold")
       (list @racket[handle-size] @elem{@tt{sizeof(raft::handle_t)}, in bytes}))]

@examples[#:eval ev
(define abi (raft-abi))
(raft-abi? abi)
(raft-abi-version abi)
(raft-abi-cuda-runtime abi)
(equal? abi (raft-abi))
(equal? abi (struct-copy raft-abi abi [rmm "26.10.00"]))
]}
