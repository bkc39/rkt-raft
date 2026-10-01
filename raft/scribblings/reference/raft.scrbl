#lang scribble/manual
@(require "../utils.rkt")

@(define ev (make-raft-eval))

@title[#:tag "ref-raft"]{The @racketmodname[raft] module}

@defmodule[raft]

@racket[(require raft)] provides the whole library. Today that is the version
of RAFT the native library was built against and its ABI tag.

@defproc[(raft-version) string?]{

Returns the RAFT release that @tt{libraftrkt} was compiled against, spelled as
RAFT spells it: two digits each for the year, the month and the patch, so
@racket["26.08.00"] is the August 2026 release. It is the same string
@tt{pylibraft.__version__} gives for the same release.

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

Returns the ABI tag of @tt{libraftrkt}: an immutable hash, keyed by symbols, of
the facts a second native library has to share with it to exchange RAFT
handles and arrays safely. RAFT has no versioned C++ namespace and the layout
of its handle changes between releases, so a native library that receives a
@tt{raft::handle_t} from this one (a cuML binding, for example) must have been
compiled against identical RAFT, RMM and CCCL headers. Such a library records
the tag it was built against and compares it with this one when it loads.

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

A downstream library checks the tag before it loads its own native code. Here
the expected tag is the current one, then the tag of a library built against
RAFT 26.10, then one built against headers whose @tt{raft::handle_t} has a
different layout, which a version check alone would miss:

@examples[#:eval ev #:label #f
(define (abi-mismatches built-against)
  (for/list ([(key value) (in-hash built-against)]
             #:unless (equal? value (hash-ref (raft-abi) key #f)))
    key))
(abi-mismatches (raft-abi))
(abi-mismatches (hash-set (raft-abi) 'raft "26.10.00"))
(abi-mismatches (hash-update (raft-abi) 'handle-size add1))
]

The tag also makes a one-line support report:

@examples[#:eval ev #:label #f
(string-join (for/list ([key (in-list '(raft rmm cccl cuda-runtime))])
               (~a key "=" (hash-ref (raft-abi) key)))
             " ")
]}
