#lang racket/base

(require (only-in racket/file delete-directory/files make-directory* make-temporary-directory)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path
         (only-in rackunit check-equal? check-pred check-regexp-match test-case)
         (only-in "../private/foreign/library.rkt" native-library-dir)
         (only-in "../private/install-native.rkt" native-library-error package-version)
         (only-in "../private/resource.rkt" with-release)
         (only-in "private/native-package.rkt" call-with-native-package copy-loader! link-library)
         (only-in "private/probe.rkt" probe-fixture probe-path test-host-probe))

(define-runtime-path raft-dir "..")

(define real-library (build-path native-library-dir "libraftrkt.so"))
(define raft-version (package-version raft-dir))

(define (write-garbage native-libs)
  (call-with-output-file (build-path native-libs "libraftrkt.so")
                         (lambda (out) (write-bytes #"not a shared object" out))))

(define (consumer library)
  `(module consumer racket/base
     (require (only-in ffi/unsafe _fun _void)
              (file ,(path->string library)))
     (provide native-library-dir)
     (define-raft rr-holder-create (_fun -> _void))))

(struct outcome (loaded-from message staged override package))

(define (load-outcome #:override [override! #f]
                      #:override-value [override-value #f]
                      #:staged [stage! void]
                      #:package [package #f])
  (with-release ([root (make-temporary-directory "raft-load-~a") delete-directory/files])
    (copy-loader! root)
    (make-directory* (build-path root "override" "lib"))
    (define override (build-path root "override"))
    (define exn-module (build-path root "private" "exn.rkt"))
    (stage! (build-path root "native-libs"))
    (when override!
      (override! (build-path override "lib")))
    (call-with-native-package
     (build-path root "collects")
     package
     #:override (or override-value (and override! override))
     (lambda ()
       (eval (consumer (build-path root "private" "foreign" "library.rkt")))
       (define loaded
         (with-handlers ([exn:fail? values])
           (dynamic-require ''consumer 'native-library-dir)))
       (define raised (and (exn? loaded) loaded))
       (when raised
         (check-pred (dynamic-require exn-module 'exn:fail:raft?) raised)
         (check-equal? ((dynamic-require exn-module 'exn:fail:raft-kind) raised) 'generic))
       (outcome (and (not raised) (path->string loaded))
                (and raised (exn-message raised))
                (path->string (build-path root "native-libs"))
                (path->string (build-path override "lib"))
                (path->string (build-path root "collects" "raft-x86_64-linux" "native-libs")))))))

(define (path-line label where)
  (regexp (regexp-quote (format "\n  ~a: ~a\n" label where))))

(test-case "with nothing staged and no native package, the message names the package to install"
  (define o (load-outcome))
  (check-equal? (outcome-message o)
                (format "raft: ~a" (native-library-error 'missing (outcome-staged o) #f)))
  (check-regexp-match
   #rx"^raft: libraftrkt is not installed: the package raft-x86_64-linux is missing\n"
   (outcome-message o))
  (check-regexp-match (path-line "looked in" (outcome-staged o)) (outcome-message o))
  (check-regexp-match #rx"`raco pkg install raft-x86_64-linux`" (outcome-message o)))

(test-case "the native package's library loads when nothing overrides it"
  (define o (load-outcome #:package (list raft-version (link-library real-library))))
  (check-equal? (outcome-loaded-from o) (outcome-package o)))

(test-case "a staged library wins over the native package's"
  (define o
    (load-outcome #:staged (link-library real-library) #:package (list raft-version write-garbage)))
  (check-equal? (outcome-loaded-from o) (outcome-staged o)))

(test-case "RAFT_NATIVE_LIB_PATH wins over the staged library and the native package's"
  (define o
    (load-outcome #:override (link-library real-library)
                  #:staged write-garbage
                  #:package (list raft-version write-garbage)))
  (check-equal? (outcome-loaded-from o) (outcome-override o)))

(test-case "an empty RAFT_NATIVE_LIB_PATH is no override"
  (define o
    (load-outcome #:override-value "" #:package (list raft-version (link-library real-library))))
  (check-equal? (outcome-loaded-from o) (outcome-package o)))

(test-case "RAFT_NATIVE_LIB_PATH naming a directory with no libraftrkt is refused"
  (define o (load-outcome #:override void #:package (list raft-version (link-library real-library))))
  (check-regexp-match #rx"^raft: libraftrkt is not where RAFT_NATIVE_LIB_PATH points\n"
                      (outcome-message o))
  (check-regexp-match (path-line "looked in" (outcome-override o)) (outcome-message o)))

(test-case "a native package with no libraftrkt is refused with where it looked"
  (define o (load-outcome #:package (list raft-version void)))
  (check-regexp-match #rx"^raft: the package raft-x86_64-linux holds no libraftrkt\n"
                      (outcome-message o))
  (check-regexp-match (path-line "looked in" (outcome-package o)) (outcome-message o))
  (check-regexp-match #rx"reinstall raft" (outcome-message o)))

(test-case "a native package of another version is refused before its library loads"
  (define o (load-outcome #:package (list "0.1" write-garbage)))
  (check-regexp-match
   (regexp
    (regexp-quote
     (format "raft: the package raft-x86_64-linux is version 0.1, but this raft is version ~a\n"
             raft-version)))
   (outcome-message o))
  (check-regexp-match (path-line "found in" (outcome-package o)) (outcome-message o))
  (check-regexp-match #rx"`raco pkg update raft raft-x86_64-linux`" (outcome-message o)))

(test-case "a staged file that will not load is refused with the loader's message"
  (define o (load-outcome #:staged write-garbage))
  (check-regexp-match #rx"^raft: libraftrkt was found but would not load\n" (outcome-message o))
  (check-regexp-match (path-line "found in" (outcome-staged o)) (outcome-message o))
  (check-regexp-match #rx"the loader said: .*libraftrkt[.]so" (outcome-message o)))

(test-host-probe "a library of another ABI version is refused with both versions and its path"
  (define o (load-outcome #:staged (link-library (probe-fixture "libraftrkt_stale_abi.so"))))
  (check-regexp-match #rx"^raft: libraftrkt has ABI version 2, but this raft needs ABI version 1\n"
                      (outcome-message o))
  (check-regexp-match (path-line "found in" (outcome-staged o)) (outcome-message o))
  (check-regexp-match #rx"reinstall raft" (outcome-message o)))

(test-host-probe "a library with no rr_abi is refused before define-raft resolves a symbol"
  (define o (load-outcome #:staged (link-library probe-path)))
  (check-regexp-match #rx"^raft: libraftrkt has no ABI version, but this raft needs ABI version 1\n"
                      (outcome-message o)))

(test-host-probe "an rr_abi that returns NULL is no ABI version"
  (define o (load-outcome #:staged (link-library (probe-fixture "libraftrkt_null_abi.so"))))
  (check-regexp-match #rx"^raft: libraftrkt has no ABI version, but this raft needs ABI version 1\n"
                      (outcome-message o)))

(test-host-probe "a library of this ABI version that lacks an export is named older than raft"
  (define o (load-outcome #:staged (link-library (probe-fixture "libraftrkt_abi_only.so"))))
  (check-regexp-match
   #rx"^raft: libraftrkt lacks the export for rr-holder-create, so it is older than this raft\n"
   (outcome-message o))
  (check-regexp-match (path-line "found in" (outcome-staged o)) (outcome-message o))
  (check-regexp-match #rx"reinstall raft" (outcome-message o)))
