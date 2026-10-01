#lang racket/base

(require (only-in racket/file delete-directory/files file->bytes make-temporary-directory)
         (only-in rackunit check-equal? check-false check-true test-case)
         (only-in "../private/foreign/library.rkt" native-library-error)
         (only-in "../private/install-native.rkt" stage-native-libs!))

(define (call-with-dirs proc)
  (define root (make-temporary-directory "raft-staging-~a"))
  (dynamic-wind
   void
   (lambda ()
     (define src (build-path root "src"))
     (define dst (build-path root "dst"))
     (make-directory src)
     (proc src dst))
   (lambda () (delete-directory/files root))))

(define (write-lib! dir bytes)
  (call-with-output-file (build-path dir "libraftrkt.so") #:exists 'truncate
    (lambda (out) (write-bytes bytes out))))

(define (inode path)
  (file-or-directory-identity path))

(test-case "staging copies the library and nothing else"
  (call-with-dirs
   (lambda (src dst)
     (write-lib! src #"v1")
     (call-with-output-file (build-path src "README") (lambda (out) (write-string "x" out)))
     (stage-native-libs! src dst)
     (check-equal? (map path->string (directory-list dst)) '("libraftrkt.so"))
     (check-equal? (file->bytes (build-path dst "libraftrkt.so")) #"v1"))))

(test-case "identical bytes are left in place"
  (call-with-dirs
   (lambda (src dst)
     (write-lib! src #"v1")
     (stage-native-libs! src dst)
     (define before (inode (build-path dst "libraftrkt.so")))
     (stage-native-libs! src dst)
     (check-equal? (inode (build-path dst "libraftrkt.so")) before))))

(test-case "new bytes arrive by rename, never by rewriting the old file"
  (call-with-dirs
   (lambda (src dst)
     (write-lib! src #"v1")
     (stage-native-libs! src dst)
     (define staged (build-path dst "libraftrkt.so"))
     (define before (inode staged))
     (write-lib! src #"v2")
     (stage-native-libs! src dst)
     (check-equal? (file->bytes staged) #"v2")
     (check-false (equal? (inode staged) before))
     (check-equal? (map path->string (directory-list dst)) '("libraftrkt.so")))))

(test-case "the two load failures read differently"
  (define absent (native-library-error #f "/x/native-libs" "ignored"))
  (define broken (native-library-error #t "/x/native-libs" "libcuda.so.1: cannot open"))
  (check-true (regexp-match? #rx"is not staged" absent))
  (check-true (regexp-match? #rx"looked in: /x/native-libs" absent))
  (check-true (regexp-match? #rx"would not load" broken))
  (check-true (regexp-match? #rx"libcuda.so.1: cannot open" broken)))
