#lang racket/base

(require (only-in file/sha1 bytes->hex-string)
         (only-in file/zip zip)
         (only-in racket/file
                  delete-directory/files
                  file->bytes
                  make-directory*
                  make-temporary-directory)
         (only-in racket/tcp tcp-accept tcp-addresses tcp-close tcp-listen)
         (only-in "../../private/cuda-wheels.rkt" cuda-wheel wheel-member)
         (only-in "../../private/resource.rkt" with-release))

(provide call-with-server
         call-with-temp
         closed-port-base
         file-base
         http-response
         installed
         libraries
         make-wheel!
         sized-file!)

(define libraries '("libcublasLt.so.13" "libcublas.so.13"))

(define (call-with-temp proc)
  (with-release ([dir (make-temporary-directory "raft-cuda-~a") delete-directory/files])
    (proc dir)))

(define (sized-file! file size)
  (call-with-output-file file #:exists 'truncate (lambda (out) (file-truncate out size)))
  file)

(define (make-wheel! dir)
  (define stage (build-path dir "stage"))
  (define lib (build-path stage "nvidia" "cu13" "lib"))
  (make-directory* lib)
  (for ([name (in-list (cons "libnvblas.so.13" libraries))])
    (call-with-output-file (build-path lib name) (lambda (out) (write-string name out))))
  (define file (build-path dir "fake.whl"))
  (parameterize ([current-directory stage])
    (zip file "nvidia"))
  (cuda-wheel "nvidia-cublas"
              "13.4.0.1"
              "cu13"
              "https://example.invalid/packages/fake.whl"
              (bytes->hex-string (call-with-input-file file sha256-bytes))
              (file-size file)
              (for/list ([name (in-list libraries)])
                (wheel-member (string-append "nvidia/cu13/lib/" name) (string-length name)))))

(define (file-base dir)
  (string-append "file://" (path->string dir)))

(define (http-response status body)
  (bytes-append (string->bytes/utf-8
                 (format "HTTP/1.1 ~a\r\nContent-Length: ~a\r\n\r\n" status (bytes-length body)))
                body))

(define (installed root)
  (define home (build-path root "rapids" "cu13"))
  (if (directory-exists? home)
      (sort (for/list ([entry (in-list (directory-list home))]
                       #:unless (regexp-match? #rx"[.]lock$" (path->string entry)))
              (path->string entry))
            string<?)
      '()))

(define (serve respond in out)
  (let skip ()
    (define line (read-line in 'return-linefeed))
    (when (and (string? line) (positive? (string-length line)))
      (skip)))
  (respond out)
  (close-output-port out)
  (close-input-port in))

(define (start-server respond)
  (define custodian (make-custodian))
  (parameterize ([current-custodian custodian])
    (define listener (tcp-listen 0 8 #t "127.0.0.1"))
    (define-values (_host port _peer _peer-port) (tcp-addresses listener #t))
    (thread (lambda ()
              (let loop ()
                (define-values (in out) (tcp-accept listener))
                (thread (lambda () (serve respond in out)))
                (loop))))
    (cons custodian port)))

(define (call-with-server respond proc)
  (with-release ([server (start-server respond) (lambda (s) (custodian-shutdown-all (car s)))])
    (proc (format "http://127.0.0.1:~a" (cdr server)))))

(define (closed-port-base)
  (define listener (tcp-listen 0 4 #t "127.0.0.1"))
  (define-values (_host port _peer _peer-port) (tcp-addresses listener #t))
  (tcp-close listener)
  (format "http://127.0.0.1:~a" port))
