#lang racket/base

(require (only-in file/sha1 bytes->hex-string)
         (only-in file/zip zip)
         (only-in racket/file
                  delete-directory/files
                  file->bytes
                  make-directory*
                  make-temporary-directory)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path
         (only-in racket/tcp tcp-accept tcp-addresses tcp-close tcp-listen)
         (only-in rackunit
                  check-equal?
                  check-exn
                  check-false
                  check-not-false
                  check-regexp-match
                  check-true
                  test-case)
         (only-in "../private/cublas.rkt"
                  cublas-location-dir
                  cublas-location-kind
                  cublas-missing-error
                  cublas-setup
                  locate-cublas)
         (only-in "../private/cuda-wheels.rkt"
                  cuda-wheel
                  cuda-wheel-dir
                  cuda-wheel-present?
                  cuda-wheel-source
                  ensure-cuda-wheel
                  find-cuda-wheel
                  read-cuda-wheel)
         (only-in "../private/resource.rkt" with-release))

(define-runtime-path cuda-wheels "../private/cuda-wheels.rktd")

(define cublas-wheel (read-cuda-wheel cuda-wheels "nvidia-cublas"))

(define libraries '("libcublasLt.so.13" "libcublas.so.13"))

(define (call-with-temp proc)
  (with-release ([dir (make-temporary-directory "raft-cuda-~a") delete-directory/files])
    (proc dir)))

(define (call-with-env bindings thunk)
  (parameterize ([current-environment-variables
                  (environment-variables-copy (current-environment-variables))])
    (for ([binding (in-list bindings)])
      (environment-variables-set! (current-environment-variables)
                                  (string->bytes/utf-8 (car binding))
                                  (and (cdr binding) (string->bytes/utf-8 (cdr binding)))))
    (thunk)))

(define (make-wheel! dir)
  (define stage (build-path dir "stage"))
  (define lib (build-path stage "nvidia" "cu13" "lib"))
  (make-directory* lib)
  (for ([name (in-list (cons "libnvblas.so.13" libraries))])
    (call-with-output-file (build-path lib name) (lambda (out) (write-string name out))))
  (define file (build-path dir "fake.whl"))
  (parameterize ([current-directory stage])
    (zip file "nvidia"))
  (define bytes (file->bytes file))
  (cuda-wheel "nvidia-cublas"
              "13.4.0.1"
              "https://example.invalid/packages/fake.whl"
              (bytes->hex-string (call-with-input-file file sha256-bytes))
              (bytes-length bytes)
              (for/list ([name (in-list libraries)])
                (string-append "nvidia/cu13/lib/" name))))

(define (file-base dir)
  (string-append "file://" (path->string dir)))

(define (fetch wheel root base)
  (call-with-env (list (cons "RAFT_CUDA_WHEEL_URL_BASE" base))
                 (lambda () (ensure-cuda-wheel wheel root))))

(define (nothing-in-place? root wheel)
  (define home (build-path (cuda-wheel-dir root wheel) 'up))
  (define cu13 (build-path home 'up))
  (and (not (find-cuda-wheel wheel (list root)))
       (not (directory-exists? (simplify-path home)))
       (or (not (directory-exists? (simplify-path cu13)))
           (null? (directory-list (simplify-path cu13))))))

(define (call-with-server respond proc)
  (define listener (tcp-listen 0 4 #t "127.0.0.1"))
  (define-values (_host port _peer _peer-port) (tcp-addresses listener #t))
  (define server
    (thread (lambda ()
              (let loop ()
                (define-values (in out) (tcp-accept listener))
                (let skip ()
                  (define line (read-line in 'return-linefeed))
                  (when (and (string? line) (positive? (string-length line)))
                    (skip)))
                (respond out)
                (close-output-port out)
                (close-input-port in)
                (loop)))))
  (with-release ([_
                  server
                  (lambda (t)
                    (kill-thread t)
                    (tcp-close listener))])
    (proc (format "http://127.0.0.1:~a" port))))

(define (closed-port-base)
  (define listener (tcp-listen 0 4 #t "127.0.0.1"))
  (define-values (_host port _peer _peer-port) (tcp-addresses listener #t))
  (tcp-close listener)
  (format "http://127.0.0.1:~a" port))

(test-case "the pin is the wheel's two cuBLAS libraries, Lt first"
  (check-equal? (cuda-wheel-dir "/r" cublas-wheel)
                (build-path "/r" "rapids" "cu13" "nvidia-cublas-13.4.0.1" "lib"))
  (check-regexp-match #rx"^https://files[.]pythonhosted[.]org/.*/nvidia_cublas-13[.]4[.]0[.]1-"
                      (cuda-wheel-source cublas-wheel)))

(test-case "RAFT_CUDA_WHEEL_URL_BASE serves the pinned file name from elsewhere"
  (check-equal? (call-with-env (list (cons "RAFT_CUDA_WHEEL_URL_BASE" "file:///cache/"))
                               (lambda () (cuda-wheel-source cublas-wheel)))
                "file:///cache/nvidia_cublas-13.4.0.1-py3-none-manylinux_2_27_x86_64.whl"))

(test-case "a fetch with the pinned hash unpacks only the two libraries"
  (call-with-temp
   (lambda (dir)
     (define wheel (make-wheel! dir))
     (define root (build-path dir "root"))
     (define lib (fetch wheel root (file-base dir)))
     (check-equal? lib (cuda-wheel-dir root wheel))
     (check-equal? (sort (map path->string (directory-list lib)) string<?) (sort libraries string<?))
     (check-equal? (file->bytes (build-path lib "libcublasLt.so.13")) #"libcublasLt.so.13")
     (check-equal? (directory-list (build-path lib 'up 'up))
                   (list (string->path "nvidia-cublas-13.4.0.1")))
     (check-equal? (find-cuda-wheel wheel (list (build-path dir "elsewhere") root)) lib))))

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
                                        (fprintf out
                                                 "HTTP/1.1 200 OK\r\nContent-Length: ~a\r\n\r\n"
                                                 (bytes-length body))
                                        (write-bytes body out 0 (quotient (bytes-length body) 2)))
                                      (lambda (base)
                                        (check-exn exn:fail? (lambda () (fetch wheel root base)))
                                        (check-true (nothing-in-place? root wheel)))))))

(test-case "an HTTP error is named and leaves nothing in place"
  (call-with-temp (lambda (dir)
                    (define wheel (make-wheel! dir))
                    (define root (build-path dir "root"))
                    (call-with-server
                     (lambda (out)
                       (write-string "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n" out))
                     (lambda (base)
                       (check-exn #rx"answered HTTP 404" (lambda () (fetch wheel root base)))
                       (check-true (nothing-in-place? root wheel)))))))

(test-case "an HTTP download with the pinned hash is unpacked"
  (call-with-temp
   (lambda (dir)
     (define wheel (make-wheel! dir))
     (define body (file->bytes (build-path dir "fake.whl")))
     (define root (build-path dir "root"))
     (call-with-server
      (lambda (out)
        (fprintf out "HTTP/1.1 200 OK\r\nContent-Length: ~a\r\n\r\n" (bytes-length body))
        (write-bytes body out))
      (lambda (base) (check-true (cuda-wheel-present? (fetch wheel root base) wheel)))))))

(test-case "a fetch killed before its rename does not count, and the next one replaces it"
  (call-with-temp (lambda (dir)
                    (define wheel (make-wheel! dir))
                    (define root (build-path dir "root"))
                    (define part
                      (build-path root "rapids" "cu13" "nvidia-cublas-13.4.0.1.part" "lib"))
                    (make-directory* part)
                    (for ([name (in-list libraries)])
                      (call-with-output-file (build-path part name) void))
                    (check-false (find-cuda-wheel wheel (list root)))
                    (check-not-false (fetch wheel root (file-base dir)))
                    (check-equal? (directory-list (build-path root "rapids" "cu13"))
                                  (list (string->path "nvidia-cublas-13.4.0.1"))))))

(test-case "libraries already in place are not fetched again"
  (call-with-temp (lambda (dir)
                    (define wheel (make-wheel! dir))
                    (define root (build-path dir "root"))
                    (define lib (fetch wheel root (file-base dir)))
                    (delete-file (build-path dir "fake.whl"))
                    (check-equal? (fetch wheel root (file-base dir)) lib))))

(define (cublas-env #:override (override #f) #:base [base #f])
  (list (cons "RAFT_CUDA_LIB_PATH" (and override (path->string override)))
        (cons "RAFT_CUDA_WHEEL_URL_BASE" base)))

(define (stage-libraries! dir)
  (make-directory* dir)
  (for ([name (in-list libraries)])
    (call-with-output-file (build-path dir name) void))
  dir)

(define (located dir #:override (override #f) #:system? system?)
  (call-with-env (cublas-env #:override override)
                 (lambda ()
                   (define location (locate-cublas #:system? (lambda () system?) #:roots (list dir)))
                   (list (cublas-location-kind location) (cublas-location-dir location)))))

(test-case "RAFT_CUDA_LIB_PATH wins over a system CUDA 13, which wins over the fetched copy"
  (call-with-temp (lambda (dir)
                    (define override (stage-libraries! (build-path dir "override")))
                    (define fetched (stage-libraries! (cuda-wheel-dir dir cublas-wheel)))
                    (check-equal? (located dir #:override override #:system? #t)
                                  (list 'override (simplify-path override)))
                    (check-equal? (located dir #:system? #t) (list 'system #f))
                    (check-equal? (located dir #:system? #f) (list 'fetched fetched))
                    (delete-directory/files fetched)
                    (check-equal? (located dir #:system? #f) (list 'missing #f))
                    (check-equal? (located dir #:override (build-path dir "empty") #:system? #t)
                                  (list 'bad-override (simplify-path (build-path dir "empty")))))))

(define (setup-output root #:platform [platform "x86_64-linux"] #:base base)
  (define out (open-output-string))
  (define warning
    (call-with-env
     (cublas-env #:base base)
     (lambda ()
       (parameterize ([current-output-port out])
         (cublas-setup root #:roots (list root) #:platform platform #:system? (lambda () #f))))))
  (list warning (get-output-string out)))

(test-case "offline, setup warns with the cause and the retry command and does not raise"
  (call-with-temp
   (lambda (dir)
     (define root (build-path dir "root"))
     (define result (setup-output root #:base (closed-port-base)))
     (check-regexp-match #rx"^could not fetch cuBLAS: " (car result))
     (check-regexp-match #rx"retry with `racket -l- raft/fetch-cuda`" (car result))
     (check-regexp-match #rx"RAFT_CUDA_LIB_PATH" (car result))
     (check-regexp-match #rx"^raft: fetching cuBLAS 13[.]4[.]0[.]1 [(]404 MB[)] from http://127"
                         (cadr result))
     (check-true (nothing-in-place? root cublas-wheel)))))

(test-case "off x86_64-linux, setup fetches nothing"
  (call-with-temp
   (lambda (dir)
     (define root (build-path dir "root"))
     (check-equal? (setup-output root #:platform "aarch64-macosx" #:base (closed-port-base))
                   (list #f ""))
     (check-false (directory-exists? root)))))

(test-case "the loader's missing-cuBLAS message names the three ways to provide it"
  (define message (cublas-missing-error (list (string->path "/u") (string->path "/i"))))
  (check-regexp-match
   #rx"^cuBLAS from CUDA 13 is not installed: raft needs libcublasLt[.]so[.]13 and libcublas[.]so[.]13\n"
   message)
  (check-regexp-match
   #rx"\n  looked in: RAFT_CUDA_LIB_PATH [(]unset[)], the system library path, /u/rapids/cu13/nvidia-cublas-13[.]4[.]0[.]1/lib, /i/rapids/cu13/nvidia-cublas-13[.]4[.]0[.]1/lib\n"
   message)
  (check-regexp-match
   #rx"fetch it with `racket -l- raft/fetch-cuda`, set RAFT_CUDA_LIB_PATH to a directory holding them, or install CUDA 13"
   message))
