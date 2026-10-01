#lang racket/base

(require (only-in racket/file delete-directory/files file->bytes make-temporary-directory)
         (only-in rackunit check-equal? check-false check-regexp-match check-true test-case)
         (only-in "../private/foreign/library.rkt" native-library-error)
         (only-in "../private/install-native.rkt" stage-native-libs! staged?)
         (only-in "../private/resource.rkt" with-release))

(define (call-with-dirs proc)
  (with-release ([root (make-temporary-directory "raft-staging-~a") delete-directory/files])
    (define src (build-path root "src"))
    (make-directory src)
    (proc src (build-path root "dst"))))

(define (write-lib! dir contents)
  (call-with-output-file (build-path dir "libraftrkt.so")
                         #:exists 'truncate
                         (lambda (out) (write-bytes contents out))))

(test-case "staging copies the library and nothing else"
  (call-with-dirs (lambda (src dst)
                    (write-lib! src #"v1")
                    (call-with-output-file (build-path src "README")
                                           (lambda (out) (write-string "x" out)))
                    (check-false (staged? dst))
                    (stage-native-libs! src dst)
                    (check-true (staged? dst))
                    (check-equal? (map path->string (directory-list dst)) '("libraftrkt.so"))
                    (check-equal? (file->bytes (build-path dst "libraftrkt.so")) #"v1"))))

(test-case "identical bytes are left in place"
  (call-with-dirs (lambda (src dst)
                    (write-lib! src #"v1")
                    (stage-native-libs! src dst)
                    (define staged (build-path dst "libraftrkt.so"))
                    (define before (file-or-directory-identity staged))
                    (stage-native-libs! src dst)
                    (check-equal? (file-or-directory-identity staged) before))))

(test-case "new bytes arrive by rename, never by rewriting the old file"
  (call-with-dirs (lambda (src dst)
                    (write-lib! src #"v1")
                    (stage-native-libs! src dst)
                    (define staged (build-path dst "libraftrkt.so"))
                    (define before (file-or-directory-identity staged))
                    (write-lib! src #"v2")
                    (stage-native-libs! src dst)
                    (check-equal? (file->bytes staged) #"v2")
                    (check-false (equal? (file-or-directory-identity staged) before))
                    (check-equal? (map path->string (directory-list dst)) '("libraftrkt.so")))))

(test-case "the two load failures read differently"
  (define absent (native-library-error #f "/x/native-libs" "ignored"))
  (define broken (native-library-error #t "/x/native-libs" "libcuda.so.1: cannot open"))
  (check-regexp-match #rx"is not staged" absent)
  (check-regexp-match #rx"looked in: /x/native-libs" absent)
  (check-regexp-match #rx"RAFT_NATIVE_LIB_PATH" absent)
  (check-regexp-match #rx"would not load" broken)
  (check-regexp-match #rx"libcuda.so.1: cannot open" broken))
