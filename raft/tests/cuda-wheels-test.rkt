#lang racket/base

(require (only-in net/url-connect current-https-protocol)
         (only-in racket/file call-with-file-lock/timeout file->bytes make-directory*)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path
         (only-in rackunit
                  check-equal?
                  check-exn
                  check-false
                  check-not-false
                  check-pred
                  check-regexp-match
                  check-true
                  fail
                  test-case)
         (only-in "../private/cuda-wheel-fetch.rkt"
                  cuda-wheel-connect-timeout
                  cuda-wheel-lock-timeout
                  cuda-wheel-read-timeout
                  cuda-wheel-source
                  ensure-cuda-wheel)
         (only-in "../private/cuda-wheels.rkt"
                  cuda-wheel
                  cuda-wheel-dir
                  cuda-wheel-libraries
                  locate-cuda-wheel
                  read-cuda-wheels)
         (only-in "../private/resource.rkt" with-release)
         (only-in "private/cuda-wheels.rkt"
                  call-with-server
                  call-with-temp
                  file-base
                  http-response
                  installed
                  libraries
                  make-wheel!
                  sized-file!))

(define-runtime-path cuda-wheels "../private/cuda-wheels.rktd")

(define cublas-wheel (hash-ref (read-cuda-wheels cuda-wheels) "nvidia-cublas"))

(define home "nvidia-cublas-13.4.0.1")

