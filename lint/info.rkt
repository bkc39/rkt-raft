#lang info

#|review: ignore|#

(define collection "raft-lint")
(define deps '("base" "review"))
(define review-exts '((raft-lint/review should-review? review-syntax)))
(define pkg-desc "raco review rules for the raft package's own forms")
(define license 'Apache-2.0)
