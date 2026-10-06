#lang scribble/manual
@(require "../utils.rkt")

@(define ev (make-raft-eval))

@title[#:tag "ref-raft"]{The @racketmodname[raft] module}

@defmodule[raft]

@racket[(require raft)] provides the whole library.

@defproc[(raft-version) string?]{

Returns the RAFT release the library was compiled against, as
@tt{pylibraft.__version__} spells it: @racket["26.08.00"] is August 2026.

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

@defproc[(raft-abi) hash?]{

Returns the library's ABI tag, an immutable hash of what a second native
library, such as a cuML binding, must share with it to exchange RAFT handles
and arrays: it must be compiled against identical RAFT, RMM and CCCL headers,
and compares its tag with this one when it loads.

@tabular[#:sep @hspace[2]
         #:style 'boxed
         #:row-properties '(bottom-border ())
 (list (list @bold{Key} @bold{Value})
       (list @racket['abi-version]
             @elem{the version of the tag itself, an exact integer; it changes
                   whenever the native interface does})
       (list @racket['raft] @elem{the RAFT release, as @racket[raft-version] returns it})
       (list @racket['rmm] "the RMM release, in the same form")
       (list @racket['cccl] @elem{the CCCL release, for example @racket["3.4.3"]})
       (list @racket['cuda-runtime]
             "the CUDA runtime the native library was compiled with, major.minor")
       (list @racket['handle-size] @elem{@tt{sizeof(raft::handle_t)}, in bytes})
       (list @racket['resource-types]
             "the number of resource kinds a RAFT handle can hold"))]

@examples[#:eval ev
(raft-abi)
]

A tag from RAFT 26.10, or from headers whose handle has another layout,
differs from this one:

@examples[#:eval ev #:label #f
(define (abi-mismatches built-against)
  (for/list ([(key value) (in-hash built-against)]
             #:unless (equal? value (hash-ref (raft-abi) key #f)))
    key))
(abi-mismatches (raft-abi))
(abi-mismatches (hash-set (raft-abi) 'raft "26.10.00"))
(abi-mismatches (hash-update (raft-abi) 'handle-size add1))
]

A one-line support report:

@examples[#:eval ev #:label #f
(string-join (for/list ([key (in-list '(raft rmm cccl cuda-runtime))])
               (~a key "=" (hash-ref (raft-abi) key)))
             " ")
]}
