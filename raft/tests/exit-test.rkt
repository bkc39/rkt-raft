#lang racket/base

(require (only-in racket/list last take)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path
         (only-in rackunit check-equal? check-not-false check-true test-case)
         (only-in "../main.rkt" current-exit-wait)
         (only-in "private/exit-run.rkt"
                  atexit-line
                  check-lines
                  in-flight-line
                  run-exit-program
                  still-running-line)
         (only-in "private/probe.rkt" test-host-probe)
         (only-in "private/raft-error.rkt" check-raft-error))

(define-runtime-path programs "fixtures/exit-programs.rktd")

(define (run name #:env [env '()])
  (run-exit-program name #:fixture programs #:env env))

(define (check-exit name code expected #:env [env '()])
  (define-values (rc _out lines) (run name #:env env))
  (check-equal? rc code (format "~a" name))
  (check-lines lines expected))

(test-case "current-exit-wait defaults to 10 seconds"
  (check-equal? (current-exit-wait) 10))

(test-case "current-exit-wait is parameterized per thread"
  (parameterize ([current-exit-wait 2])
    (check-equal? (current-exit-wait) 2)
    (check-equal? (thread-wait (thread (lambda () (current-exit-wait)) #:keep 'results)) 2))
  (check-equal? (current-exit-wait) 10))

(test-case "current-exit-wait accepts every non-negative real"
  (for ([seconds (in-list (list 0 1/2 2.5 10 +inf.0))])
    (check-equal? (parameterize ([current-exit-wait seconds])
                    (current-exit-wait))
                  seconds)))

(test-case "current-exit-wait refuses the rest, assigned or parameterized"
  (for ([given (in-list (list -1 -0.5 +nan.0 -inf.0 'x "10"))])
    (define message
      (format "current-exit-wait: expected a non-negative real number of seconds, given ~e" given))
    (check-raft-error 'logic message (lambda () (current-exit-wait given)))
    (check-raft-error 'logic
                      message
                      (lambda ()
                        (parameterize ([current-exit-wait given])
                          (current-exit-wait)))))
  (check-equal? (current-exit-wait) 10))

(test-host-probe "with no jobs the exit drains at once and tears down"
                 (check-exit 'no-jobs-exit 3 (list (in-flight-line 0 0 1) atexit-line))
                 (check-exit 'no-jobs-return 0 (list (in-flight-line 0 0 1) atexit-line)))

(test-host-probe "the exit waits for a job that returns within its bound"
                 (check-exit 'clean 4 (list (in-flight-line 1 250 1000) atexit-line)))

(test-host-probe "past its bound the exit skips native teardown"
                 (check-exit 'timeout 5 (list (in-flight-line 1 500 1000) (still-running-line 1))))

(test-host-probe "the skip keeps the exit code"
                 (for ([action (in-list '("0" "1" "255" "x"))]
                       [code (in-list '(0 1 255 0))])
                   (check-exit 'code
                               code
                               (list (in-flight-line 1 500 1000) (still-running-line 1))
                               #:env (list (cons "RAFT_EXIT_CASE" action))))
                 (define-values (rc _out lines) (run 'code #:env '(("RAFT_EXIT_CASE" . "error"))))
                 (check-equal? rc 1)
                 (check-equal? (car lines) "boom: x")
                 (check-true (>= (length lines) 3))
                 (check-lines (list-tail lines (- (length lines) 2))
                              (list (in-flight-line 1 500 1000) (still-running-line 1))))

(test-host-probe "output written before the exit survives the skip"
                 (define-values (rc out lines) (run 'output))
                 (check-equal? rc 5)
                 (check-equal? out "out\n")
                 (check-lines lines (list "err" (in-flight-line 1 500 1000) (still-running-line 1))))

(test-host-probe "an exit from another thread waits for the job"
                 (check-exit 'other-thread 6 (list (in-flight-line 1 250 1000) atexit-line)))

(test-host-probe "an exit from a break handler runs after the job"
                 (check-exit 'break-handler 7 (list (in-flight-line 0 0 1) atexit-line)))

(test-host-probe "the exit waits for a killed caller's job"
                 (check-exit 'killed-caller 8 (list (in-flight-line 1 250 1000) atexit-line)))

(test-host-probe "a queued job counts at exit"
                 (check-exit 'queued 9 (list (in-flight-line 2 250 1000) atexit-line)))

(test-host-probe "a looping submitter in the main place lets the exit through"
                 (check-exit 'looping-main 10 (list (in-flight-line 1 0 150) atexit-line)))

(test-host-probe "a looping submitter in a place parks at exit"
                 (check-exit 'looping-place
                             11
                             (list (lambda (line)
                                     (or ((in-flight-line 0 0 150) line)
                                         ((in-flight-line 1 0 150) line)))
                                   atexit-line)))

(test-host-probe "the exit waits for a place's job"
                 (check-exit 'place-job 12 (list (in-flight-line 1 300 1000) atexit-line)))

(test-host-probe "a place's own current-exit-wait bounds its job"
                 (check-exit 'place-value 13 (list (in-flight-line 1 0 50) (still-running-line 1))))

(test-host-probe "a place exiting does not close the executor"
                 (define-values (rc out lines) (run 'place-exits))
                 (check-equal? rc 0)
                 (check-equal? out "5 1 1\n")
                 (check-lines lines (list (in-flight-line 0 0 1) atexit-line)))

(test-host-probe "a bound covers only its own job"
                 (check-exit 'own-bound 14 (list (in-flight-line 2 950 1500) (still-running-line 1))))

(test-host-probe
 "the largest bound governs the wait"
 (check-exit 'largest-bound 15 (list (in-flight-line 2 1000 1500) (still-running-line 2))))

(test-host-probe
 "the default bound is 10 seconds"
 (check-exit 'default-bound 16 (list (in-flight-line 1 10000 10500) (still-running-line 1))))

(test-host-probe "a zero bound does not wait"
                 (check-exit 'zero-bound 17 (list (in-flight-line 1 0 50) (still-running-line 1))))

(test-host-probe
 "an infinite bound outwaits the others and the deadline is recomputed"
 (check-exit 'infinite-bound 18 (list (in-flight-line 2 1450 2000) (still-running-line 1))))

(test-host-probe
 "a late static survives the skip"
 (check-exit 'late-static-skip 19 (list (in-flight-line 1 500 1000) (still-running-line 1))))

(test-host-probe "a late static outlives a clean exit"
                 (check-exit 'late-static-clean 20 (list (in-flight-line 1 250 1000) atexit-line)))

(test-host-probe "the hook does not depend on the custodian current at load"
                 (check-exit 'loaded-elsewhere 4 (list (in-flight-line 1 250 1000) atexit-line)))

(test-host-probe "each instantiation drains"
                 (define-values (rc _out lines) (run 'two-instantiations))
                 (check-equal? rc 4)
                 (check-equal? (length lines) 3)
                 (check-equal? (last lines) atexit-line)
                 (define drains (take lines 2))
                 (check-not-false (ormap (in-flight-line 1 250 1000) drains))
                 (check-not-false (ormap (in-flight-line 0 0 1) drains)))

(test-host-probe "raft only in a place gets the native backstop"
                 (check-exit 'place-only 21 (list "probe: gate opened" atexit-line)))
