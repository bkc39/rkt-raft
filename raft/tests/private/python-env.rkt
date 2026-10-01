#lang racket/base

(require syntax/parse/define
         (only-in json read-json write-json)
         (only-in racket/file delete-directory/files make-temporary-directory)
         (only-in racket/port open-output-nowhere)
         (only-in racket/system system*)
         (only-in rackunit check-equal? check-true test-case)
         (only-in "gpu.rkt" gpu-skip-reason skip))

(provide close?
         check-close
         run-twin
         test-twin
         twin-skip-reason)

(define python (find-executable-path "python3"))

;; The child sees only the dev shell's driver farm, so no host CUDA library
;; can shadow the ones the wheels were patched against.
(define (call-with-twin-env thunk #:env [extra '()])
  (define env (environment-variables-copy (current-environment-variables)))
  (define driver (getenv "RAFT_CUDA_DRIVER_PATH"))
  (when driver
    (environment-variables-set! env #"LD_LIBRARY_PATH" (string->bytes/utf-8 driver)))
  (for ([kv (in-list extra)])
    (environment-variables-set! env
                                (string->bytes/utf-8 (car kv))
                                (string->bytes/utf-8 (cdr kv))))
  (parameterize ([current-environment-variables env])
    (thunk)))

;; Probed from the temp directory with PYTHONSAFEPATH: `python3 -c` puts the
;; working directory on sys.path, where a same-named directory would shadow
;; the wheel and answer yes with nothing installed.
(define (python-imports? module)
  (and python
       (call-with-twin-env
        #:env '(("PYTHONSAFEPATH" . "1"))
        (lambda ()
          (parameterize ([current-directory (find-system-path 'temp-dir)]
                         [current-output-port (open-output-nowhere)]
                         [current-error-port (open-output-nowhere)])
            (system* python "-c" (format "import ~a" module)))))))

(define twin-skip-reason
  (cond
    [(not python) "python3 is not on PATH"]
    [(not (python-imports? "pylibraft")) "import pylibraft failed"]
    [else #f]))

(define (run-twin script input)
  (define dir (make-temporary-directory "raft-twin-~a"))
  (dynamic-wind
   void
   (lambda ()
     (define in-path (build-path dir "in.json"))
     (define out-path (build-path dir "out.json"))
     (call-with-output-file in-path (lambda (out) (write-json input out)))
     (define err (open-output-string))
     (define ok?
       (call-with-twin-env
        (lambda ()
          (parameterize ([current-directory dir]
                         [current-error-port err])
            (system* python (path->string script)
                     (path->string in-path) (path->string out-path))))))
     (unless ok?
       (error 'run-twin "~a failed:\n~a" script (get-output-string err)))
     (call-with-input-file out-path read-json))
   (lambda ()
     (delete-directory/files dir #:must-exist? #f))))

(define (close? actual expected tolerance)
  (<= (abs (- actual expected))
      (* tolerance (max 1.0 (abs expected)))))

(define (check-close actual expected #:tolerance [tolerance 0.0])
  (check-equal? (length actual) (length expected) "element count")
  (for ([a (in-list actual)]
        [e (in-list expected)]
        [i (in-naturals)])
    (check-true (close? a e tolerance)
                (format "element ~a: ~a against the twin's ~a" i a e))))

(define-syntax-parse-rule (test-twin name:expr body:expr ...+)
  (cond
    [gpu-skip-reason (skip (format "no GPU (~a)" gpu-skip-reason) name)]
    [twin-skip-reason (skip (format "no Python twin (~a)" twin-skip-reason) name)]
    [else (test-case name body ...)]))
