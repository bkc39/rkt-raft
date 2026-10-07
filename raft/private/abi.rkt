#lang racket/base

(require (for-syntax racket/base
                     (only-in "abi-syntax.rkt" keyword-struct-binding))
         (only-in racket/format ~a ~r)
         (only-in racket/match match-define)
         (only-in "foreign/core.rkt" rr-abi rr-abi-tag->list))

(provide raft-abi
         raft-abi-cccl
         raft-abi-cuda-runtime
         raft-abi-handle-size
         raft-abi-raft
         raft-abi-resource-types
         raft-abi-rmm
         raft-abi-version
         raft-abi?)

(define (write-raft-abi abi port _mode)
  (write-string (~a "#<raft-abi raft "
                    (raft-abi-raft abi)
                    " rmm "
                    (raft-abi-rmm abi)
                    " cccl "
                    (raft-abi-cccl abi)
                    " cuda-runtime "
                    (raft-abi-cuda-runtime abi)
                    " version "
                    (raft-abi-version abi)
                    " resource-types "
                    (raft-abi-resource-types abi)
                    " handle-size "
                    (raft-abi-handle-size abi)
                    ">")
                port))

;; `raft-abi` itself is the query and the match pattern (below), so the struct
;; binds its static information to `raft-abi-struct` and never binds `raft-abi`.
(struct raft-abi (version raft rmm cccl cuda-runtime resource-types handle-size)
  #:name raft-abi-struct ;; noqa
  #:constructor-name make-raft-abi
  #:transparent
  #:property prop:custom-write
  write-raft-abi)

(define (two-digits n)
  (~r n #:min-width 2 #:pad-string "0"))

(define (rapids-release major minor patch)
  (~a (two-digits major) "." (two-digits minor) "." (two-digits patch)))

(define (cuda-release code)
  (~a (quotient code 1000) "." (quotient (remainder code 1000) 10)))

(define (query-raft-abi) ;; noqa
  (match-define (list version
                      raft-major
                      raft-minor
                      raft-patch
                      rmm-major
                      rmm-minor
                      rmm-patch
                      cccl-major
                      cccl-minor
                      cccl-patch
                      cuda-runtime
                      resource-types
                      handle-size)
    (rr-abi-tag->list (rr-abi)))
  (make-raft-abi version
                 (rapids-release raft-major raft-minor raft-patch)
                 (rapids-release rmm-major rmm-minor rmm-patch)
                 (~a cccl-major "." cccl-minor "." cccl-patch)
                 (cuda-release cuda-runtime)
                 resource-types
                 handle-size))

(define-syntax raft-abi
  (keyword-struct-binding #'query-raft-abi
                          #'raft-abi?
                          (list (cons '#:version #'raft-abi-version)
                                (cons '#:raft #'raft-abi-raft)
                                (cons '#:rmm #'raft-abi-rmm)
                                (cons '#:cccl #'raft-abi-cccl)
                                (cons '#:cuda-runtime #'raft-abi-cuda-runtime)
                                (cons '#:resource-types #'raft-abi-resource-types)
                                (cons '#:handle-size #'raft-abi-handle-size))
                          #'raft-abi-struct))
