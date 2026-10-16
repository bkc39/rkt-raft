#lang racket/base

(require (only-in ffi/unsafe ffi-lib)
         (only-in file/sha1 bytes->hex-string)
         (only-in json read-json)
         (only-in racket/file file->string)
         (only-in racket/list append* remove-duplicates)
         (only-in racket/path path-only)
         (only-in racket/string string-contains? string-prefix?))

(define native-package 'raft-x86_64-linux)
(define shipped '("libraftrkt.so" "librmm.so" "librapids_logger.so"))
(define cublas '("libcublas.so.13" "libcublasLt.so.13"))

(define (check ok? what)
  (printf "~a ~a\n" (if ok? "ok  " "FAIL") what)
  (if ok?
      '()
      (list what)))

(define (mapped name)
  (define suffix (regexp (format "/~a$" (regexp-quote name))))
  (call-with-input-file "/proc/self/maps"
                        (lambda (in)
                          (remove-duplicates (for/list ([line (in-lines in)]
                                                        #:when (regexp-match? suffix line))
                                               (car (regexp-match #rx"/.*$" line)))))))

(define (mapped-from? name dir)
  (check (equal? (mapped name) (list (path->string (build-path dir name))))
         (format "~a mapped once, from ~a" name dir)))

(define (file-sha256 path)
  (bytes->hex-string (call-with-input-file path sha256-bytes)))

(define (installed cublas-dir)
  (dynamic-require 'raft #f)
  (define native-libs (simplify-path (dynamic-require native-package 'native-libs-dir)))
  (define manifest (call-with-input-file (build-path native-libs 'up "manifest.json") read-json))
  (define raft-libs (build-path (path-only (collection-file-path "main.rkt" "raft")) "native-libs"))
  (printf "raft loaded; ~a holds its libraries in ~a\n" native-package native-libs)
  (define loaded
    (append (check (not (directory-exists? raft-libs)) (format "nothing staged in ~a" raft-libs))
            (append* (for/list ([name (in-list shipped)])
                       (append (mapped-from? name native-libs)
                               (check (equal? (file-sha256 (build-path native-libs name))
                                              (hash-ref (hash-ref manifest 'files)
                                                        (string->symbol name)))
                                      (format "~a is the release build's, byte for byte" name)))))
            (append* (for/list ([name (in-list cublas)])
                       (mapped-from? name cublas-dir)))))
  (ffi-lib "librmm")
  (append loaded
          (check (equal? (mapped "librmm.so")
                         (list (path->string (build-path native-libs "librmm.so"))))
                 "a later dlopen of librmm.so by name gets raft's copy")))

(define (load-failure)
  (with-handlers ([exn:fail? exn-message])
    (dynamic-require 'raft #f)
    ""))

(define (missing out)
  (define message (load-failure))
  (printf "(require raft) said:\n~a\n" message)
  (with-output-to-file out #:exists 'truncate (lambda () (display message)))
  (append (check (string-prefix?
                  message
                  "raft: libraftrkt is not installed: the package raft-x86_64-linux is missing\n")
                 "the load failure names the missing package")
          (check (string-contains? message "`raco pkg install raft-x86_64-linux`")
                 "and says how to install it")))

(define (cuda-missing)
  (define message (load-failure))
  (printf "(require raft) said:\n~a\n" message)
  (append (check (string-prefix? message "raft: cuBLAS from CUDA 13 is not installed: ")
                 "the load failure names the missing cuBLAS")
          (check (string-contains? message "`racket -l- raft/fetch-cuda`")
                 "and the command that fetches it")
          (check (string-contains? message "RAFT_CUDA_LIB_PATH") "and the override")))

(define (setup status load-file setup-log)
  (define log (file->string setup-log))
  (append (check (equal? status "0") (format "raco setup --pkgs raft exited 0 (got ~a)" status))
          (check (not (string-contains? log "collection not found"))
                 "raco setup found no reference to a missing collection")
          (check (string-contains? log (string-append (file->string load-file) "\n"))
                 "the pre-installer printed the same message while raco setup ran")))

(module+ main
  (require (only-in racket/match match))
  (define failures
    (match (current-command-line-arguments)
      [(vector "installed" cublas-dir) (installed cublas-dir)]
      [(vector "missing" out) (missing out)]
      [(vector "cuda-missing") (cuda-missing)]
      [(vector "setup" status load-file setup-log) (setup status load-file setup-log)]
      [_
       (raise-user-error
        'catalog-check
        "usage: catalog-check.rkt installed CUBLAS-DIR | missing OUT | cuda-missing | setup STATUS LOAD SETUP-LOG")]))
  (exit (if (null? failures) 0 1)))
