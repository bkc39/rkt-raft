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
         (only-in racket/match match match*)
         (only-in racket/path path-only)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path
         (only-in "../cublas.rkt" cublas-error cublas-libraries cublas-location locate-cublas)
         (only-in "../cuda-wheels.rkt" cuda-wheel-roots)
         (only-in "../exn.rkt" raise-raft)
         (only-in "../install-native.rkt"
                  locate-native-library
                  native-library-advice
                  native-library-error
                  native-library-problem
                  native-location-dir
                  native-location-kind
                  package-version))

(provide define-raft
         ensure-cublas ;; noqa
         native-library-dir
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

(define-runtime-path staged-dir "../../native-libs")
(define-runtime-path raft-info "../../info.rkt")

(define abi-version 1)

(define (library-abi-version library)
  (define tag (get-ffi-obj "rr_abi" library (_fun -> _pointer) (lambda () #f)))
  (define tag-pointer (and tag (tag)))
  (and tag-pointer (ptr-ref tag-pointer _int32)))

(define (abi-mismatch-error where found)
  (format "libraftrkt ~a, but this raft needs ABI version ~a\n  found in: ~a\n  ~a"
          (if found
              (format "has ABI version ~a" found)
              "has no ABI version")
          abi-version
          where
          native-library-advice))

(define (raise-load-failure message)
  (raise-raft 'raft 'generic "~a" message))

(define (load-checked-library where)
  (define library
    (with-handlers ([exn:fail? (lambda (e)
                                 (raise-load-failure
                                  (native-library-error 'unloadable where (exn-message e))))])
      (ffi-lib (build-path where "libraftrkt"))))
  (define found (library-abi-version library))
  (cond
    [(eqv? found abi-version) library]
    [else (raise-load-failure (abi-mismatch-error where found))]))

(define (load-cublas dir)
  (for ([name (in-list cublas-libraries)])
    (with-handlers ([exn:fail? (lambda (e)
                                 (raise-load-failure
                                  (cublas-error 'unloadable name dir (exn-message e))))])
      (ffi-lib (build-path dir name)))))

(define (ensure-cublas location native-kind)
  (match* (location native-kind)
    [((cublas-location 'override dir) _) (load-cublas dir)]
    [((cublas-location 'fetched dir) 'package) (load-cublas dir)]
    [((cublas-location 'fetched _) (or 'override 'staged)) (void)]
    [((cublas-location 'system _) _) (void)]
    [((cublas-location 'bad-override dir) _) (raise-load-failure (cublas-error 'override dir))]
    [((cublas-location 'missing _) 'package)
     (raise-load-failure (cublas-error 'missing (cuda-wheel-roots)))]
    [((cublas-location 'missing _) (or 'override 'staged)) (void)]))

(define ((missing-export where) name)
  (lambda ()
    (raise-load-failure
     (format "libraftrkt lacks the export for ~a, so it is older than this raft\n  found in: ~a\n  ~a"
             name
             where
             native-library-advice))))

(define location (locate-native-library staged-dir))

(define native-library-dir (native-location-dir location))

(define native-library
  (match (native-library-problem location (package-version (path-only raft-info)))
    [#f
     (ensure-cublas (locate-cublas) (native-location-kind location))
     (load-checked-library native-library-dir)]
    [message (raise-load-failure message)]))

(define-ffi-definer define-raft
                    native-library
                    #:make-c-id convention:hyphen->underscore
                    #:default-make-fail (missing-export native-library-dir))

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
