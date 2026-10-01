#lang racket/base

(require (only-in racket/file file->bytes make-directory* make-temporary-file)
         (only-in racket/path file-name-from-path))

(provide pre-installer
         stage-native-libs!)

(define library-pattern #rx"^libraftrkt[.]")

(define (same-bytes? a b)
  (and (file-exists? b)
       (= (file-size a) (file-size b))
       (equal? (file->bytes a) (file->bytes b))))

;; rename(2), never a write in place: an in-place write faults every process
;; that still has the old library mapped.
(define (stage-file! src dst-dir)
  (define dst (build-path dst-dir (file-name-from-path src)))
  (unless (same-bytes? src dst)
    (define tmp (make-temporary-file "libraftrkt-~a.part" #f dst-dir))
    (dynamic-wind
     void
     (lambda ()
       (copy-file src tmp #t)
       (file-or-directory-permissions tmp #o555)
       (rename-file-or-directory tmp dst #t))
     (lambda ()
       (when (file-exists? tmp)
         (delete-file tmp))))))

(define (stage-native-libs! source-dir dest-dir)
  (make-directory* dest-dir)
  (for ([f (in-list (directory-list source-dir #:build? #t))]
        #:when (regexp-match? library-pattern (path->string (file-name-from-path f))))
    (stage-file! f dest-dir)))

(define (staged? dir)
  (and (directory-exists? dir)
       (for/or ([f (in-list (directory-list dir))])
         (regexp-match? library-pattern (path->string f)))))

(define (pre-installer _collections-top-path this-collection-path _user-specific?)
  (define native-libs-dir (build-path this-collection-path "native-libs"))
  (define override (getenv "RAFT_NATIVE_LIB_PATH"))
  (cond
    [override (stage-native-libs! (build-path override "lib") native-libs-dir)]
    [(staged? native-libs-dir) (void)]
    [else
     (eprintf "raft: libraftrkt is not staged in ~a; build it with nix (`nix develop` stages it) or set RAFT_NATIVE_LIB_PATH to a directory whose lib/ holds it\n"
              native-libs-dir)]))
