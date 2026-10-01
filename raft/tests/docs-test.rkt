#lang racket/base

(require (only-in racket/format ~a)
         (only-in racket/port with-output-to-string)
         (only-in racket/string string-join string-split)
         (only-in rackunit check-equal? check-exn check-pred check-true test-case)
         (only-in "../main.rkt" raft-abi raft-version))

(test-case "getting started: the first program and the stack report"
  (check-equal? (raft-version) "26.08.00")
  (define abi (raft-abi))
  (check-equal? (hash-ref abi 'raft) "26.08.00")
  (check-equal? (hash-ref abi 'rmm) "26.08.00")
  (check-equal? (hash-ref abi 'cuda-runtime) "13.2")
  (check-equal? (with-output-to-string
                  (lambda ()
                    (for ([part (in-list '(raft rmm cccl cuda-runtime))])
                      (printf "~a ~a\n" (~a part #:min-width 13) (hash-ref abi part)))))
                (string-append "raft          26.08.00\n"
                               "rmm           26.08.00\n"
                               "cccl          3.4.3\n"
                               "cuda-runtime  13.2\n")))

(test-case "concepts: row-major and column-major order"
  (define m '((1 2 3) (4 5 6)))
  (define (row-major rows) (apply append rows))
  (define (column-major rows) (apply append (apply map list rows)))
  (check-equal? (row-major m) '(1 2 3 4 5 6))
  (check-equal? (column-major m) '(1 4 2 5 3 6)))

(test-case "reference: raft-version"
  (define release (map string->number (string-split (raft-version) ".")))
  (check-equal? release '(26 8 0))
  (check-true (apply (lambda (year month patch) (>= (+ (* 100 year) month) 2608)) release))
  (define (require-raft-release! wanted)
    (unless (string=? (raft-version) wanted)
      (error 'my-pipeline "built for RAFT ~a, but this is RAFT ~a" wanted (raft-version))))
  (check-pred void? (require-raft-release! "26.08.00"))
  (check-exn #rx"^my-pipeline: built for RAFT 26.10.00, but this is RAFT 26.08.00$"
             (lambda () (require-raft-release! "26.10.00"))))

(test-case "reference: raft-abi"
  (check-equal? (raft-abi)
                (hasheq 'abi-version 1
                        'cccl "3.4.3"
                        'cuda-runtime "13.2"
                        'handle-size 32
                        'raft "26.08.00"
                        'resource-types 22
                        'rmm "26.08.00"))
  (check-equal? (hash-ref (raft-abi) 'handle-size) 32)
  (define (abi-mismatches built-against)
    (for/list ([(key value) (in-hash built-against)]
               #:unless (equal? value (hash-ref (raft-abi) key #f)))
      key))
  (check-equal? (abi-mismatches (raft-abi)) '())
  (check-equal? (abi-mismatches (hash-set (raft-abi) 'raft "26.10.00")) '(raft))
  (check-equal? (string-join (for/list ([key (in-list '(raft rmm cccl cuda-runtime))])
                               (~a key "=" (hash-ref (raft-abi) key)))
                             " ")
                "raft=26.08.00 rmm=26.08.00 cccl=3.4.3 cuda-runtime=13.2"))
