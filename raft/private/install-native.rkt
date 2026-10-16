#lang racket/base

(require (only-in racket/file call-with-atomic-output-file file->bytes make-directory*)
         (only-in racket/match match)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path
         (only-in setup/getinfo get-info/full))

(provide locate-native-library
         native-library-advice
         native-library-error
         native-version-error
         package-version
         pre-installer
         stage-native-libs!
         staged?)

(define native-package "raft-x86_64-linux")

(define-runtime-path native-package-module "native-package.rkt")

(define library-pattern #rx"^libraftrkt[.]")

(define override-advice
  "to use a libraftrkt built by hand, set RAFT_NATIVE_LIB_PATH to the directory whose lib/ holds it")

(define native-library-advice (format "reinstall raft; ~a" override-advice))

(define missing-package-advice
  (format "install it with `raco pkg install ~a`; ~a" native-package override-advice))

(define (staged? dir)
  (and (directory-exists? dir)
       (for/or ([f (in-list (directory-list dir))])
         (regexp-match? library-pattern f))))

(define (native-package-libs-dir)
  (with-handlers ([exn:missing-module? (lambda (_) #f)])
    (dynamic-require native-package-module 'native-libs-dir)))

(define (locate-native-library staged-dir)
  (define override
    (match (getenv "RAFT_NATIVE_LIB_PATH")
      [(or #f "") #f]
      [dir dir]))
  (define package-dir (and (not override) (not (staged? staged-dir)) (native-package-libs-dir)))
  (define-values (kind dir)
    (cond
      [override (values 'override (build-path override "lib"))]
      [(staged? staged-dir) (values 'staged staged-dir)]
      [package-dir (values 'package package-dir)]
      [else (values 'missing staged-dir)]))
  (values kind (simplify-path dir)))

(define (package-version dir)
  (define info (get-info/full dir))
  (and info (info 'version (lambda () #f))))

(define (native-library-error kind where loader-message)
  (match kind
    ['missing
     (format "libraftrkt is not installed: the package ~a is missing\n  looked in: ~a\n  ~a"
             native-package
             where
             missing-package-advice)]
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
             native-library-advice)]
    ['unloadable
     (format
      "libraftrkt was found but would not load\n  found in: ~a\n  the loader said: ~a\n  check that LD_LIBRARY_PATH holds no other CUDA, or ~a"
      where
      loader-message
      native-library-advice)]))

(define (native-version-error found wanted where)
  (format "the package ~a is version ~a, but this raft is version ~a\n  found in: ~a\n  ~a"
          native-package
          (or found "unknown")
          (or wanted "unknown")
          where
          (format "update both with `raco pkg update raft ~a`" native-package)))

(define (same-bytes? a b)
  (and (file-exists? b) (= (file-size a) (file-size b)) (equal? (file->bytes a) (file->bytes b))))

;; A temp file and rename(2), never a write in place: rewriting a library
;; that a live process has mapped faults that process.
(define (stage-file! src dst)
  (unless (same-bytes? src dst)
    (call-with-atomic-output-file dst
                                  (lambda (out tmp)
                                    (write-bytes (file->bytes src) out)
                                    (file-or-directory-permissions tmp #o555)))))

(define (stage-native-libs! source-dir dest-dir)
  (make-directory* dest-dir)
  (for ([f (in-list (directory-list source-dir))]
        #:when (regexp-match? library-pattern f))
    (stage-file! (build-path source-dir f) (build-path dest-dir f))))

(define (pre-installer _collections-top-path this-collection-path _user-specific?)
  (define native-libs-dir (build-path this-collection-path "native-libs"))
  (define-values (kind dir) (locate-native-library native-libs-dir))
  (match kind
    ['override (stage-native-libs! dir native-libs-dir)]
    ['missing (eprintf "raft: ~a\n" (native-library-error 'missing dir #f))]
    ['package
     #:when (not (staged? dir))
     (eprintf "raft: ~a\n" (native-library-error 'package dir #f))]
    [_ (void)]))
