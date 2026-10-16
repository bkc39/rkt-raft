#lang racket/base

(require (only-in ffi/unsafe ffi-lib)
         (only-in file/sha1 bytes->hex-string)
         (only-in json read-json)
         (only-in racket/file file->string)
         (only-in racket/list remove-duplicates)
         (only-in racket/path path-only)
         (only-in racket/string string-contains? string-prefix?))

(define native-package 'raft-x86_64-linux)
(define shipped '("libraftrkt.so" "librmm.so" "librapids_logger.so"))

(define failures 0)

(define (check ok? what)
  (cond
    [ok? (printf "ok   ~a\n" what)]
    [else
     (printf "FAIL ~a\n" what)
     (set! failures (add1 failures))]))

(define (mapped name)
  (define suffix (regexp (format "/~a$" (regexp-quote name))))
  (call-with-input-file "/proc/self/maps"
                        (lambda (in)
                          (remove-duplicates (for/list ([line (in-lines in)]
                                                        #:when (regexp-match? suffix line))
                                               (car (regexp-match #rx"/.*$" line)))))))

(define (file-sha256 path)
  (bytes->hex-string (call-with-input-file path sha256-bytes)))

(define (installed)
  (dynamic-require 'raft #f)
  (define native-libs (simplify-path (dynamic-require native-package 'native-libs-dir)))
  (define manifest (call-with-input-file (build-path native-libs 'up "manifest.json") read-json))
  (define raft-libs (build-path (path-only (collection-file-path "main.rkt" "raft")) "native-libs"))
  (printf "raft loaded; ~a holds its libraries in ~a\n" native-package native-libs)
  (check (not (directory-exists? raft-libs)) (format "nothing staged in ~a" raft-libs))
  (for ([name (in-list shipped)])
    (define want (path->string (build-path native-libs name)))
    (check (equal? (mapped name) (list want)) (format "~a mapped once, from ~a" name want))
    (check (equal? (file-sha256 want) (hash-ref (hash-ref manifest 'files) (string->symbol name)))
           (format "~a is the release build's, byte for byte" name)))
  (ffi-lib "librmm")
  (check (equal? (mapped "librmm.so") (list (path->string (build-path native-libs "librmm.so"))))
         "a later dlopen of librmm.so by name gets raft's copy"))

(define (load-failure)
  (with-handlers ([exn:fail? exn-message])
    (dynamic-require 'raft #f)
    #f))

(define (missing out)
  (define message (load-failure))
  (printf "(require raft) said:\n~a\n" message)
  (check (and message
              (string-prefix?
               message
               "raft: libraftrkt is not installed: the package raft-x86_64-linux is missing\n"))
         "the load failure names the missing package")
  (check (and message (string-contains? message "`raco pkg install raft-x86_64-linux`"))
         "and says how to install it")
  (with-output-to-file out #:exists 'truncate (lambda () (display (or message "")))))

(define (agree load-file setup-log)
  (define message (file->string load-file))
  (check (string-contains? (file->string setup-log) (string-append message "\n"))
         "the pre-installer printed the same message while raco setup ran"))

(module+ main
  (require (only-in racket/match match))
  (match (current-command-line-arguments)
    [(vector "installed") (installed)]
    [(vector "missing" out) (missing out)]
    [(vector "agree" load-file setup-log) (agree load-file setup-log)]
    [_
     (raise-user-error 'catalog-check
                       "usage: catalog-check.rkt installed | missing OUT | agree LOAD SETUP-LOG")])
  (exit (if (zero? failures) 0 1)))
