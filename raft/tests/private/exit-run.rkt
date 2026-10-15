#lang racket/base

(require (only-in compiler/find-exe find-exe)
         (only-in racket/file delete-directory/files make-temporary-directory)
         (only-in racket/match == match)
         (only-in racket/port port->string)
         (only-in racket/string string-split)
         (only-in rackunit check-equal? check-true fail with-check-info)
         (only-in "../../private/resource.rkt" with-release))

(provide atexit-line
         check-lines
         in-flight-line
         run-exit-program
         still-running-line
         waited)

(define atexit-line "probe: atexit")

(define (still-running-line jobs [releases 0])
  (format
   "raft: exit: jobs still running: ~a; releases still running: ~a; exiting without native teardown"
   jobs
   releases))

(define (in-flight-parts line)
  (match (regexp-match #px"^raft: exit: jobs in flight: (\\d+); waited (\\d+) ms$" line)
    [(list _ n w) (list (string->number n) (string->number w))]
    [_ #f]))

(define (waited line)
  (match (in-flight-parts line)
    [(list _ w) w]
    [_ #f]))

(define ((in-flight-line n low high) line)
  (match (in-flight-parts line)
    [(list (== n) w) (<= low w high)]
    [_ #f]))

(define (line-matches? want line)
  (if (string? want)
      (string=? want line)
      (want line)))

(define (check-lines actual expected)
  (with-check-info (['stderr actual])
                   (check-equal? (length actual) (length expected))
                   (for ([line (in-list actual)]
                         [want (in-list expected)])
                     (check-true (line-matches? want line) line))))

(define (environment-with pairs)
  (define variables (environment-variables-copy (current-environment-variables)))
  (for ([pair (in-list (cons '("PLTSTDERR" . "debug@raft") pairs))])
    (environment-variables-set! variables
                                (string->bytes/utf-8 (car pair))
                                (string->bytes/utf-8 (cdr pair))))
  variables)

(define (run-exit-program name #:fixture fixture #:env [env '()])
  (define program (hash-ref (call-with-input-file fixture read) name))
  (with-release ([dir (make-temporary-directory "raft-exit-~a") delete-directory/files])
    (define path (build-path dir "program.rkt"))
    (call-with-output-file path (lambda (out) (write program out)))
    (define-values (process stdout stdin stderr)
      (parameterize ([current-environment-variables (environment-with env)])
        (subprocess #f #f #f (find-exe) path)))
    (close-output-port stdin)
    (define out (thread (lambda () (port->string stdout #:close? #t)) #:keep 'results))
    (define err (thread (lambda () (port->string stderr #:close? #t)) #:keep 'results))
    (cond
      [(sync/timeout 60 process)
       (values (subprocess-status process) (thread-wait out) (string-split (thread-wait err) "\n"))]
      [else
       (subprocess-kill process #t)
       (fail (format "~a: still running after 60 s; stderr: ~s" name (thread-wait err)))])))
