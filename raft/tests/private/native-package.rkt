#lang racket/base

(require (only-in racket/file make-directory*)
         (only-in racket/match match)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path
         (only-in setup/dirs find-collects-dir))

(provide call-with-native-package
         copy-loader!
         link-library)

(define-runtime-path loader-dir "../../private")
(define-runtime-path raft-dir "../..")

(define (copy-loader! root)
  (make-directory* (build-path root "private" "foreign"))
  (make-directory* (build-path root "native-libs"))
  (copy-file (build-path raft-dir "info.rkt") (build-path root "info.rkt"))
  (for ([module (in-list
                 '("exn.rkt" "install-native.rkt" "native-package.rkt" "foreign/library.rkt"))])
    (copy-file (build-path loader-dir module) (build-path root "private" module))))

(define ((link-library library) native-libs)
  (make-file-or-directory-link library (build-path native-libs "libraftrkt.so")))

(define (write-native-package! collects package)
  (match package
    [#f (void)]
    [(list version stage!)
     (define dir (build-path collects "raft-x86_64-linux"))
     (make-directory* (build-path dir "native-libs"))
     (copy-file (collection-file-path "main.rkt" "raft-x86_64-linux") (build-path dir "main.rkt"))
     (with-output-to-file (build-path dir "info.rkt")
                          (lambda ()
                            (write `(module info setup/infotab
                                      (define version ,version)))))
     (stage! (build-path dir "native-libs"))]))

(define (call-with-native-package collects package proc #:override (override #f))
  (make-directory* collects)
  (write-native-package! collects package)
  (parameterize ([current-namespace (make-base-namespace)]
                 [current-library-collection-links (list #f)]
                 [current-library-collection-paths (list collects (find-collects-dir))]
                 [current-environment-variables
                  (environment-variables-copy (current-environment-variables))])
    (environment-variables-set! (current-environment-variables)
                                #"RAFT_NATIVE_LIB_PATH"
                                (match override
                                  [#f #f]
                                  [(? path?) (path->bytes override)]
                                  [_ (string->bytes/utf-8 override)]))
    (proc)))