(define (fetch wheel root base)
  (ensure-cuda-wheel wheel root #:url-base base))

(define (nothing-in-place? root wheel)
  (and (not (locate-cuda-wheel wheel (list root))) (null? (installed root))))

(define (within seconds thunk)
  (define worker
    (thread (lambda ()
              (with-handlers ([exn:fail? values])
                (thunk)))
            #:keep 'results))
  (cond
    [(sync/timeout seconds worker) (thread-wait worker)]
    [else
     (kill-thread worker)
     (fail (format "still running after ~a s" seconds))]))

(define (open-fds)
  (length (directory-list "/proc/self/fd")))

(define ((serving body #:then [then void]) out)
  (write-bytes (http-response "200 OK" body) out)
  (then))

(test-case "the pin is the wheel's two cuBLAS libraries, Lt first"
  (check-equal? (cuda-wheel-libraries cublas-wheel) '("libcublasLt.so.13" "libcublas.so.13"))
  (check-equal? (cuda-wheel-dir "/r" cublas-wheel) (build-path "/r" "rapids" "cu13" home "lib"))
  (check-regexp-match #rx"^https://files[.]pythonhosted[.]org/.*/nvidia_cublas-13[.]4[.]0[.]1-"
                      (cuda-wheel-source cublas-wheel #f)))

(test-case "a URL base serves the pinned file name from elsewhere"
  (for ([base (in-list '("file:///cache/" "file:///cache"))])
    (check-equal? (cuda-wheel-source cublas-wheel base)
                  "file:///cache/nvidia_cublas-13.4.0.1-py3-none-manylinux_2_27_x86_64.whl")))

(test-case "a fetch with the pinned hash unpacks only the two libraries"
  (call-with-temp
   (lambda (dir)
     (define wheel (make-wheel! dir))
     (define root (build-path dir "root"))
     (define lib (fetch wheel root (file-base dir)))
     (check-equal? lib (cuda-wheel-dir root wheel))
     (check-equal? (sort (map path->string (directory-list lib)) string<?) (sort libraries string<?))
     (check-equal? (file->bytes (build-path lib "libcublasLt.so.13")) #"libcublasLt.so.13")
     (check-equal? (installed root) (list home))
     (check-equal? (locate-cuda-wheel wheel (list (build-path dir "elsewhere") root)) lib))))

(test-case "a wrong hash leaves nothing in place"
  (call-with-temp (lambda (dir)
                    (define wheel
                      (struct-copy cuda-wheel (make-wheel! dir) [sha256 (make-string 64 #\0)]))
                    (define root (build-path dir "root"))
                    (check-exn #rx"has sha256 [0-9a-f]+, not the pinned 0000"
                               (lambda () (fetch wheel root (file-base dir))))
                    (check-true (nothing-in-place? root wheel)))))

(test-case "a truncated download leaves nothing in place"
  (call-with-temp
   (lambda (dir)
     (define wheel (make-wheel! dir))
     (define short (build-path dir "short"))
     (make-directory* short)
     (call-with-output-file
      (build-path short "fake.whl")
      (lambda (out) (write-bytes (subbytes (file->bytes (build-path dir "fake.whl")) 0 100) out)))
     (define root (build-path dir "root"))
     (check-exn #rx"gave 100 bytes, not the pinned" (lambda () (fetch wheel root (file-base short))))
     (check-true (nothing-in-place? root wheel)))))

(test-case "a connection dropped mid-download leaves nothing in place"
  (call-with-temp (lambda (dir)
                    (define wheel (make-wheel! dir))
                    (define body (file->bytes (build-path dir "fake.whl")))
                    (define root (build-path dir "root"))
                    (call-with-server (lambda (out)
                                        (define response (http-response "200 OK" body))
                                        (write-bytes response out 0 (- (bytes-length response) 100)))
                                      (lambda (base)
                                        (check-exn exn:fail? (lambda () (fetch wheel root base)))
                                        (check-true (nothing-in-place? root wheel)))))))

(test-case "an HTTP error is named and leaves nothing in place"
  (call-with-temp (lambda (dir)
                    (define wheel (make-wheel! dir))
                    (define root (build-path dir "root"))
                    (call-with-server
                     (lambda (out) (write-bytes (http-response "404 Not Found" #"") out))
                     (lambda (base)
                       (check-exn #rx"answered HTTP 404" (lambda () (fetch wheel root base)))
                       (check-true (nothing-in-place? root wheel)))))))

(test-case "an HTTP download with the pinned hash is unpacked"
  (call-with-temp (lambda (dir)
                    (define wheel (make-wheel! dir))
                    (define root (build-path dir "root"))
                    (call-with-server (serving (file->bytes (build-path dir "fake.whl")))
                                      (lambda (base)
                                        (check-equal? (fetch wheel root base)
                                                      (locate-cuda-wheel wheel (list root))))))))

(test-case "a download that stalls after its first bytes fails and leaves nothing in place"
  (call-with-temp
   (lambda (dir)
     (define wheel (make-wheel! dir))
     (define root (build-path dir "root"))
     (define response (http-response "200 OK" (file->bytes (build-path dir "fake.whl"))))
     (define fds (open-fds))
     (call-with-server (lambda (out)
                         (write-bytes response out 0 200)
                         (flush-output out)
                         (sync never-evt))
                       (lambda (base)
                         (define result
                           (parameterize ([cuda-wheel-read-timeout 0.5])
                             (within 10 (lambda () (fetch wheel root base)))))
                         (check-regexp-match #rx"stalled: no data for 0[.]5 s" (exn-message result))
                         (check-true (nothing-in-place? root wheel))))
     (check-equal? (open-fds) fds))))

(test-case "a server that accepts but never answers fails within the connect timeout"
  (call-with-temp (lambda (dir)
                    (define wheel (make-wheel! dir))
                    (define root (build-path dir "root"))
                    (define fds (open-fds))
                    (call-with-server (lambda (_out) (sync never-evt))
                                      (lambda (base)
                                        (define result
                                          (parameterize ([cuda-wheel-connect-timeout 0.5])
                                            (within 10 (lambda () (fetch wheel root base)))))
                                        (check-regexp-match #rx"did not answer within 0[.]5 s"
                                                            (exn-message result))
                                        (check-true (nothing-in-place? root wheel))))
                    (check-equal? (open-fds) fds))))

(test-case "the fetch verifies HTTPS certificates"
  (call-with-temp (lambda (dir)
                    (define wheel (make-wheel! dir))
                    (define body (file->bytes (build-path dir "fake.whl")))
                    (define protocol (box #f))
                    (define (get _url #:redirections _redirections #:status? _status?)
                      (set-box! protocol (current-https-protocol))
                      (values (open-input-bytes body) "HTTP/1.1 200 OK\r\n"))
                    (check-not-false (ensure-cuda-wheel wheel
                                                        (build-path dir "root")
                                                        #:url-base "https://example.invalid"
                                                        #:get get))
                    (check-equal? (unbox protocol) 'secure))))

(test-case "two concurrent fetches into one root download once and both find it"
  (call-with-temp
   (lambda (dir)
     (define wheel (make-wheel! dir))
     (define root (build-path dir "root"))
     (define body (file->bytes (build-path dir "fake.whl")))
     (define requests (box 0))
     (call-with-server
      (lambda (out)
        (set-box! requests (add1 (unbox requests)))
        (define response (http-response "200 OK" body))
        (for ([start (in-range 0 (bytes-length response) 64)])
          (write-bytes response out start (min (bytes-length response) (+ start 64)))
          (flush-output out)
          (sleep 0.05)))
      (lambda (base)
        (define (start delay)
          (thread (lambda ()
                    (sleep delay)
                    (with-handlers ([exn:fail? values])
                      (fetch wheel root base)))
                  #:keep 'results))
        (define first (start 0))
        (define second (start 0.1))
        (define lib (cuda-wheel-dir root wheel))
        (check-equal? (within 30 (lambda () (list (thread-wait first) (thread-wait second))))
                      (list lib lib))
        (check-equal? (unbox requests) 1)
        (check-equal? (installed root) (list home)))))))

(test-case "a fetch killed before its rename does not count, and the next one removes it"
  (call-with-temp
   (lambda (dir)
     (define wheel (make-wheel! dir))
     (define root (build-path dir "root"))
     (define part (build-path root "rapids" "cu13" (string-append home ".part-123") "lib"))
     (make-directory* part)
     (for ([name (in-list libraries)])
       (call-with-output-file (build-path part name) (lambda (out) (write-string name out))))
     (check-false (locate-cuda-wheel wheel (list root)))
     (check-not-false (fetch wheel root (file-base dir)))
     (check-equal? (installed root) (list home)))))

(test-case "a stale part that cannot be deleted does not block the fetch"
  (call-with-temp (lambda (dir)
                    (define wheel (make-wheel! dir))
                    (define root (build-path dir "root"))
                    (define stale
                      (build-path root "rapids" "cu13" (string-append home ".part-123") "lib"))
                    (make-directory* stale)
                    (call-with-output-file (build-path stale "libcublas.so.13") void)
                    (with-release ([locked
                                    (begin
                                      (file-or-directory-permissions stale #o555)
                                      stale)
                                    (lambda (locked) (file-or-directory-permissions locked #o755))])
                      (check-equal? (fetch wheel root (file-base dir)) (cuda-wheel-dir root wheel))
                      (check-true (directory-exists? locked))))))

(test-case "a fetch waiting on another's lock says so once and gives up at the limit"
  (call-with-temp (lambda (dir)
                    (define wheel (make-wheel! dir))
                    (define root (build-path dir "root"))
                    (define parent (build-path root "rapids" "cu13"))
                    (define lock (build-path parent (string-append home ".lock")))
                    (make-directory* parent)
                    (define held (make-semaphore))
                    (define release (make-semaphore))
                    (define holder
                      (thread (lambda ()
                                (call-with-file-lock/timeout #f
                                                             'exclusive
                                                             (lambda ()
                                                               (semaphore-post held)
                                                               (semaphore-wait release))
                                                             (lambda () (semaphore-post held))
                                                             #:lock-file lock))))
                    (semaphore-wait held)
                    (define out (open-output-string))
                    (define result
                      (parameterize ([cuda-wheel-lock-timeout 4]
                                     [current-output-port out])
                        (within 20 (lambda () (fetch wheel root (file-base dir))))))
                    (semaphore-post release)
                    (thread-wait holder)
                    (check-pred exn:fail? result)
                    (check-regexp-match
                     (regexp (string-append "gave up after 4 s waiting for another fetch to release "
                                            (regexp-quote (path->string lock))))
                     (exn-message result))
                    (check-equal? (get-output-string out)
                                  (format "raft: waiting for another fetch (~a)\n" lock))
                    (check-true (nothing-in-place? root wheel)))))

(test-case "libraries already in place are not fetched again"
  (call-with-temp (lambda (dir)
                    (define wheel (make-wheel! dir))
                    (define root (build-path dir "root"))
                    (define lib (fetch wheel root (file-base dir)))
                    (delete-file (build-path dir "fake.whl"))
                    (check-equal? (fetch wheel root (file-base dir)) lib))))

(test-case "a library of the wrong size is not present, and the next fetch replaces it"
  (call-with-temp (lambda (dir)
                    (define wheel (make-wheel! dir))
                    (define root (build-path dir "root"))
                    (define lib (fetch wheel root (file-base dir)))
                    (sized-file! (build-path lib "libcublasLt.so.13") 5)
                    (check-false (locate-cuda-wheel wheel (list root)))
                    (check-equal? (fetch wheel root (file-base dir)) lib)
                    (check-equal? (file->bytes (build-path lib "libcublasLt.so.13"))
                                  #"libcublasLt.so.13")
                    (check-equal? (installed root) (list home)))))
