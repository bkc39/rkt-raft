#lang racket/base

(require (only-in rackunit check-equal? check-pred check-true test-case)
         (only-in "../main.rkt" raft-abi raft-version))

(test-case "raft-version names the pinned RAFT release"
  (check-equal? (raft-version) "26.08.00"))

(test-case "raft-abi describes the headers the shim was compiled against"
  (define abi (raft-abi))
  (check-true (immutable? abi))
  (check-equal? (sort (hash-keys abi) symbol<?)
                '(abi-version cccl cuda-runtime handle-size raft resource-types rmm))
  (check-equal? (hash-ref abi 'abi-version) 1)
  (check-equal? (hash-ref abi 'raft) (raft-version))
  (check-equal? (hash-ref abi 'rmm) "26.08.00")
  (check-equal? (hash-ref abi 'cccl) "3.4.3")
  (check-equal? (hash-ref abi 'cuda-runtime) "13.2")
  (check-equal? (hash-ref abi 'resource-types) 22)
  (check-pred exact-positive-integer? (hash-ref abi 'handle-size)))

(test-case "raft-abi is the same value every time"
  (check-equal? (raft-abi) (raft-abi)))
