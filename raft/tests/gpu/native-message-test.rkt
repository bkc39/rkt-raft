#lang racket/base

(require (only-in racket/match match-define)
         (only-in rackunit check-equal? check-regexp-match)
         (only-in "../../private/error.rkt" call/raft)
         (only-in "../../private/foreign/array-api.rkt" rr-array-create)
         (only-in "../../private/foreign/array.rkt" blank-view)
         (only-in "../../private/foreign/memory.rkt" rr-resources-free)
         (only-in "../../private/resource.rkt" with-release)
         (only-in "../../private/resources.rkt" host-resources)
         (only-in "../private/gpu.rkt" test-gpu)
         (only-in "../private/native.rkt" new-resources)
         (only-in "../private/probe.rkt"
                  call/probe
                  probe-raft-fail
                  probe-raft-fail-job
                  test-host-probe)
         (only-in "../private/raft-error.rkt" raised-and-logged))

(define (check-backtrace-logged result)
  (match-define (list message log) result)
  (check-regexp-match #px"^demo: RAFT failure at file=\\S+ line=[0-9]+: token 7$" message)
  (match-define (list (list 'debug 'raft text)) log)
  (check-regexp-match
   #px"^raft: demo: RAFT failure at file=\\S+ line=[0-9]+: token 7\nObtained [0-9]+ stack frames\n#1 in "
   text))

(for ([call (in-list `(("a short call" . ,(lambda ()
                                            (call/probe 'demo (lambda () (probe-raft-fail 7)))))
                       ("a job" . ,(lambda () (probe-raft-fail-job 'demo (host-resources) 7)))))])
  (match-define (cons what thunk) call)
  (test-host-probe (format "~a's native backtrace goes to the raft logger, not the message" what)
    (check-backtrace-logged (raised-and-logged thunk))))

(test-gpu "libraftrkt's multi-line text is cut where call/raft raises"
  (define dtype (string->symbol "float32\n#1 in /nix/store/0000-raft/lib/libraft.so"))
  (with-release ([resources (new-resources) rr-resources-free])
    (match-define (list message log)
      (raised-and-logged
       (lambda ()
         (call/raft 'demo
                    (lambda () (rr-array-create resources dtype '(2) 'row-major (blank-view)))))))
    (check-equal? message "demo: unsupported dtype float32")
    (match-define (list (list 'debug 'raft text)) log)
    (check-regexp-match
     #px"^raft: demo: unsupported dtype float32\n#1 in /nix/store/0000-raft/lib/libraft.so; expected "
     text)))
