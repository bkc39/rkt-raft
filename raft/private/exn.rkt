#lang racket/base

(provide (struct-out exn:fail:raft))

(struct exn:fail:raft exn:fail (kind))
