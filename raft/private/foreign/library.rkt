#lang racket/base

(require (only-in ffi/unsafe define-cpointer-type ffi-lib)
         (only-in ffi/unsafe/define define-ffi-definer)
         (only-in ffi/unsafe/define/conventions convention:hyphen->underscore)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path)

(provide define-raft
         native-library-error
         _rr-buffer
         _rr-buffer/null
         _rr-resources
         _rr-resources/null)

(define-runtime-path native-libs-dir "../../native-libs")

(define (staged? dir)
  (and (directory-exists? dir)
       (for/or ([f (in-list (directory-list dir))])
         (regexp-match? #rx"^libraftrkt[.]" (path->string f)))))

;; ffi-lib reports a missing file and a failed dlopen of a dependency alike.
(define (native-library-error staged where loader-message)
  (if staged
      (format "libraftrkt is staged but would not load\n  found in: ~a\n  the loader said: ~a\n  check that a CUDA 13 driver is installed and LD_LIBRARY_PATH holds no other CUDA"
              where loader-message)
      (format "libraftrkt is not staged\n  looked in: ~a\n  build it with nix (`nix develop` stages it), or set RAFT_NATIVE_LIB_PATH to a directory whose lib/ holds it and reinstall"
              where)))

(define native-library
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (error 'raft "~a"
                            (native-library-error (staged? native-libs-dir)
                                                  (simplify-path native-libs-dir)
                                                  (exn-message e))))])
    (ffi-lib (build-path native-libs-dir "libraftrkt"))))

(define-ffi-definer define-raft native-library
  #:make-c-id convention:hyphen->underscore)

(define-cpointer-type _rr-resources)
(define-cpointer-type _rr-buffer)
