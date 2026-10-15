#lang racket/base

(require (only-in ffi/unsafe
                  _fun
                  _int32
                  _pointer
                  cpointer-has-tag?
                  cpointer?
                  define-cpointer-type
                  ffi-lib
                  get-ffi-obj
                  ptr-ref)
         (only-in ffi/unsafe/define define-ffi-definer)
         (only-in ffi/unsafe/define/conventions convention:hyphen->underscore)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path
         (only-in "../exn.rkt" raise-raft)
         (only-in "../install-native.rkt" native-library-advice staged?))

(provide abi-version
         define-raft
         native-library-error
         open-native-library
         _raft-handle/null ;; noqa
         _rr-buffer
         _rr-buffer/null ;; noqa
         _rr-deposit/null ;; noqa
         _rr-holder
         _rr-holder/null ;; noqa
         _rr-job
         _rr-job/null ;; noqa
         _rr-resources
         _rr-resources/null ;; noqa
         released-tag)

(define-runtime-path native-libs-dir "../../native-libs")

;; ffi-lib reports a missing file and a failed dlopen of a dependency alike.
(define (native-library-error staged where loader-message)
  (if staged
      (format
       "libraftrkt is staged but would not load\n  found in: ~a\n  the loader said: ~a\n  check that LD_LIBRARY_PATH holds no other CUDA, or ~a"
       where
       loader-message
       native-library-advice)
      (format "libraftrkt is not staged\n  looked in: ~a\n  ~a" where native-library-advice)))

(define abi-version 1)

(define (library-abi-version library)
  (define tag (get-ffi-obj "rr_abi" library (_fun -> _pointer) (lambda () #f)))
  (and tag (ptr-ref (tag) _int32)))

(define (abi-mismatch-error where found)
  (format "libraftrkt ~a, but this raft needs ABI version ~a\n  found in: ~a\n  ~a"
          (if found
              (format "has ABI version ~a" found)
              "has no ABI version (it exports no rr_abi)")
          abi-version
          where
          native-library-advice))

;; The handshake runs before any define-raft resolves a symbol, so a stale
;; library is named as stale rather than by the first export it lacks.
(define (open-native-library dir)
  (define where (simplify-path dir))
  (define library
    (with-handlers
        ([exn:fail? (lambda (e)
                      (error 'raft "~a" (native-library-error (staged? dir) where (exn-message e))))])
      (ffi-lib (build-path dir "libraftrkt"))))
  (define found (library-abi-version library))
  (cond
    [(eqv? found abi-version) library]
    [else (error 'raft "~a" (abi-mismatch-error where found))]))

(define native-library (open-native-library native-libs-dir))

(define-ffi-definer define-raft native-library #:make-c-id convention:hyphen->underscore)

(define released-tag 'rr-released)

(define ((refuse-released what) handle)
  (when (and handle (cpointer? handle) (cpointer-has-tag? handle released-tag))
    (raise-raft what 'logic "used after its release"))
  handle)

(define-cpointer-type _rr-resources #f (refuse-released 'device-resources) #f)
(define-cpointer-type _rr-buffer #f (refuse-released 'device-array) #f)
(define-cpointer-type _rr-holder #f (refuse-released 'deposit) #f)
(define-cpointer-type _rr-job #f (refuse-released 'job) #f)
(define-cpointer-type _raft-handle)
(define-cpointer-type _rr-deposit)
