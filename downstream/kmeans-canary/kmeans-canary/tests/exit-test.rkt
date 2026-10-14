#lang racket/base

;; whole-module: define-runtime-path needs bindings only-in strips
(require racket/runtime-path
         (only-in rackunit check-equal?)
         (only-in raft/tests/private/exit-run
                  check-lines
                  in-flight-line
                  run-exit-program
                  still-running-line)
         (only-in raft/tests/private/gpu test-gpu))

(define-runtime-path programs "fixtures/exit-programs.rktd")

(define (check-runs name runs code expected)
  (for ([_ (in-range runs)])
    (define-values (rc _out lines) (run-exit-program name #:fixture programs))
    (check-equal? rc code (format "~a" name))
    (check-lines lines expected)))

(test-gpu "an exit 100 ms into a warm fit waits for it"
  (check-runs 'warm-fit 8 0 (list (in-flight-line 1 200 3000))))

(test-gpu "an exit 100 ms into a cold fit waits for it"
  (check-runs 'cold-fit 4 0 (list (in-flight-line 1 0 +inf.0))))

(test-gpu "a fit under a zero bound exits without native teardown"
  (check-runs 'unwaited-fit 3 3 (list (in-flight-line 1 0 50) (still-running-line 1))))

(test-gpu "an exit waits for a killed caller's fit"
  (check-runs 'killed-fit 3 0 (list (in-flight-line 1 0 +inf.0))))

(test-gpu "an exit waits for a place's fit"
  (check-runs 'place-fit 3 0 (list (in-flight-line 1 0 +inf.0))))

(test-gpu "a job past its bound leaves its late static alone"
  (check-runs 'sleep-job 3 3 (list (in-flight-line 1 0 +inf.0) (still-running-line 1))))
