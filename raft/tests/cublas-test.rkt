#lang racket/base

(require (only-in compiler/find-exe find-exe)
         (only-in racket/file delete-directory/files make-directory*)
         (only-in racket/port port->string)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path
         (only-in rackunit check-equal? check-false check-regexp-match fail test-case)
         (only-in "../private/cublas.rkt"
                  cublas-error
                  cublas-location-dir
                  cublas-location-kind
                  cublas-setup-warning
                  locate-cublas)
         (only-in "../private/cuda-wheels.rkt"
                  cuda-wheel-dir
                  cuda-wheel-members
                  read-cuda-wheels
                  wheel-member-name
                  wheel-member-size)
         (only-in "private/cuda-wheels.rkt"
                  call-with-env
                  call-with-temp
                  closed-port-base
                  installed
                  libraries
                  sized-file!)
         (only-in "private/native-package.rkt" cublas-dir))

(define-runtime-path cuda-wheels "../private/cuda-wheels.rktd")
(define-runtime-path cublas-module "../private/cublas.rkt")

(define cublas-wheel (hash-ref (read-cuda-wheels cuda-wheels) "nvidia-cublas"))

(define (cublas-env #:override (override #f) #:base [base #f])
  (list (cons "RAFT_CUDA_LIB_PATH" (and override (path->string override)))
        (cons "RAFT_CUDA_WHEEL_URL_BASE" base)))

(define (stage-override! dir)
  (make-directory* dir)
  (for ([name (in-list libraries)])
    (call-with-output-file (build-path dir name) void))
  dir)

(define (stage-fetched! dir)
  (make-directory* dir)
  (for ([member (in-list (cuda-wheel-members cublas-wheel))])
    (sized-file! (build-path dir (wheel-member-name member)) (wheel-member-size member)))
  dir)

(define (located dir #:override (override #f) #:system? system?)
  (call-with-env (cublas-env #:override override)
                 (lambda ()
                   (define location (locate-cublas #:system? (lambda () system?) #:roots (list dir)))
                   (list (cublas-location-kind location) (cublas-location-dir location)))))

(test-case "RAFT_CUDA_LIB_PATH wins over a system CUDA 13, which wins over the fetched copy"
  (call-with-temp (lambda (dir)
                    (define override (stage-override! (build-path dir "override")))
                    (define fetched (stage-fetched! (cuda-wheel-dir dir cublas-wheel)))
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
    (call-with-env (cublas-env #:base base)
                   (lambda ()
                     (parameterize ([current-output-port out])
                       (cublas-setup-warning root
                                             #:roots (list root)
                                             #:platform platform
                                             #:system? (lambda () #f))))))
  (list warning (get-output-string out)))

(test-case "offline, setup warns with the cause and the retry command and does not raise"
  (call-with-temp
   (lambda (dir)
     (define root (build-path dir "root"))
     (define result (setup-output root #:base (closed-port-base)))
     (check-regexp-match #rx"^could not fetch cuBLAS: " (car result))
     (check-regexp-match #rx"retry with `racket -l- raft/fetch-cuda`" (car result))
     (check-regexp-match #rx"RAFT_CUDA_LIB_PATH" (car result))
     (check-regexp-match #rx"^raft: fetching cuBLAS 13[.]4[.]0[.]1 [(]405 MB[)] from http://127"
                         (cadr result))
     (check-equal? (installed root) '()))))

(test-case "off x86_64-linux, setup fetches nothing"
  (call-with-temp
   (lambda (dir)
     (define root (build-path dir "root"))
     (check-equal? (setup-output root #:platform "aarch64-macosx" #:base (closed-port-base))
                   (list #f ""))
     (check-false (directory-exists? root)))))

(test-case "the loader's missing-cuBLAS message names the three ways to provide it"
  (define message (cublas-error 'missing (list (string->path "/u") (string->path "/i"))))
  (check-regexp-match
   #rx"^cuBLAS from CUDA 13 is not installed: raft needs libcublasLt[.]so[.]13 and libcublas[.]so[.]13\n"
   message)
  (check-regexp-match
   #rx"\n  looked in: RAFT_CUDA_LIB_PATH [(]unset[)], the system library path, /u/rapids/cu13/nvidia-cublas-13[.]4[.]0[.]1/lib, /i/rapids/cu13/nvidia-cublas-13[.]4[.]0[.]1/lib\n"
   message)
  (check-regexp-match
   #rx"fetch it with `racket -l- raft/fetch-cuda`, set RAFT_CUDA_LIB_PATH to a directory holding them, or install CUDA 13"
   message))

(define (system-probe library-path)
  (call-with-temp
   (lambda (dir)
     (define program (build-path dir "probe.rkt"))
     (call-with-output-file program
                            (lambda (out)
                              (write `(module probe racket/base
                                        (require (only-in (file ,(path->string cublas-module))
                                                          cublas-location-kind
                                                          locate-cublas))
                                        (write (cublas-location-kind (locate-cublas #:roots '()))))
                                     out)))
     (define-values (process stdout stdin stderr)
       (call-with-env (list (cons "LD_LIBRARY_PATH" (path->string library-path))
                            (cons "RAFT_CUDA_LIB_PATH" #f))
                      (lambda () (subprocess #f #f #f (find-exe) program))))
     (close-output-port stdin)
     (define err (thread (lambda () (port->string stderr #:close? #t)) #:keep 'results))
     (define result (read stdout))
     (close-input-port stdout)
     (cond
       [(sync/timeout 60 process)
        (check-equal? (subprocess-status process) 0 (thread-wait err))
        result]
       [else
        (subprocess-kill process #t)
        (fail "the system probe was still running after 60 s")]))))

(define (link-dir! dir names)
  (make-directory* dir)
  (for ([name (in-list names)])
    (make-file-or-directory-link (build-path cublas-dir (cdr name)) (build-path dir (car name))))
  dir)

(test-case "the system probe needs both CUDA 13 libraries on the library path"
  (cond
    [cublas-dir
     (call-with-temp (lambda (dir)
                       (define both
                         (link-dir! (build-path dir "both") (map cons libraries libraries)))
                       (define older
                         (link-dir! (build-path dir "older")
                                    (for*/list ([major (in-list '("12" "11"))]
                                                [name (in-list libraries)])
                                      (cons (regexp-replace #rx"13$" name major) name))))
                       (define lt-only
                         (link-dir! (build-path dir "lt-only")
                                    (list (cons "libcublasLt.so.13" "libcublasLt.so.13"))))
                       (check-equal? (system-probe both) 'system)
                       (check-equal? (system-probe older) 'missing)
                       (check-equal? (system-probe lt-only) 'missing)))]
    [else (displayln "SKIP: the system probe test needs the native library's cuBLAS")]))
