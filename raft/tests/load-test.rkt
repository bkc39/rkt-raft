#lang racket/base

(require (only-in racket/file delete-directory/files make-directory* make-temporary-directory)
         (only-in racket/match match)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path
         (only-in rackunit check-equal? check-false check-pred check-regexp-match test-case)
         (only-in "../private/foreign/library.rkt" native-library-dir)
         (only-in "../private/install-native.rkt"
                  native-library-error
                  native-version-error
                  package-version
                  pre-installer)
         (only-in "../private/resource.rkt" with-release)
         (only-in "private/native-package.rkt"
                  call-with-native-package
                  copy-loader!
                  link-library
                  native-package)
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

(define (override-value override root)
  (match override
    [#f #f]
    ["" ""]
    [stage!
     (define dir (build-path root "override"))
     (make-directory* (build-path dir "lib"))
     (stage! (build-path dir "lib"))
     (path->string dir)]))

(define (load-outcome #:override (override #f) #:staged [stage! void] #:package [package void])
  (with-release ([root (make-temporary-directory "raft-load-~a") delete-directory/files])
    (copy-loader! root)
    (make-directory* (build-path root "native-libs"))
    (stage! (build-path root "native-libs"))
    (define exn-module (build-path root "private" "exn.rkt"))
    (define (finish loaded-from message)
      (outcome loaded-from
               message
               (path->string (build-path root "native-libs"))
               (path->string (build-path root "override" "lib"))
               (path->string (build-path root "collects" "raft-x86_64-linux" "native-libs"))))
    (call-with-native-package (build-path root "collects")
                              package
                              #:override (override-value override root)
                              (lambda ()
                                (eval (consumer (build-path root "private" "foreign" "library.rkt")))
                                (match (with-handlers ([exn:fail? values])
                                         (dynamic-require ''consumer 'native-library-dir))
                                  [(? exn? e)
                                   (check-pred (dynamic-require exn-module 'exn:fail:raft?) e)
                                   (check-equal? ((dynamic-require exn-module 'exn:fail:raft-kind) e)
                                                 'generic)
                                   (finish #f (exn-message e))]
                                  [dir (finish (path->string dir) #f)])))))

(define ((pre-install-with-override library) native-libs)
  (define collection (simplify-path (build-path native-libs 'up)))
  (define override (build-path collection "pre-install-override"))
  (make-directory* (build-path override "lib"))
  ((link-library library) (build-path override "lib"))
  (parameterize ([current-environment-variables
                  (environment-variables-copy (current-environment-variables))])
    (putenv "RAFT_NATIVE_LIB_PATH" (path->string override))
    (pre-installer #f collection #f)))

(define (path-line label where)
  (regexp (regexp-quote (format "\n  ~a: ~a\n" label where))))

(test-case "the loader's runtime files are raft's info.rkt and native-libs, not the collection"
  (check-equal? (sort (runtime-paths "../private/foreign/library.rkt") string<?)
                '("../../info.rkt" "../../native-libs")))

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
  (define o (load-outcome #:package (native-package raft-version (link-library real-library))))
  (check-equal? (outcome-loaded-from o) (outcome-package o)))

(test-case "a staged library wins over the native package's"
  (define o
    (load-outcome #:staged (link-library real-library)
                  #:package (native-package raft-version write-garbage)))
  (check-equal? (outcome-loaded-from o) (outcome-staged o)))

(test-case "RAFT_NATIVE_LIB_PATH wins over the staged library and the native package's"
  (define o
    (load-outcome #:override (link-library real-library)
                  #:staged write-garbage
                  #:package (native-package raft-version write-garbage)))
  (check-equal? (outcome-loaded-from o) (outcome-override o)))

(test-case "an empty RAFT_NATIVE_LIB_PATH is no override"
  (define o
    (load-outcome #:override "" #:package (native-package raft-version (link-library real-library))))
  (check-equal? (outcome-loaded-from o) (outcome-package o)))

(test-case "RAFT_NATIVE_LIB_PATH naming a directory with no libraftrkt is refused"
  (define o
    (load-outcome #:override void
                  #:package (native-package raft-version (link-library real-library))))
  (check-regexp-match #rx"^raft: libraftrkt is not where RAFT_NATIVE_LIB_PATH points\n"
                      (outcome-message o))
  (check-regexp-match (path-line "looked in" (outcome-override o)) (outcome-message o)))

(test-case "a native package with no libraftrkt is refused with where it looked"
  (define o (load-outcome #:package (native-package raft-version void)))
  (check-regexp-match #rx"^raft: the package raft-x86_64-linux holds no libraftrkt\n"
                      (outcome-message o))
  (check-regexp-match (path-line "looked in" (outcome-package o)) (outcome-message o))
  (check-regexp-match #rx"reinstall raft" (outcome-message o)))

(test-case "a native package of another version is refused before its library loads"
  (define o (load-outcome #:package (native-package "0.1" write-garbage)))
  (check-equal? (outcome-message o)
                (format "raft: ~a" (native-version-error "0.1" raft-version (outcome-package o))))
  (check-regexp-match
   (regexp
    (regexp-quote
     (format "raft: the package raft-x86_64-linux is version 0.1, but this raft is version ~a\n"
             raft-version)))
   (outcome-message o))
  (check-regexp-match (path-line "found in" (outcome-package o)) (outcome-message o))
  (check-regexp-match #rx"`raco pkg update raft raft-x86_64-linux`" (outcome-message o)))

(test-case "a pre-install with RAFT_NATIVE_LIB_PATH set leaves a later load to the native package"
  (define o
    (load-outcome #:staged (pre-install-with-override real-library)
                  #:package (native-package raft-version (link-library real-library))))
  (check-equal? (outcome-loaded-from o) (outcome-package o)))

(define (broken-package-message package)
  (define o (load-outcome #:package package))
  (check-regexp-match #rx"^raft: the package raft-x86_64-linux is installed but would not load\n"
                      (outcome-message o))
  (check-false (regexp-match? #rx"is missing" (outcome-message o)))
  (outcome-message o))

(test-case "a registered native package with no main.rkt is named broken, with the cause"
  (check-regexp-match #rx"it said: .*main[.]rkt"
                      (broken-package-message
                       (native-package raft-version (link-library real-library) #:main #f))))

(test-case "a native package whose main.rkt lacks native-libs-dir is named broken, with the cause"
  (check-regexp-match #rx"it said: .*native-libs-dir"
                      (broken-package-message (native-package raft-version
                                                              (link-library real-library)
                                                              #:main '(module main racket/base
                                                                        )))))

(test-case "a native package whose info.rkt will not evaluate is named broken, with the cause"
  (check-regexp-match #rx"it said: .*define"
                      (broken-package-message (native-package raft-version
                                                              (link-library real-library)
                                                              #:info '(module info setup/infotab
                                                                        (define version))))))

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
