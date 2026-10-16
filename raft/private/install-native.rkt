#lang racket/base

(require (only-in racket/match == match)
         (only-in racket/path path-only)
         (only-in setup/getinfo get-info/full)
         (only-in "cublas.rkt" cublas-setup-warning)
         (only-in "cuda-wheels.rkt" cuda-wheel-root))

(provide (struct-out native-location)
         locate-native-library
         native-library-advice
         native-library-error
         native-library-problem
         native-version-error
         package-version
         pre-installer
         staged?)

(struct native-location (kind dir version cause))

(define native-package "raft-x86_64-linux")

(define native-platform "x86_64-linux")

(define library-pattern #rx"^libraftrkt[.]")

(define override-advice
  "to use a libraftrkt built by hand, set RAFT_NATIVE_LIB_PATH to the directory whose lib/ holds it")

(define native-library-advice (format "reinstall raft; ~a" override-advice))

(define missing-package-advice
  (format "install it with `raco pkg install ~a`; ~a" native-package override-advice))

(define broken-package-advice
  (format "reinstall it with `raco pkg remove --force ~a` and `raco pkg install ~a`; ~a"
          native-package
          native-package
          override-advice))

(define (staged? dir)
  (and (directory-exists? dir)
       (for/or ([f (in-list (directory-list dir))])
         (regexp-match? library-pattern f))))

(define (package-version dir)
  (define info (get-info/full dir))
  (and info (info 'version (lambda () #f))))

(define (override-dir)
  (match (getenv "RAFT_NATIVE_LIB_PATH")
    [(or #f "") #f]
    [dir (simplify-path (build-path dir "lib"))]))

(define (native-package-location main)
  (define package-dir (simplify-path (path-only main)))
  (with-handlers ([exn:fail? (lambda (e) (native-location 'broken package-dir #f (exn-message e)))])
    (native-location 'package
                     (simplify-path (dynamic-require main 'native-libs-dir))
                     (package-version package-dir)
                     #f)))

(define (installed-package-location)
  (match (collection-file-path "main.rkt" native-package #:fail (lambda (_) #f))
    [#f #f]
    [main (native-package-location main)]))

(define (locate-native-library staged-dir)
  (cond
    [(override-dir)
     =>
     (lambda (dir) (native-location 'override dir #f #f))]
    [(staged? staged-dir) (native-location 'staged (simplify-path staged-dir) #f #f)]
    [(installed-package-location)]
    [else (native-location 'missing (simplify-path staged-dir) #f #f)]))

(define (missing-error where platform)
  (match platform
    [(== native-platform)
     (format "libraftrkt is not installed: the package ~a is missing\n  looked in: ~a\n  ~a"
             native-package
             where
             missing-package-advice)]
    [other
     (format
      "libraftrkt is not installed: raft ships a native library for x86_64 Linux only, not ~a\n  looked in: ~a\n  ~a"
      other
      where
      override-advice)]))

(define (native-library-error kind
                              where
                              [detail #f]
                              #:platform [platform (path->string (system-library-subpath #f))])
  (match kind
    ['missing (missing-error where platform)]
    ['broken
     (format "the package ~a is installed but would not load\n  found in: ~a\n  it said: ~a\n  ~a"
             native-package
             where
             detail
             broken-package-advice)]
    ['override
     (format
      "libraftrkt is not where RAFT_NATIVE_LIB_PATH points\n  looked in: ~a\n  unset it to load ~a's, or ~a"
      where
      native-package
      override-advice)]
    ['package
     (format "the package ~a holds no libraftrkt\n  looked in: ~a\n  ~a"
             native-package
             where
             broken-package-advice)]
    ['unloadable
     (format
      "libraftrkt was found but would not load\n  found in: ~a\n  the loader said: ~a\n  check that LD_LIBRARY_PATH holds no other CUDA, or ~a"
      where
      detail
      native-library-advice)]))

(define (native-version-error found wanted where)
  (format "the package ~a is version ~a, but this raft is version ~a\n  found in: ~a\n  ~a"
          native-package
          (or found "unknown")
          (or wanted "unknown")
          where
          (format "update both with `raco pkg update raft ~a`" native-package)))

(define (native-library-problem location wanted)
  (match location
    [(native-location 'missing dir _ _) (native-library-error 'missing dir)]
    [(native-location 'broken dir _ cause) (native-library-error 'broken dir cause)]
    [(native-location (and kind (or 'override 'package)) dir _ _)
     #:when (not (staged? dir))
     (native-library-error kind dir)]
    [(native-location 'package dir found _)
     #:when (not (equal? found wanted))
     (native-version-error found wanted dir)]
    [(native-location (or 'override 'staged 'package) _ _ _) #f]))

(define (package-holds-library?)
  (match (installed-package-location)
    [(native-location 'package dir _ _) (staged? dir)]
    [_ #f]))

(define (shadowed-package-warning location)
  (match location
    [(native-location 'staged dir _ _)
     #:when (package-holds-library?)
     (format "the staged directory ~a wins over the package ~a; delete it to use the package"
             dir
             native-package)]
    [_ #f]))

(define (ensure-cublas-at-setup location user-specific?)
  (match location
    [(native-location 'package _ _ _) (cublas-setup-warning (cuda-wheel-root user-specific?))]
    [_ #f]))

(define (pre-installer _collections-top-path this-collection-path user-specific?)
  (define location (locate-native-library (build-path this-collection-path "native-libs")))
  (for ([message (in-list (list (shadowed-package-warning location)
                                (native-library-problem location
                                                        (package-version this-collection-path))
                                (ensure-cublas-at-setup location user-specific?)))]
        #:when message)
    (eprintf "raft: ~a\n" message)))
