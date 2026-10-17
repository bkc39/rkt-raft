#lang racket/base

(require (only-in racket/list append-map)
         (only-in racket/match match)
         (only-in racket/path find-relative-path)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path
         (only-in rackunit check-equal? check-not-false test-case)
         (only-in setup/getinfo get-info/full)
         (only-in syntax/modcode get-module-code)
         (only-in syntax/modresolve resolve-module-path-index))

(define-runtime-path raft-dir "..")
(define-runtime-path loader "../private/foreign/library.rkt")

(define (omit-paths build-service)
  (parameterize ([current-environment-variables
                  (environment-variables-copy (current-environment-variables))])
    (environment-variables-set! (current-environment-variables)
                                #"PLT_INFO_ALLOW_VARS"
                                #";PLT_PKG_BUILD_SERVICE")
    (environment-variables-set! (current-environment-variables)
                                #"PLT_PKG_BUILD_SERVICE"
                                build-service)
    ((get-info/full raft-dir #:namespace (make-base-empty-namespace)) 'test-omit-paths)))

(define (relative path)
  (path->string (find-relative-path (simplify-path raft-dir) (simplify-path path))))

(define modules
  (for/list ([path (in-directory raft-dir
                                 (lambda (dir)
                                   (not (regexp-match? #rx"/(compiled|native-libs)$"
                                                       (path->string dir)))))]
             #:when (regexp-match? #rx"[.]rkt$" (path->string path))
             #:unless (regexp-match? #rx"(^|/)info[.]rkt$" (path->string path)))
    (relative path)))

(define (omitted? module omits)
  (for/or ([omit (in-list omits)])
    (or (equal? module omit)
        (regexp-match? (regexp (string-append "^" (regexp-quote omit) "/")) module))))

(define (resolved-file mpi path)
  (match (resolve-module-path-index mpi path)
    [(? path? file) (simplify-path file)]
    [(list* 'submod (? path? file) _) (simplify-path file)]
    [_ #f]))

(define (runtime-imports code path)
  (append (for*/list ([phase+imports (in-list (module-compiled-imports code))]
                      #:when (eqv? (car phase+imports) 0)
                      [mpi (in-list (cdr phase+imports))]
                      [file (in-value (resolved-file mpi path))]
                      #:when file)
            file)
          (append-map (lambda (submodule) (runtime-imports submodule path))
                      (append (module-compiled-submodules code #t)
                              (module-compiled-submodules code #f)))))

(define loads-libraftrkt
  (let ([memo (make-hash)])
    (lambda (path)
      (define file (simplify-path path))
      (hash-ref memo
                file
                (lambda ()
                  (hash-set! memo file #f)
                  (define answer
                    (or (equal? file (simplify-path loader))
                        (for/or ([import (in-list (runtime-imports (get-module-code file) file))]
                                 #:unless (regexp-match? #rx"^[.][.]/" (relative import)))
                          (loads-libraftrkt import))))
                  (hash-set! memo file answer)
                  answer)))))

(define (native? module)
  (loads-libraftrkt (build-path raft-dir module)))

(test-case "info.rkt omits the native tests only where the build service asks"
  (check-equal? (omit-paths #f) '("scribblings" "tests/python"))
  (define service (omit-paths #"1"))
  (check-not-false (member "tests/gpu" service))
  (check-equal? (filter (lambda (path) (not (member path service))) (omit-paths #f)) '()))

(test-case "on the build service, no module raco test runs loads libraftrkt"
  (define service (omit-paths #"1"))
  (check-equal? (filter (lambda (module) (and (not (omitted? module service)) (native? module)))
                        modules)
                '()))

(test-case "the build service still runs every library module that needs no libraftrkt"
  (define service (omit-paths #"1"))
  (check-equal? (filter (lambda (module)
                          (and (omitted? module service)
                               (not (regexp-match? #rx"^(tests|scribblings)/" module))
                               (not (native? module))))
                        modules)
                '()))

(test-case "the native tests are the ones that load libraftrkt"
  (check-not-false (native? "tests/gpu/smoke-test.rkt"))
  (check-not-false (native? "main.rkt"))
  (check-equal? (native? "tests/docs-replay-test.rkt") #f))
