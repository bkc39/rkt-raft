((define r (device-resources)) (values "") "" "")
(r (values "#<device-resources device 0>\n") "" "")
((resources-device r) (values "0\n") "" "")
((define loader (device-resources)) (values "") "" "")
((define trainer (device-resources)) (values "") "" "")
((eq? loader trainer) (values "#f\n") "" "")
((map resources-device (list loader trainer)) (values "'(0 0)\n") "" "")
((device-count) (values "1\n") "" "")
((device-resources #:device (device-count))
 (raise "device-resources: no device 1 among 1")
 ""
 "")
((device-resources? (current-device-resources)) (values "#t\n") "" "")
((device-resources? 0) (values "#f\n") "" "")
((define (as-resources where)
   (if (device-resources? where) where (current-device-resources where)))
 (values "")
 ""
 "")
((eq? (as-resources 0) (current-device-resources)) (values "#t\n") "" "")
((eq? (as-resources loader) loader) (values "#t\n") "" "")
((define finished (with-device-resources ((r (device-resources))) r))
 (values "")
 ""
 "")
((device-resources? finished) (values "#t\n") "" "")
((resources-device (current-device-resources)) (values "0\n") "" "")
((printf "training on cuda:~a\n" (resources-device trainer))
 (values "")
 "training on cuda:0\n"
 "")
((define (same-device? a b) (= (resources-device a) (resources-device b)))
 (values "")
 ""
 "")
((same-device? loader trainer) (values "#t\n") "" "")
((resources-device finished) (values "0\n") "" "")
((resources-sync! (current-device-resources)) (values "") "" "")
((define (milliseconds-on r thunk)
   (define start (current-inexact-milliseconds))
   (thunk)
   (resources-sync! r)
   (- (current-inexact-milliseconds) start))
 (values "")
 ""
 "")
((milliseconds-on trainer void) (values "0.015625\n") "" "")
((thread-wait
  (thread
   (lambda ()
     (resources-sync! trainer)
     (displayln "the trainer's stream has drained"))))
 (values "")
 "the trainer's stream has drained\n"
 "")
((resources-sync! finished)
 (raise "resources-sync!: the device resources on device 0 were released")
 ""
 "")
((eq? (current-device-resources) (current-device-resources))
 (values "#t\n")
 ""
 "")
((eq? (current-device-resources) (current-device-resources 0))
 (values "#t\n")
 ""
 "")
((define (worker-resources)
   (define answer (make-channel))
   (thread (lambda () (channel-put answer (current-device-resources))))
   (channel-get answer))
 (values "")
 ""
 "")
((define a (worker-resources)) (values "") "" "")
((define b (worker-resources)) (values "") "" "")
((list (eq? a b) (eq? a (current-device-resources)))
 (values "'(#f #f)\n")
 ""
 "")
((define before (current-device-resources)) (values "") "" "")
((with-device-resources ((r before)) (resources-sync! r)) (values "") "" "")
(before (values "#<device-resources device 0 released>\n") "" "")
((eq? before (current-device-resources)) (values "#f\n") "" "")
((define unscoped (device-resources)) (values "") "" "")
((define scoped (with-device-resources ((r (device-resources))) r))
 (values "")
 ""
 "")
((list unscoped scoped)
 (values
  "'(#<device-resources device 0> #<device-resources device 0 released>)\n")
 ""
 "")
((with-device-resources
  ((r (device-resources)))
  (resources-sync! r)
  (resources-device r))
 (values "0\n")
 ""
 "")
((define (run-batch items)
   (with-device-resources
    ((r (device-resources)))
    (for
     ((item (in-list items)))
     (when (negative? item) (error 'run-batch "bad item ~a" item)))
    (resources-sync! r)
    (length items)))
 (values "")
 ""
 "")
((run-batch '(1 2 3)) (values "3\n") "" "")
((run-batch '(1 -2 3)) (raise "run-batch: bad item -2") "" "")
((define-values
  (left right)
  (with-device-resources
   ((left (device-resources)) (right (device-resources)))
   (values left right)))
 (values "")
 ""
 "")
((list left right)
 (values
  "'(#<device-resources device 0 released> #<device-resources device 0 released>)\n")
 ""
 "")
((resources-sync! left)
 (raise "resources-sync!: the device resources on device 0 were released")
 ""
 "")
((device-count) (values "1\n") "" "")
((define (device-for-worker i) (modulo i (device-count))) (values "") "" "")
((map device-for-worker '(0 1 2 3)) (values "'(0 0 0 0)\n") "" "")
((define per-device
   (for/list ((d (in-range (device-count)))) (device-resources #:device d)))
 (values "")
 ""
 "")
((map resources-device per-device) (values "'(0)\n") "" "")
((define missing
   (with-handlers
    ((exn:fail:raft? values))
    (device-resources #:device (device-count))))
 (values "")
 ""
 "")
((exn-message missing)
 (values "\"device-resources: no device 1 among 1\"\n")
 ""
 "")
((exn:fail:raft-kind missing) (values "'logic\n") "" "")
((define (describe-failure thunk)
   (with-handlers
    ((exn:fail:raft?
      (lambda (e)
        (case (exn:fail:raft-kind e)
          ((out-of-memory) 'free-memory-and-retry)
          ((logic) 'fix-the-call)
          (else 'report)))))
    (thunk)
    'ok))
 (values "")
 ""
 "")
((describe-failure (lambda () (current-device-resources)))
 (values "'ok\n")
 ""
 "")
((describe-failure (lambda () (device-resources #:device 99)))
 (values "'fix-the-call\n")
 ""
 "")
((with-handlers
  ((exn:fail:raft?
    (lambda (e)
      (match-define (list who _ ...) (string-split (exn-message e) ": "))
      who)))
  (resources-sync! finished))
 (values "\"resources-sync!\"\n")
 ""
 "")
((current-exit-wait) (values "10\n") "" "")
((parameterize ((current-exit-wait 60)) (current-exit-wait))
 (values "60\n")
 ""
 "")
((define seen (make-channel)) (values "") "" "")
((parameterize
  ((current-exit-wait +inf.0))
  (thread (lambda () (channel-put seen (current-exit-wait)))))
 (values "#<thread>\n")
 ""
 "")
((channel-get seen) (values "+inf.0\n") "" "")
((current-exit-wait -1)
 (raise
  "current-exit-wait: expected a non-negative real number of seconds, given -1")
 ""
 "")
((parameterize ((current-exit-wait +nan.0)) 'unreached)
 (raise
  "current-exit-wait: expected a non-negative real number of seconds, given +nan.0")
 ""
 "")
((raft-version) (values "\"26.08.00\"\n") "" "")
((match-define
  (list year month _)
  (map string->number (string-split (raft-version) ".")))
 (values "")
 ""
 "")
((list year month) (values "'(26 8)\n") "" "")
((>= (+ (* 100 year) month) 2608) (values "#t\n") "" "")
((define (require-raft-release! wanted)
   (unless (string=? (raft-version) wanted)
     (error
      'my-pipeline
      "built for RAFT ~a, but this is RAFT ~a"
      wanted
      (raft-version))))
 (values "")
 ""
 "")
((require-raft-release! "26.08.00") (values "") "" "")
((require-raft-release! "26.10.00")
 (raise "my-pipeline: built for RAFT 26.10.00, but this is RAFT 26.08.00")
 ""
 "")
((raft-abi)
 (values
  "#<raft-abi raft 26.08.00 rmm 26.08.00 cccl 3.4.3 cuda-runtime 13.2 version 1 resource-types 22 handle-size 32>\n")
 ""
 "")
((match-define (raft-abi #:raft raft #:cuda-runtime cuda-runtime) (raft-abi))
 (values "")
 ""
 "")
((list raft cuda-runtime) (values "'(\"26.08.00\" \"13.2\")\n") "" "")
((define (support-status abi)
   (match
    abi
    ((raft-abi #:raft "26.08.00") 'supported)
    ((raft-abi #:raft other) (list 'untested other))))
 (values "")
 ""
 "")
((support-status (raft-abi)) (values "'supported\n") "" "")
((support-status (struct-copy raft-abi (raft-abi) (raft "26.10.00")))
 (values "'(untested \"26.10.00\")\n")
 ""
 "")
((define (abi-mismatches built-against)
   (for/list
    ((field (in-list
             (list
              raft-abi-version
              raft-abi-raft
              raft-abi-rmm
              raft-abi-cccl
              raft-abi-handle-size)))
     (name (in-list '(version raft rmm cccl handle-size)))
     #:unless
     (equal? (field built-against) (field (raft-abi))))
    name))
 (values "")
 ""
 "")
((abi-mismatches (raft-abi)) (values "'()\n") "" "")
((abi-mismatches (struct-copy raft-abi (raft-abi) (raft "26.10.00")))
 (values "'(raft)\n")
 ""
 "")
((abi-mismatches (struct-copy raft-abi (raft-abi) (handle-size 40)))
 (values "'(handle-size)\n")
 ""
 "")
((match-let
  (((raft-abi #:raft raft #:rmm rmm #:cccl cccl) (raft-abi)))
  (format "raft=~a rmm=~a cccl=~a" raft rmm cccl))
 (values "\"raft=26.08.00 rmm=26.08.00 cccl=3.4.3\"\n")
 ""
 "")
((define abi (raft-abi)) (values "") "" "")
((raft-abi? abi) (values "#t\n") "" "")
((raft-abi-version abi) (values "1\n") "" "")
((raft-abi-cuda-runtime abi) (values "\"13.2\"\n") "" "")
((equal? abi (raft-abi)) (values "#t\n") "" "")
((equal? abi (struct-copy raft-abi abi (rmm "26.10.00")))
 (values "#f\n")
 ""
 "")
