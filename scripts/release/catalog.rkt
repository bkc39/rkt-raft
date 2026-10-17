#lang racket/base

(require (only-in file/sha1 sha1)
         (only-in racket/file file->string)
         (only-in racket/match == match)
         (only-in racket/path file-name-from-path)
         (only-in racket/string string-contains?)
         (only-in setup/getinfo get-info/full))

(define (info-ref dir key)
  (define info (get-info/full dir))
  (unless info
    (raise-user-error 'catalog "~a has no info.rkt" dir))
  (info key (lambda () (raise-user-error 'catalog "~a/info.rkt has no ~a" dir key))))

(define (package-name dir)
  (path->string (file-name-from-path (simplify-path (path->complete-path dir)))))

(define (entry dir zip source)
  (hash 'name (package-name dir)
        'source source
        'checksum (call-with-input-file zip sha1)
        'version (info-ref dir 'version)
        'dependencies (info-ref dir 'deps)
        'description (info-ref dir 'pkg-desc)))

(define (dependency-version deps name)
  (for/or ([dep (in-list deps)])
    (match dep
      [(list (== name) _ ... '#:version version _ ...) version] ;; noqa
      [_ #f])))

(define (dependency-name dep)
  (match dep
    [(? string?) dep]
    [(cons name _) name]))

(define (dependencies-except dir name)
  (for/list ([dep (in-list (append (info-ref dir 'deps) (info-ref dir 'build-deps)))]
             #:unless (equal? (dependency-name dep) name))
    (dependency-name dep)))

(define (refuse-or problem value)
  (match problem
    [#f value]
    [message (raise-user-error 'catalog "~a" message)]))

(define notice-licenses
  (hash "Apache License 2.0" 'Apache-2.0
        "MIT License" 'MIT
        "NVIDIA CUDA Toolkit End User License Agreement" 'LicenseRef-NVIDIA-CUDA-EULA))

(define (license-sexp? license)
  (match license
    [(list (? symbol? id) 'WITH (? symbol? exception))
     (and (license-sexp? id) (license-sexp? exception))]
    [(list left (or 'AND 'OR) right) (and (license-sexp? left) (license-sexp? right))]
    [(? symbol?) (not (memq license '(AND OR WITH)))]
    [_ #f]))

(define (license-ids license)
  (match license
    [(list left (or 'AND 'OR) right) (append (license-ids left) (license-ids right))]
    [(list id 'WITH _) (list id)]
    [id (list id)]))

(define (check-license native)
  (define license (info-ref native 'license))
  (define notice (regexp-replace* #px"\\s+" (file->string (build-path native "NOTICE")) " "))
  (define unclaimed
    (sort (for/list ([(phrase id) (in-hash notice-licenses)]
                     #:when (and (string-contains? notice phrase)
                                 (not (memq id (license-ids license)))))
            id)
          symbol<?))
  (refuse-or
   (cond
     [(not (license-sexp? license))
      (format "~a/info.rkt: license ~s is not a license S-expression" native license)]
     [(pair? unclaimed)
      (format "~a/info.rkt: license ~s lacks ~a, which NOTICE names" native license unclaimed)]
     [else #f])
   (format "~s" license)))

(define (check-version native raft tag)
  (define name (package-name native))
  (define version (info-ref native 'version))
  (define needed (info-ref raft 'native-version))
  (define wanted (dependency-version (info-ref raft 'deps) name))
  (define problem
    (cond
      [(not (equal? version needed))
       (format "~a is version ~a, raft needs version ~a" name version needed)]
      [(not (equal? wanted version))
       (format "raft depends on ~a #:version ~a, not ~a" name wanted version)]
      [(and (not (equal? tag "")) (not (equal? tag (string-append "v" version))))
       (format "tag ~a does not name version ~a (want v~a)" tag version version)]
      [else #f]))
  (refuse-or problem version))

(module+ main
  (require (only-in racket/pretty pretty-write))
  (match (current-command-line-arguments)
    [(vector "check" native raft tag) (displayln (check-version native raft tag))]
    [(vector "license" native) (displayln (check-license native))]
    [(vector "entry" dir zip source) (pretty-write (entry dir zip source))]
    [(vector "deps-except" dir name) (for-each displayln (dependencies-except dir name))]
    [_
     (raise-user-error
      'catalog
      "usage: catalog.rkt check NATIVE RAFT TAG | license NATIVE | entry DIR ZIP SOURCE | deps-except DIR NAME")]))
