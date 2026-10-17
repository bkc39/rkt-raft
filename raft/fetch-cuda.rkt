#lang racket/base

(module+ main
  (require (only-in "private/cublas.rkt" fetch-cublas)
           (only-in "private/cuda-wheels.rkt" cuda-wheel-root)
           (only-in "private/exn.rkt" exn:fail:raft?))
  (with-handlers ([exn:fail:raft? (lambda (e)
                                    (eprintf "raft: ~a\n" (exn-message e))
                                    (exit 1))])
    (printf "raft: cuBLAS is in ~a\n" (fetch-cublas (cuda-wheel-root #t)))))
