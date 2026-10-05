#lang racket/base

(require (only-in racket/match match match-define)
         (only-in rackunit check-equal? check-pred check-true test-case)
         (only-in "../main.rkt" raft-abi raft-version))

(define public-names
  '(current-device-resources device-count
                             device-resources
                             device-resources?
                             exn:fail:raft
                             exn:fail:raft-kind
                             exn:fail:raft?
                             raft-abi
                             raft-version
                             resources-device
                             resources-sync!
                             struct:exn:fail:raft
                             with-device-resources))

(define (phase-0-exports mod)
  (module-declared? mod #t)
  (define-values (variables syntax) (module->exports mod))
  (sort (for*/list ([exports (in-list (append variables syntax))]
                    [entry (in-list (match exports
                                      [(cons 0 entries) entries]
                                      [_ '()]))])
          (match-define (cons name _) entry)
          name)
        symbol<?))

(test-case "raft/core and raft export exactly the documented names"
  (check-equal? (phase-0-exports 'raft/core) public-names)
  (check-equal? (phase-0-exports 'raft) public-names))

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
