#lang racket/base

(require (only-in ffi/unsafe cpointer-has-tag? cpointer? define-cpointer-type ffi-lib)
         (only-in ffi/unsafe/define define-ffi-definer)
         (only-in ffi/unsafe/define/conventions convention:hyphen->underscore)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path
         (only-in "../exn.rkt" exn:fail:raft)
         (only-in "../install-native.rkt" not-staged-advice staged?))

(provide define-raft
         native-library-error
         _rr-buffer
         _rr-buffer/null ;; noqa
         _rr-resources
         _rr-resources/null ;; noqa
         released-tag)

(define-runtime-path native-libs-dir "../../native-libs")

;; ffi-lib reports a missing file and a failed dlopen of a dependency alike.
(define (native-library-error staged where loader-message)
  (if staged
      (format
       "libraftrkt is staged but would not load\n  found in: ~a\n  the loader said: ~a\n  check that a CUDA 13 driver is installed and LD_LIBRARY_PATH holds no other CUDA"
       where
       loader-message)
      (format "libraftrkt is not staged\n  looked in: ~a\n  ~a" where not-staged-advice)))

(define native-library
  (with-handlers ([exn:fail? (lambda (e)
                               (error 'raft
                                      "~a"
                                      (native-library-error (staged? native-libs-dir)
                                                            (simplify-path native-libs-dir)
                                                            (exn-message e))))])
    (ffi-lib (build-path native-libs-dir "libraftrkt"))))

(define-ffi-definer define-raft native-library #:make-c-id convention:hyphen->underscore)

(define released-tag 'rr-released)

(define ((refuse-released what) handle)
  (when (and handle (cpointer? handle) (cpointer-has-tag? handle released-tag))
    (raise
     (exn:fail:raft (format "~a: used after its release" what) (current-continuation-marks) 'logic)))
  handle)

(define-cpointer-type _rr-resources #f (refuse-released 'device-resources) #f)
(define-cpointer-type _rr-buffer #f (refuse-released 'buffer) #f)
