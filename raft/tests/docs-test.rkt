#lang racket/base

(require (only-in racket/format ~a)
         (only-in racket/match match-define)
         (only-in racket/port with-output-to-string)
         (only-in racket/string string-join string-split)
         (only-in rackunit check-equal? check-exn check-pred check-true test-case)
         (only-in "../main.rkt" raft-abi raft-version))

(test-case "getting started: the first program and the stack report"
  (check-equal? (raft-version) "26.08.00")
  (check-true (> (hash-count (raft-abi)) 4))
  (match-define (hash-table ('raft raft) ('rmm rmm) ('cccl cccl) ('cuda-runtime cuda-runtime))
    (raft-abi))
  (check-equal? (with-output-to-string
                 (lambda ()
                   (printf "raft ~a\nrmm ~a\ncccl ~a\ncuda-runtime ~a\n" raft rmm cccl cuda-runtime)))
                "raft 26.08.00\nrmm 26.08.00\ncccl 3.4.3\ncuda-runtime 13.2\n"))

(test-case "concepts: row-major and column-major order"
  (define m '((1 2 3) (4 5 6)))
  (define (row-major rows)
    (apply append rows))
  (define (column-major rows)
    (apply append (apply map list rows)))
  (check-equal? (row-major m) '(1 2 3 4 5 6))
  (check-equal? (column-major m) '(1 4 2 5 3 6)))

(test-case "reference: raft-version"
  (match-define (list year month _) (map string->number (string-split (raft-version) ".")))
  (check-equal? (list year month) '(26 8))
  (check-true (>= (+ (* 100 year) month) 2608))
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
  (define (abi-mismatches built-against)
    (for/list ([(key value) (in-hash built-against)]
               #:unless (equal? value (hash-ref (raft-abi) key #f)))
      key))
  (check-equal? (abi-mismatches (raft-abi)) '())
  (check-equal? (abi-mismatches (hash-set (raft-abi) 'raft "26.10.00")) '(raft))
  (check-equal? (abi-mismatches (hash-update (raft-abi) 'handle-size add1)) '(handle-size))
  (check-equal? (string-join (for/list ([key (in-list '(raft rmm cccl cuda-runtime))])
                               (~a key "=" (hash-ref (raft-abi) key)))
                             " ")
                "raft=26.08.00 rmm=26.08.00 cccl=3.4.3 cuda-runtime=13.2"))
