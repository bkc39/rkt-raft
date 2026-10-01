#lang racket/base

(require (only-in racket/file call-with-atomic-output-file file->bytes make-directory*))

(provide not-staged-advice
         pre-installer
         stage-native-libs!
         staged?)

(define library-pattern #rx"^libraftrkt[.]")

(define not-staged-advice
  "build it with nix (`nix develop` stages it), or set RAFT_NATIVE_LIB_PATH to a directory whose lib/ holds it and reinstall")

(define (staged? dir)
  (and (directory-exists? dir)
       (for/or ([f (in-list (directory-list dir))])
         (regexp-match? library-pattern f))))

(define (same-bytes? a b)
  (and (file-exists? b)
       (= (file-size a) (file-size b))
       (equal? (file->bytes a) (file->bytes b))))

;; A temp file and rename(2), never a write in place: rewriting a library
;; that a live process has mapped faults that process.
(define (stage-file! src dst)
  (unless (same-bytes? src dst)
    (call-with-atomic-output-file
     dst
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
  (define override (getenv "RAFT_NATIVE_LIB_PATH"))
  (cond
    [override (stage-native-libs! (build-path override "lib") native-libs-dir)]
    [(staged? native-libs-dir) (void)]
    [else (eprintf "raft: libraftrkt is not staged in ~a; ~a\n" native-libs-dir not-staged-advice)]))
