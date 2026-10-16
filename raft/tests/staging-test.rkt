#lang racket/base

(require (only-in racket/file delete-directory/files file->bytes make-temporary-directory)
         (only-in racket/list remove-duplicates)
         (only-in racket/match match match-define)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path
         (only-in rackunit check-equal? check-false check-regexp-match check-true test-case)
         (only-in setup/getinfo get-info get-info/full)
         (only-in "../private/install-native.rkt"
                  native-library-error
                  native-version-error
                  stage-native-libs!
                  staged?)
         (only-in "../private/resource.rkt" with-release)
         (only-in "private/native-package.rkt" call-with-native-package copy-loader!))

(define-runtime-path raft-dir "..")

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

(test-case "each load failure reads differently"
  (define loader-said "libcublas.so.13: cannot open shared object file: No such file or directory")
  (define messages
    (for/list ([kind (in-list '(missing override package unloadable))])
      (native-library-error kind "/x/native-libs" loader-said)))
  (match-define (list missing _ _ unloadable) messages)
  (check-equal? (length (remove-duplicates messages)) 4)
  (check-regexp-match #rx"looked in: /x/native-libs" missing)
  (check-regexp-match (regexp (regexp-quote (format "the loader said: ~a\n" loader-said)))
                      unloadable))

(test-case "a missing native package is named, the other failures advise a reinstall of raft"
  (define (message kind)
    (native-library-error kind "/x/native-libs" "ignored"))
  (check-regexp-match #rx"the package raft-x86_64-linux is missing" (message 'missing))
  (check-regexp-match #rx"`raco pkg install raft-x86_64-linux`" (message 'missing))
  (for ([kind (in-list '(package unloadable))])
    (check-regexp-match #rx"reinstall raft" (message kind)))
  (check-regexp-match #rx"raft-x86_64-linux" (native-version-error "0.1" "0.2" "/x/native-libs"))
  (for ([text (in-list (list (message 'missing)
                             (message 'override)
                             (message 'package)
                             (message 'unloadable)
                             (native-version-error "0.1" "0.2" "/x/native-libs")))])
    (check-regexp-match #rx"RAFT_NATIVE_LIB_PATH|raco pkg update" text)
    (check-false (regexp-match? #rx"(?i:nix)" text))))

(define (pre-installer-output collection package)
  (define errors (open-output-string))
  (copy-loader! collection)
  (call-with-native-package
   (build-path collection "collects")
   package
   (lambda ()
     (parameterize ([current-error-port errors])
       ((dynamic-require (build-path collection "private" "install-native.rkt") 'pre-installer)
        #f
        collection
        #f))))
  (get-output-string errors))

(test-case "with no native package the pre-installer prints what loading raft would raise"
  (with-release ([collection (make-temporary-directory "raft-collection-~a") delete-directory/files])
    (check-equal? (pre-installer-output collection #f)
                  (format "raft: ~a\n"
                          (native-library-error 'missing
                                                (simplify-path (build-path collection "native-libs"))
                                                #f)))))

(test-case "the pre-installer names a native package that holds no libraftrkt"
  (with-release ([collection (make-temporary-directory "raft-collection-~a") delete-directory/files])
    (check-regexp-match #rx"^raft: the package raft-x86_64-linux holds no libraftrkt\n"
                        (pre-installer-output collection (list "0.2" void)))))

(test-case "the pre-installer is quiet when the native package holds libraftrkt"
  (with-release ([collection (make-temporary-directory "raft-collection-~a") delete-directory/files])
    (check-equal? (pre-installer-output collection (list "0.2" (lambda (dir) (write-lib! dir #"v1"))))
                  "")))

(test-case "raft, its dependency on raft-x86_64-linux and that package carry one version"
  (define raft-info (get-info/full raft-dir))
  (define version (raft-info 'version))
  (define dependency
    (for/first ([dep (in-list (raft-info 'deps))]
                #:when (match dep
                         [(cons "raft-x86_64-linux" _) #t]
                         [_ #f]))
      dep))
  (check-equal? dependency `("raft-x86_64-linux" #:platform "x86_64-linux" #:version ,version))
  (check-equal? ((get-info '("raft-x86_64-linux")) 'version) version))
