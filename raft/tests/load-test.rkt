#lang racket/base

(require (only-in racket/file delete-directory/files make-directory* make-temporary-directory)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path
         (only-in rackunit check-equal? check-pred check-regexp-match test-case)
         (only-in "../private/resource.rkt" with-release)
         (only-in "private/probe.rkt" probe-fixture probe-path test-host-probe))

(define-runtime-path loader-dir "../private")

(define (copy-loader! root)
  (make-directory* (build-path root "private" "foreign"))
  (make-directory (build-path root "native-libs"))
  (for ([module (in-list '("exn.rkt" "install-native.rkt" "foreign/library.rkt"))])
    (copy-file (build-path loader-dir module) (build-path root "private" module))))

(define ((link-library library) native-libs)
  (make-file-or-directory-link library (build-path native-libs "libraftrkt.so")))

(define (write-garbage native-libs)
  (call-with-output-file (build-path native-libs "libraftrkt.so")
                         (lambda (out) (write-bytes #"not a shared object" out))))

(define (consumer library)
  `(module consumer racket/base
     (require (only-in ffi/unsafe _fun _void)
              (file ,(path->string library)))
     (define-raft rr-holder-create (_fun -> _void))))

(define (load-failure stage!)
  (with-release ([root (make-temporary-directory "raft-load-~a") delete-directory/files])
    (copy-loader! root)
    (define native-libs (build-path root "native-libs"))
    (define exn-module (build-path root "private" "exn.rkt"))
    (stage! native-libs)
    (parameterize ([current-namespace (make-base-namespace)])
      (eval (consumer (build-path root "private" "foreign" "library.rkt")))
      (define raised
        (with-handlers ([exn:fail? values])
          (dynamic-require ''consumer #f)
          #f))
      (check-pred (dynamic-require exn-module 'exn:fail:raft?) raised)
      (check-equal? ((dynamic-require exn-module 'exn:fail:raft-kind) raised) 'generic)
      (values (exn-message raised) (path->string native-libs)))))

(define (path-line label where)
  (regexp (regexp-quote (format "\n  ~a: ~a\n" label where))))

(test-case "an unstaged library is refused with where it looked"
  (define-values (message where) (load-failure void))
  (check-regexp-match #rx"^raft: libraftrkt is not staged\n" message)
  (check-regexp-match (path-line "looked in" where) message)
  (check-regexp-match #rx"reinstall raft" message))

(test-case "a staged file that will not load is refused with the loader's message"
  (define-values (message where) (load-failure write-garbage))
  (check-regexp-match #rx"^raft: libraftrkt is staged but would not load\n" message)
  (check-regexp-match (path-line "found in" where) message)
  (check-regexp-match #rx"the loader said: .*libraftrkt[.]so" message))

(test-host-probe "a library of another ABI version is refused with both versions and its path"
  (define-values (message where)
    (load-failure (link-library (probe-fixture "libraftrkt_stale_abi.so"))))
  (check-regexp-match #rx"^raft: libraftrkt has ABI version 2, but this raft needs ABI version 1\n"
                      message)
  (check-regexp-match (path-line "found in" where) message)
  (check-regexp-match #rx"reinstall raft" message))

(test-host-probe "a library with no rr_abi is refused before define-raft resolves a symbol"
  (define-values (message _where) (load-failure (link-library probe-path)))
  (check-regexp-match #rx"^raft: libraftrkt has no ABI version, but this raft needs ABI version 1\n"
                      message))

(test-host-probe "an rr_abi that returns NULL is no ABI version"
  (define-values (message _where)
    (load-failure (link-library (probe-fixture "libraftrkt_null_abi.so"))))
  (check-regexp-match #rx"^raft: libraftrkt has no ABI version, but this raft needs ABI version 1\n"
                      message))

(test-host-probe "a library of this ABI version that lacks an export is named older than raft"
  (define-values (message where)
    (load-failure (link-library (probe-fixture "libraftrkt_abi_only.so"))))
  (check-regexp-match
   #rx"^raft: libraftrkt lacks the export for rr-holder-create, so it is older than this raft\n"
   message)
  (check-regexp-match (path-line "found in" where) message)
  (check-regexp-match #rx"reinstall raft" message))
