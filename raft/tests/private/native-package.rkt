#lang racket/base

(require (only-in racket/file make-directory*)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path
         (only-in setup/dirs find-collects-dir))

(provide call-with-native-package
         copy-loader!
         link-library
         native-package
         pre-installer-output)

(define-runtime-path loader-dir "../../private")
(define-runtime-path raft-dir "../..")

(define (copy-loader! root)
  (make-directory* (build-path root "private" "foreign"))
  (copy-file (build-path raft-dir "info.rkt") (build-path root "info.rkt"))
  (for ([module (in-list '("exn.rkt" "install-native.rkt" "foreign/library.rkt"))])
    (copy-file (build-path loader-dir module) (build-path root "private" module))))

(define ((link-library library) native-libs)
  (make-file-or-directory-link library (build-path native-libs "libraftrkt.so")))

(define (write-form path form)
  (with-output-to-file path (lambda () (write form))))

(define ((native-package version
                         stage!
                         #:main [main (collection-file-path "main.rkt" "raft-x86_64-linux")]
                         #:info [info
                                 `(module info setup/infotab
                                    (define version ,version))])
         collects)
  (define dir (build-path collects "raft-x86_64-linux"))
  (make-directory* (build-path dir "native-libs"))
  (cond
    [(path? main) (copy-file main (build-path dir "main.rkt"))]
    [main (write-form (build-path dir "main.rkt") main)]
    [else (void)])
  (write-form (build-path dir "info.rkt") info)
  (stage! (build-path dir "native-libs")))

(define (call-with-native-package collects package proc #:override (override #f))
  (make-directory* collects)
  (package collects)
  (parameterize ([current-namespace (make-base-namespace)]
                 [current-library-collection-links (list #f)]
                 [current-library-collection-paths (list collects (find-collects-dir))]
                 [current-environment-variables
                  (environment-variables-copy (current-environment-variables))])
    (environment-variables-set! (current-environment-variables)
                                #"RAFT_NATIVE_LIB_PATH"
                                (and override (string->bytes/utf-8 override)))
    (proc)))

(define (pre-installer-output collection package #:override (override #f))
  (define errors (open-output-string))
  (copy-loader! collection)
  (call-with-native-package
   (build-path collection "collects")
   package
   #:override override
   (lambda ()
     (parameterize ([current-error-port errors])
       ((dynamic-require (build-path collection "private" "install-native.rkt") 'pre-installer)
        #f
        collection
        #f))))
  (get-output-string errors))
