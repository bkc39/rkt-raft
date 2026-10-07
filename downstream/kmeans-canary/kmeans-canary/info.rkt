#lang info

#|review: ignore|#

(define collection "kmeans-canary")
(define deps '("base" "raft"))
(define build-deps '("rackunit-lib"))
(define pkg-desc "The k-means canary: a minimal cuML binding on raft's frozen downstream interface")
(define license 'Apache-2.0)
(define test-omit-paths '("tests/python"))
