#lang racket/base

(require (only-in file/sha1 bytes->hex-string)
         (only-in file/unzip read-zip-directory unzip-entry)
         (only-in net/url
                  combine-url/relative
                  get-pure-port
                  get-pure-port/headers
                  path/param-path
                  string->url
                  url->string
                  url-path
                  url-scheme)
         (only-in net/url-connect current-https-protocol)
         (only-in racket/file
                  call-with-file-lock/timeout
                  delete-directory/files
                  make-directory*
                  make-temporary-directory)
         (only-in racket/list last)
         (only-in racket/match match)
         (only-in racket/port copy-port)
         (only-in "cuda-wheels.rkt"
                  cuda-wheel-dir
                  cuda-wheel-members
                  cuda-wheel-sha256
                  cuda-wheel-size
                  cuda-wheel-url
                  locate-cuda-wheel
                  wheel-member-name
                  wheel-member-path)
         (only-in "resource.rkt" with-release))

(provide cuda-wheel-connect-timeout
         cuda-wheel-read-timeout
         cuda-wheel-source
         ensure-cuda-wheel)

(define cuda-wheel-connect-timeout (make-parameter 30))

(define cuda-wheel-read-timeout (make-parameter 60))

(define (pinned-file-name wheel)
  (path/param-path (last (url-path (string->url (cuda-wheel-url wheel))))))

(define (cuda-wheel-source wheel url-base)
  (match url-base
    [#f (cuda-wheel-url wheel)]
    [base
     (define directory
       (string->url (if (regexp-match? #rx"/$" base)
                        base
                        (string-append base "/"))))
     (url->string (combine-url/relative directory (pinned-file-name wheel)))]))

(define (call-with-deadline seconds stalled thunk)
  (define custodian (make-custodian))
  (define worker
    (parameterize ([current-custodian custodian])
      (thread (lambda ()
                (with-handlers ([exn:fail? values])
                  (call-with-values thunk list)))
              #:keep 'results)))
  (match (sync/timeout seconds worker)
    [#f
     (custodian-shutdown-all custodian)
     (error 'cuda-wheel "~a" stalled)]
    [_
     (match (thread-wait worker)
       [(? exn:fail? e) (raise e)]
       [results (apply values results)])]))

(define (open-source source get)
  (define url (string->url source))
  (define seconds (cuda-wheel-connect-timeout))
  (match (url-scheme url)
    ["file" (get-pure-port url)]
    [_
     (define-values (in headers)
       (call-with-deadline seconds
                           (format "~a did not answer within ~a s" source seconds)
                           (lambda () (get url #:redirections 5 #:status? #t))))
     (match (regexp-match #rx"^HTTP/[0-9.]+ ([0-9]+)" headers)
       [(list _ "200") in]
       [(list _ code)
        (close-input-port in)
        (error 'cuda-wheel "~a answered HTTP ~a" source code)]
       [#f
        (close-input-port in)
        (error 'cuda-wheel "~a answered with no HTTP status" source)])]))

(define (copy-until-stalled in out source)
  (define seconds (cuda-wheel-read-timeout))
  (define buffer (make-bytes 65536))
  (let loop ()
    (match (and (sync/timeout seconds in) (read-bytes-avail!* buffer in))
      [#f (error 'cuda-wheel "~a stalled: no data for ~a s" source seconds)]
      [(? eof-object?) (void)]
      [count
       (write-bytes buffer out 0 count)
       (loop)])))

(define (download! source file get)
  (with-release ([in (open-source source get) close-input-port])
    (call-with-output-file file
                           #:exists 'truncate
                           (lambda (out) (copy-until-stalled in out source)))))

(define (file-sha256 file)
  (bytes->hex-string (call-with-input-file file sha256-bytes)))

(define (wheel-problem file wheel source)
  (define size (file-size file))
  (define sha256 (and (= size (cuda-wheel-size wheel)) (file-sha256 file)))
  (cond
    [(not (= size (cuda-wheel-size wheel)))
     (format "~a gave ~a bytes, not the pinned ~a" source size (cuda-wheel-size wheel))]
    [(not (equal? sha256 (cuda-wheel-sha256 wheel)))
     (format "~a has sha256 ~a, not the pinned ~a" source sha256 (cuda-wheel-sha256 wheel))]
    [else #f]))

(define (unpack! file wheel lib)
  (define directory (read-zip-directory file))
  (for ([member (in-list (cuda-wheel-members wheel))])
    (define out (build-path lib (wheel-member-name member)))
    (unzip-entry file
                 directory
                 (string->bytes/utf-8 (wheel-member-path member))
                 (lambda (_name _dir? in) (call-with-output-file out (lambda (o) (copy-port in o)))))
    (file-or-directory-permissions out #o755)))

(struct wheel-place (parent name lib))

(define (place-of root wheel)
  (define-values (home lib _lib-dir?) (split-path (cuda-wheel-dir root wheel)))
  (define-values (parent name _home-dir?) (split-path home))
  (wheel-place parent (path->string name) lib))

(define (remove-stale-parts! place)
  (define pattern (regexp (string-append "^" (regexp-quote (wheel-place-name place)) "[.]part-")))
  (for ([entry (in-list (directory-list (wheel-place-parent place)))]
        #:when (regexp-match? pattern (path->string entry)))
    (delete-directory/files (build-path (wheel-place-parent place) entry))))

(define (remove-part! part)
  (delete-directory/files part #:must-exist? #f))

(define (install! part target wheel root)
  (with-handlers ([(lambda (e) (and (exn:fail:filesystem? e) (locate-cuda-wheel wheel (list root))))
                   void])
    (rename-file-or-directory part target)))

(define (fetch! wheel root source get)
  (define place (place-of root wheel))
  (define target (build-path (wheel-place-parent place) (wheel-place-name place)))
  (remove-stale-parts! place)
  (with-release ([part
                  (make-temporary-directory (string-append (wheel-place-name place) ".part-~a")
                                            #:base-dir (wheel-place-parent place))
                  remove-part!])
    (define file (build-path part "wheel.zip"))
    (define lib (build-path part (wheel-place-lib place)))
    (make-directory* lib)
    (download! source file get)
    (match (wheel-problem file wheel source)
      [#f
       (unpack! file wheel lib)
       (delete-file file)
       (delete-directory/files target #:must-exist? #f)
       (install! part target wheel root)
       (cuda-wheel-dir root wheel)]
      [problem (error 'cuda-wheel "~a" problem)])))

(define (call-with-wheel-lock place thunk)
  (define lock
    (build-path (wheel-place-parent place) (string-append (wheel-place-name place) ".lock")))
  (make-directory* (wheel-place-parent place))
  (let retry ()
    (call-with-file-lock/timeout #f 'exclusive thunk retry #:lock-file lock #:max-delay 1)))

(define (ensure-cuda-wheel wheel root #:url-base [url-base #f] #:get [get get-pure-port/headers])
  (define (present)
    (locate-cuda-wheel wheel (list root)))
  (match (present)
    [#f
     (parameterize ([current-https-protocol 'secure])
       (call-with-wheel-lock (place-of root wheel)
                             (lambda ()
                               (match (present)
                                 [#f (fetch! wheel root (cuda-wheel-source wheel url-base) get)]
                                 [dir dir]))))]
    [dir dir]))
