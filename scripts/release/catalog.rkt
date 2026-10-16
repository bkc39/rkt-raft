#lang racket/base

(require (only-in file/sha1 sha1)
         (only-in racket/match == match)
         (only-in racket/path file-name-from-path)
         (only-in setup/getinfo get-info/full))

(define (info-ref dir key)
  (define info (get-info/full dir))
  (unless info
    (raise-user-error 'catalog "~a has no info.rkt" dir))
  (info key (lambda () (raise-user-error 'catalog "~a/info.rkt has no ~a" dir key))))

(define (entry dir zip source)
  (hash 'name (path->string (file-name-from-path (simplify-path (path->complete-path dir))))
        'source source
        'checksum (call-with-input-file zip sha1)
        'version (info-ref dir 'version)
        'dependencies (info-ref dir 'deps)
        'description (info-ref dir 'pkg-desc)))

(define (dependency-version deps name)
  (define (keyword-version options)
    (match options
      [(list* '#:version version _) version]
      [(list* _ _ more) (keyword-version more)]
      [_ #f]))
  (for/or ([dep (in-list deps)])
    (match dep
      [(cons (== name) options) (keyword-version options)]
      [_ #f])))

(define (check-version native raft tag)
  (define name (path->string (file-name-from-path (simplify-path (path->complete-path native)))))
  (define version (info-ref native 'version))
  (define raft-version (info-ref raft 'version))
  (define wanted (dependency-version (info-ref raft 'deps) name))
  (define problem
    (cond
      [(not (equal? version raft-version))
       (format "~a is version ~a, raft is version ~a" name version raft-version)]
      [(not (equal? wanted version))
       (format "raft depends on ~a #:version ~a, not ~a" name wanted version)]
      [(and (not (equal? tag "")) (not (equal? tag (string-append "v" version))))
       (format "tag ~a does not name version ~a (want v~a)" tag version version)]
      [else #f]))
  (match problem
    [#f version]
    [message (raise-user-error 'catalog "~a" message)]))

(module+ main
  (require (only-in racket/pretty pretty-write))
  (match (current-command-line-arguments)
    [(vector "check" native raft tag) (displayln (check-version native raft tag))]
    [(vector "entry" dir zip source) (pretty-write (entry dir zip source))]
    [_
     (raise-user-error 'catalog "usage: catalog.rkt check NATIVE RAFT TAG | entry DIR ZIP SOURCE")]))
