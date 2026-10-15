#lang racket/base

(require (only-in racket/match match match-define match-let)
         (only-in racket/port with-output-to-string)
         (only-in racket/string string-split)
         (only-in rackunit check-equal? check-exn check-false check-pred check-true test-case)
         (only-in "../main.rkt"
                  raft-abi
                  raft-abi-cccl
                  raft-abi-cuda-runtime
                  raft-abi-handle-size
                  raft-abi-raft
                  raft-abi-rmm
                  raft-abi-version
                  raft-abi?
                  raft-version))

(test-case "getting started: the first program and the stack report"
  (check-equal? (raft-version) "26.08.00")
  (match-define (raft-abi #:raft raft #:rmm rmm #:cccl cccl #:cuda-runtime cuda-runtime) (raft-abi))
  (check-equal? (with-output-to-string
                 (lambda ()
                   (printf "raft ~a\nrmm ~a\ncccl ~a\ncuda-runtime ~a\n" raft rmm cccl cuda-runtime)))
                "raft 26.08.00\nrmm 26.08.00\ncccl 3.4.3\ncuda-runtime 13.2\n"))

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
  (check-equal? (format "~a" (raft-abi))
                (string-append "#<raft-abi raft 26.08.00 rmm 26.08.00 cccl 3.4.3 cuda-runtime 13.2"
                               " version 1 resource-types 22 handle-size 32>"))
  (match-define (raft-abi #:raft raft #:cuda-runtime cuda-runtime) (raft-abi))
  (check-equal? (list raft cuda-runtime) '("26.08.00" "13.2"))
  (define (support-status abi)
    (match abi
      [(raft-abi #:raft "26.08.00") 'supported]
      [(raft-abi #:raft other) (list 'untested other)]))
  (check-equal? (support-status (raft-abi)) 'supported)
  (check-equal? (support-status (struct-copy raft-abi (raft-abi) [raft "26.10.00"]))
                '(untested "26.10.00"))
  (define (abi-mismatches built-against)
    (for/list ([field (in-list (list raft-abi-version
                                     raft-abi-raft
                                     raft-abi-rmm
                                     raft-abi-cccl
                                     raft-abi-handle-size))]
               [name (in-list '(version raft rmm cccl handle-size))]
               #:unless (equal? (field built-against) (field (raft-abi))))
      name))
  (check-equal? (abi-mismatches (raft-abi)) '())
  (check-equal? (abi-mismatches (struct-copy raft-abi (raft-abi) [raft "26.10.00"])) '(raft))
  (check-equal? (abi-mismatches (struct-copy raft-abi (raft-abi) [handle-size 40])) '(handle-size))
  (check-equal? (match-let ([(raft-abi #:raft raft #:rmm rmm #:cccl cccl) (raft-abi)])
                  (format "raft=~a rmm=~a cccl=~a" raft rmm cccl))
                "raft=26.08.00 rmm=26.08.00 cccl=3.4.3")
  (define abi (raft-abi))
  (check-pred raft-abi? abi)
  (check-equal? (raft-abi-version abi) 1)
  (check-equal? (raft-abi-cuda-runtime abi) "13.2")
  (check-true (equal? abi (raft-abi)))
  (check-false (equal? abi (struct-copy raft-abi abi [rmm "26.10.00"]))))
