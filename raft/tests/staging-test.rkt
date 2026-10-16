#lang racket/base

(require (only-in racket/file delete-directory/files make-directory* make-temporary-directory)
         (only-in racket/list remove-duplicates)
         (only-in racket/match match-lambda)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path
         (only-in rackunit check-equal? check-false check-regexp-match test-case)
         (only-in setup/getinfo get-info get-info/full)
         (only-in "../private/install-native.rkt"
                  native-library-error
                  native-version-error
                  package-version)
         (only-in "../private/resource.rkt" with-release)
         (only-in "private/native-package.rkt" native-package pre-installer-output))

(define-runtime-path raft-dir "..")

(define raft-version (package-version raft-dir))

(define (write-lib! dir contents)
  (call-with-output-file (build-path dir "libraftrkt.so")
                         #:exists 'truncate
                         (lambda (out) (write-bytes contents out))))

(define (call-with-collection proc)
  (with-release ([collection (make-temporary-directory "raft-collection-~a") delete-directory/files])
    (proc collection)))

(test-case "each load failure reads differently"
  (define loader-said "libcublas.so.13: cannot open shared object file: No such file or directory")
  (define messages
    (for/hash ([kind (in-list '(missing broken override package unloadable))])
      (values kind (native-library-error kind "/x/native-libs" loader-said))))
  (check-equal? (length (remove-duplicates (hash-values messages))) (hash-count messages))
  (check-regexp-match #rx"looked in: /x/native-libs" (hash-ref messages 'missing))
  (check-regexp-match (regexp (regexp-quote (format "it said: ~a\n" loader-said)))
                      (hash-ref messages 'broken))
  (check-regexp-match (regexp (regexp-quote (format "the loader said: ~a\n" loader-said)))
                      (hash-ref messages 'unloadable)))

(test-case "a missing native package is named, the other failures advise a reinstall"
  (define (message kind)
    (native-library-error kind "/x/native-libs" "ignored" #:platform "x86_64-linux"))
  (check-regexp-match #rx"the package raft-x86_64-linux is missing" (message 'missing))
  (check-regexp-match #rx"`raco pkg install raft-x86_64-linux`" (message 'missing))
  (for ([kind (in-list '(broken package))])
    (check-regexp-match #rx"`raco pkg remove --force raft-x86_64-linux`" (message kind)))
  (check-regexp-match #rx"reinstall raft" (message 'unloadable))
  (check-regexp-match #rx"raft-x86_64-linux" (native-version-error "0.1" "0.2" "/x/native-libs"))
  (for ([text (in-list (list (message 'missing)
                             (message 'broken)
                             (message 'override)
                             (message 'package)
                             (message 'unloadable)
                             (native-version-error "0.1" "0.2" "/x/native-libs")))])
    (check-regexp-match #rx"RAFT_NATIVE_LIB_PATH|raco pkg update" text)
    (check-false (regexp-match? #rx"(?i:nix)" text))))

(test-case "off x86_64 Linux, the missing library is no package to install"
  (define message (native-library-error 'missing "/x/native-libs" #:platform "aarch64-macosx"))
  (check-regexp-match
   #rx"^libraftrkt is not installed: raft ships a native library for x86_64 Linux only, not aarch64-macosx\n"
   message)
  (check-regexp-match #rx"looked in: /x/native-libs" message)
  (check-regexp-match #rx"set RAFT_NATIVE_LIB_PATH" message)
  (check-false (regexp-match? #rx"raco pkg install" message)))

(test-case "with no native package the pre-installer prints what loading raft would raise"
  (call-with-collection
   (lambda (collection)
     (check-equal? (pre-installer-output collection void)
                   (format "raft: ~a\n"
                           (native-library-error 'missing
                                                 (simplify-path (build-path collection
                                                                            "native-libs"))))))))

(test-case "the pre-installer names a native package that holds no libraftrkt"
  (call-with-collection
   (lambda (collection)
     (check-regexp-match #rx"^raft: the package raft-x86_64-linux holds no libraftrkt\n"
                         (pre-installer-output collection (native-package raft-version void))))))

(test-case "the pre-installer prints the loader's message for a native package of another version"
  (call-with-collection
   (lambda (collection)
     (define package-libs
       (simplify-path (build-path collection "collects" "raft-x86_64-linux" "native-libs")))
     (check-equal? (pre-installer-output collection
                                         (native-package "0.1" (lambda (dir) (write-lib! dir #"v1"))))
                   (format "raft: ~a\n" (native-version-error "0.1" raft-version package-libs))))))

(test-case "the pre-installer is quiet when the native package holds libraftrkt"
  (call-with-collection
   (lambda (collection)
     (check-equal? (pre-installer-output collection
                                         (native-package raft-version
                                                         (lambda (dir) (write-lib! dir #"v1"))))
                   ""))))

(define (staged-output collection package)
  (make-directory* (build-path collection "native-libs"))
  (write-lib! (build-path collection "native-libs") #"v1")
  (pre-installer-output collection package))

(test-case "the pre-installer names a staged directory that hides the native package"
  (call-with-collection
   (lambda (collection)
     (check-equal?
      (staged-output collection (native-package raft-version (lambda (dir) (write-lib! dir #"v1"))))
      (format
       "raft: the staged directory ~a wins over the package raft-x86_64-linux; delete it to use the package\n"
       (simplify-path (build-path collection "native-libs")))))))

(test-case "the pre-installer is quiet about a staged directory with no native package"
  (call-with-collection (lambda (collection) (check-equal? (staged-output collection void) ""))))

(test-case "the pre-installer is quiet about a staged directory over an empty native package"
  (call-with-collection (lambda (collection)
                          (check-equal? (staged-output collection (native-package raft-version void))
                                        ""))))

(test-case "the pre-installer copies nothing from RAFT_NATIVE_LIB_PATH"
  (call-with-collection
   (lambda (collection)
     (define override (build-path collection "override"))
     (make-directory* (build-path override "lib"))
     (write-lib! (build-path override "lib") #"v1")
     (check-equal? (pre-installer-output collection void #:override (path->string override)) "")
     (check-false (directory-exists? (build-path collection "native-libs"))))))

(test-case "raft, its dependency on raft-x86_64-linux and that package carry one version"
  (define raft-info (get-info/full raft-dir))
  (define version (raft-info 'version))
  (define dependency
    (findf (match-lambda
             [(cons "raft-x86_64-linux" _) #t]
             [_ #f])
           (raft-info 'deps)))
  (check-equal? dependency `("raft-x86_64-linux" #:platform "x86_64-linux" #:version ,version))
  (check-equal? ((get-info '("raft-x86_64-linux")) 'version) version))
