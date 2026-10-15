#lang racket/base

(require (only-in racket/file delete-directory/files make-temporary-directory)
         (only-in rackunit check-regexp-match)
         (only-in "../private/foreign/library.rkt" open-native-library)
         (only-in "../private/resource.rkt" with-release)
         (only-in "private/probe.rkt" probe-path probe-stale-abi-path test-host-probe))

(define (load-failure library)
  (with-release ([dir (make-temporary-directory "raft-load-~a") delete-directory/files])
    (make-file-or-directory-link library (build-path dir "libraftrkt.so"))
    (with-handlers ([exn:fail? (lambda (e) (cons (simplify-path dir) (exn-message e)))])
      (open-native-library dir)
      (cons dir "loaded"))))

(test-host-probe "a library of another ABI version is refused with both versions and its path"
  (define failure (load-failure probe-stale-abi-path))
  (define message (cdr failure))
  (check-regexp-match #rx"^raft: libraftrkt has ABI version 2, but this raft needs ABI version 1\n"
                      message)
  (check-regexp-match (regexp (regexp-quote (format "found in: ~a\n" (car failure)))) message)
  (check-regexp-match #rx"reinstall raft" message))

(test-host-probe "a library with no rr_abi is refused before any other symbol is looked up"
  (define message (cdr (load-failure probe-path)))
  (check-regexp-match
   #rx"^raft: libraftrkt has no ABI version [(]it exports no rr_abi[)], but this raft needs ABI version 1\n"
   message)
  (check-regexp-match #rx"reinstall raft" message))
