#lang racket/base

(module+ main
  (require (only-in racket/match match)
           ;; whole-module: define-runtime-path needs bindings only-in strips
           racket/runtime-path
           (only-in "../../raft/private/cuda-wheels.rkt"
                    cuda-wheel-dir
                    cuda-wheel-root
                    cuda-wheel-sha256
                    cuda-wheel-url
                    cuda-wheel-version
                    read-cuda-wheels))
  (define-runtime-path raft-pins "../../raft/private/cuda-wheels.rktd")
  (match (current-command-line-arguments)
    [(vector "pin" pins name)
     (define wheel (hash-ref (read-cuda-wheels pins) name))
     (printf "~a ~a ~a\n"
             (cuda-wheel-version wheel)
             (cuda-wheel-url wheel)
             (cuda-wheel-sha256 wheel))]
    [(vector "dir" (and scope (or "user" "installation")) name)
     (displayln (cuda-wheel-dir (cuda-wheel-root (equal? scope "user"))
                                (hash-ref (read-cuda-wheels raft-pins) name)))]
    [_
     (raise-user-error 'cuda-pin
                       "usage: cuda-pin.rkt pin PINS-RKTD NAME | dir user|installation NAME")]))
