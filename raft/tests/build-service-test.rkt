#lang racket/base

(require (only-in racket/file delete-directory/files make-temporary-directory)
         (only-in racket/list append-map)
         (only-in racket/match match)
         (only-in racket/path file-name-from-path find-relative-path path-has-extension?)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path
         (only-in racket/string string-prefix? string-split)
         (only-in rackunit check-equal? check-not-false test-case)
         (only-in setup/getinfo get-info/full)
         (only-in syntax/modcode get-module-code)
         (only-in syntax/modresolve resolve-module-path-index)
         (only-in "../private/resource.rkt" with-release)
         (only-in "private/env.rkt" with-environment-variables))

(define-runtime-path raft-dir "..")
(define-runtime-path loader "../private/foreign/library.rkt")
(define-runtime-path requires-raft "fixtures/requires-raft-rkt.txt")
(define-runtime-path empty-module "fixtures/empty-module-rkt.txt")

(define (omit-paths build-service)
  (with-environment-variables
   (["PLT_INFO_ALLOW_VARS" ";PLT_PKG_BUILD_SERVICE"] ["PLT_PKG_BUILD_SERVICE" build-service])
   ((get-info/full raft-dir #:namespace (make-base-empty-namespace)) 'test-omit-paths)))

(define (relative path)
  (find-relative-path (simplify-path raft-dir) (simplify-path path)))

(define (named? path . names)
  (and (member (path->string (file-name-from-path path)) names) #t))

(define modules
  (for/list ([path (in-directory raft-dir (lambda (dir) (not (named? dir "compiled" "native-libs"))))]
             #:when (path-has-extension? path #".rkt")
             #:unless (named? path "info.rkt"))
    (path->string (relative path))))

(define (omitted? module omits)
  (for/or ([omit (in-list omits)])
    (or (equal? module omit) (string-prefix? module (string-append omit "/")))))

(define (in-tree? file)
  (match (explode-path (relative file))
    [(cons 'up _) #f]
    [_ #t]))

(define (raft-collection-file name)
  (match name
    [(? symbol?)
     (match (string-split (symbol->string name) "/")
       [(list "raft") (build-path raft-dir "main.rkt")]
       [(cons "raft" more) (path-add-extension (apply build-path raft-dir more) #".rkt")]
       [_ #f])]
    [(list* 'submod collection _) (raft-collection-file collection)]
    [_ #f]))

(define (resolved-file mpi path)
  (define-values (name _base) (module-path-index-split mpi))
  (or (raft-collection-file name)
      (match (resolve-module-path-index mpi path)
        [(? path? file) file]
        [(list* 'submod (? path? file) _) file]
        [_ #f])))

(define (runtime-imports code path)
  (append (for*/list ([phase+imports (in-list (module-compiled-imports code))]
                      #:when (eqv? (car phase+imports) 0)
                      [mpi (in-list (cdr phase+imports))]
                      [file (in-value (resolved-file mpi path))]
                      #:when file)
            (simplify-path file))
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
                                 #:when (in-tree? import))
                          (loads-libraftrkt import))))
                  (hash-set! memo file answer)
                  answer)))))

(define (native? module)
  (loads-libraftrkt (build-path raft-dir module)))

(test-case "info.rkt omits the native tests only where the build service asks"
  (check-equal? (omit-paths #f) '("scribblings" "tests/python"))
  (define service (omit-paths "1"))
  (check-not-false (member "tests/gpu" service))
  (check-equal? (filter (lambda (path) (not (member path service))) (omit-paths #f)) '()))

(test-case "on the build service, no module raco test runs loads libraftrkt"
  (define service (omit-paths "1"))
  (check-equal? (filter (lambda (module) (and (not (omitted? module service)) (native? module)))
                        modules)
                '()))

(test-case "the build service still runs every library module that needs no libraftrkt"
  (define service (omit-paths "1"))
  (check-equal? (filter (lambda (module)
                          (and (omitted? module service)
                               (not (string-prefix? module "tests/"))
                               (not (string-prefix? module "scribblings/"))
                               (not (native? module))))
                        modules)
                '()))

(test-case "the native tests are the ones that load libraftrkt"
  (check-not-false (native? "tests/gpu/smoke-test.rkt"))
  (check-not-false (native? "main.rkt"))
  (check-equal? (native? "tests/docs-replay-test.rkt") #f))

(define (call-with-raft-elsewhere thunk)
  (with-release ([dir (make-temporary-directory "raft-elsewhere-~a") delete-directory/files])
    (make-directory (build-path dir "raft"))
    (copy-file empty-module (build-path dir "raft" "main.rkt"))
    (parameterize ([current-library-collection-links (cons (hash 'raft (list (build-path dir "raft")))
                                                           (current-library-collection-links))]
                   [current-namespace (make-base-namespace)])
      (thunk))))

(test-case "a module that requires the raft collection is native wherever the collection resolves"
  (call-with-raft-elsewhere (lambda () (check-not-false (loads-libraftrkt requires-raft)))))
