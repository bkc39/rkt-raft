#lang racket/base

(require (only-in file/sha1 bytes->hex-string)
         (only-in file/unzip read-zip-directory unzip-entry)
         (only-in net/url get-pure-port get-pure-port/headers string->url url->path url-scheme)
         (only-in racket/file delete-directory/files make-directory*)
         (only-in racket/match match)
         (only-in racket/path file-name-from-path)
         (only-in racket/port copy-port)
         (only-in racket/string string-trim)
         (only-in setup/dirs find-share-dir)
         (only-in "resource.rkt" with-release))

(provide (struct-out cuda-wheel)
         cuda-wheel-dir
         cuda-wheel-libraries
         cuda-wheel-present?
         cuda-wheel-roots
         cuda-wheel-source
         ensure-cuda-wheel
         find-cuda-wheel
         read-cuda-wheel)

(struct cuda-wheel (name version url sha256 size entries))

(define (read-cuda-wheel path name)
  (match (assoc name (call-with-input-file path read))
    [(list _
           (list 'version version)
           (list 'url url)
           (list 'sha256 sha256)
           (list 'size size)
           (cons 'libraries entries))
     (cuda-wheel name version url sha256 size entries)]))

(define (cuda-wheel-libraries wheel)
  (for/list ([entry (in-list (cuda-wheel-entries wheel))])
    (path->string (file-name-from-path entry))))

(define (wheel-home root wheel [suffix ""])
  (simplify-path
   (build-path root
               "rapids"
               "cu13"
               (format "~a-~a~a" (cuda-wheel-name wheel) (cuda-wheel-version wheel) suffix))))

(define (cuda-wheel-dir root wheel)
  (build-path (wheel-home root wheel) "lib"))

(define (cuda-wheel-present? dir wheel)
  (for/and ([name (in-list (cuda-wheel-libraries wheel))])
    (file-exists? (build-path dir name))))

(define (cuda-wheel-roots)
  (filter values (list (find-system-path 'addon-dir) (find-share-dir))))

(define (find-cuda-wheel wheel [roots (cuda-wheel-roots)])
  (for/first ([root (in-list roots)]
              #:when (cuda-wheel-present? (cuda-wheel-dir root wheel) wheel))
    (cuda-wheel-dir root wheel)))

(define (cuda-wheel-source wheel)
  (match (getenv "RAFT_CUDA_WHEEL_URL_BASE")
    [(or #f "") (cuda-wheel-url wheel)]
    [base
     (format "~a/~a"
             (string-trim base "/" #:left? #f)
             (file-name-from-path (string->path (cuda-wheel-url wheel))))]))

(define (open-source source)
  (define url (string->url source))
  (match (url-scheme url)
    ["file" (get-pure-port url)]
    [_
     (define-values (in headers) (get-pure-port/headers url #:redirections 5 #:status? #t))
     (match (regexp-match #rx"^HTTP/[0-9.]+ ([0-9]+)" headers)
       [(list _ "200") in]
       [status
        (close-input-port in)
        (error 'cuda-wheel
               "~a answered ~a"
               source
               (if status
                   (format "HTTP ~a" (cadr status))
                   "with no HTTP status"))])]))

(define (download! source file)
  (with-release ([in (open-source source) close-input-port])
    (call-with-output-file file #:exists 'truncate (lambda (out) (copy-port in out)))))

(define (file-sha256 file)
  (bytes->hex-string (call-with-input-file file sha256-bytes)))

(define (wheel-problem file wheel source)
  (define size (file-size file))
  (define sha256 (and (= size (cuda-wheel-size wheel)) (file-sha256 file)))
  (cond
    [(not sha256) (format "~a gave ~a bytes, not the pinned ~a" source size (cuda-wheel-size wheel))]
    [(not (equal? sha256 (cuda-wheel-sha256 wheel)))
     (format "~a has sha256 ~a, not the pinned ~a" source sha256 (cuda-wheel-sha256 wheel))]
    [else #f]))

(define (unpack! file wheel lib)
  (define directory (read-zip-directory file))
  (for ([entry (in-list (cuda-wheel-entries wheel))]
        [name (in-list (cuda-wheel-libraries wheel))])
    (define out (build-path lib name))
    (unzip-entry file
                 directory
                 (string->bytes/utf-8 entry)
                 (lambda (_name _dir? in) (call-with-output-file out (lambda (o) (copy-port in o)))))
    (file-or-directory-permissions out #o755)))

(define (fetch! wheel part target)
  (define source (cuda-wheel-source wheel))
  (define file (build-path part "wheel.zip"))
  (make-directory* (build-path part "lib"))
  (download! source file)
  (match (wheel-problem file wheel source)
    [#f
     (unpack! file wheel (build-path part "lib"))
     (delete-file file)
     (rename-file-or-directory part target)]
    [problem (error 'cuda-wheel "~a" problem)]))

(define (ensure-cuda-wheel wheel root)
  (define lib (cuda-wheel-dir root wheel))
  (define target (wheel-home root wheel))
  (define part (wheel-home root wheel ".part"))
  (cond
    [(cuda-wheel-present? lib wheel) lib]
    [else
     (delete-directory/files part #:must-exist? #f)
     (delete-directory/files target #:must-exist? #f)
     (with-handlers ([(lambda (_) #t) (lambda (e)
                                        (delete-directory/files part #:must-exist? #f)
                                        (raise e))])
       (fetch! wheel part target))
     lib]))
