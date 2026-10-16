#lang racket/base

(require (only-in ffi/unsafe ffi-lib)
         (only-in racket/lazy-require lazy-require)
         (only-in racket/match match match*)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path
         (only-in racket/string string-join)
         (only-in "cuda-wheels.rkt"
                  cuda-wheel-dir
                  cuda-wheel-libraries
                  cuda-wheel-roots
                  cuda-wheel-size
                  cuda-wheel-version
                  locate-cuda-wheel
                  read-cuda-wheels)
         (only-in "exn.rkt" exn:fail:raft exn:fail:raft?))

(lazy-require ["cuda-wheel-fetch.rkt" (cuda-wheel-source ensure-cuda-wheel)])

(provide (struct-out cublas-location)
         cublas-error
         cublas-libraries
         cublas-setup-warning
         fetch-cublas
         locate-cublas)

(define-runtime-path cuda-wheels "cuda-wheels.rktd")

(define cublas-wheel (hash-ref (read-cuda-wheels cuda-wheels) "nvidia-cublas"))

(define cublas-libraries (cuda-wheel-libraries cublas-wheel))

(define fetch-command "racket -l- raft/fetch-cuda")

(define holding (string-join cublas-libraries " and "))

(define (cublas-error kind . details)
  (match (cons kind details)
    [(list 'missing roots)
     (format
      "cuBLAS from CUDA 13 is not installed: raft needs ~a\n  looked in: RAFT_CUDA_LIB_PATH (unset), the system library path, ~a\n  fetch it with `~a`, set RAFT_CUDA_LIB_PATH to a directory holding them, or install CUDA 13 where the system loader finds it"
      holding
      (string-join (for/list ([root (in-list roots)])
                     (path->string (cuda-wheel-dir root cublas-wheel)))
                   ", ")
      fetch-command)]
    [(list 'override dir)
     (format
      "RAFT_CUDA_LIB_PATH points at ~a, which does not hold ~a\n  unset it to use a system CUDA 13 or the copy `~a` fetches"
      dir
      holding
      fetch-command)]
    [(list 'fetch cause)
     (format
      "could not fetch cuBLAS: ~a\n  retry with `~a`, or set RAFT_CUDA_LIB_PATH to a directory holding ~a"
      cause
      fetch-command
      holding)]
    [(list 'unloadable name dir said)
     (format "~a would not load\n  found in: ~a\n  the loader said: ~a" name dir said)]))

(struct cublas-location (kind dir))

(define (system-cublas?)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (for ([name (in-list cublas-libraries)])
      (match name
        [(regexp #rx"^(.+)[.]so[.](.+)$" (list _ stem version)) (ffi-lib stem (list version))]))
    #t))

(define (override-dir)
  (match (getenv "RAFT_CUDA_LIB_PATH")
    [(or #f "") #f]
    [dir (simplify-path (path->complete-path dir))]))

(define (holds-cublas? dir)
  (for/and ([name (in-list cublas-libraries)])
    (file-exists? (build-path dir name))))

(define (locate-cublas #:system? [system? system-cublas?] #:roots [roots (cuda-wheel-roots)])
  (define override (override-dir))
  (cond
    [(and override (holds-cublas? override)) (cublas-location 'override override)]
    [override (cublas-location 'bad-override override)]
    [(system?) (cublas-location 'system #f)]
    [(locate-cuda-wheel cublas-wheel roots)
     =>
     (lambda (dir) (cublas-location 'fetched dir))]
    [else (cublas-location 'missing #f)]))

(define (url-base)
  (match (getenv "RAFT_CUDA_WHEEL_URL_BASE")
    [(or #f "") #f]
    [base base]))

(define (raise-fetch-failure e)
  (raise (exn:fail:raft (cublas-error 'fetch (exn-message e)) (exn-continuation-marks e) 'generic)))

(define (fetch-cublas root)
  (match (locate-cuda-wheel cublas-wheel (list root))
    [#f
     (with-handlers ([exn:fail? raise-fetch-failure])
       (printf "raft: fetching cuBLAS ~a (~a MB) from ~a\n"
               (cuda-wheel-version cublas-wheel)
               (round (/ (cuda-wheel-size cublas-wheel) 1000000))
               (cuda-wheel-source cublas-wheel (url-base)))
       (ensure-cuda-wheel cublas-wheel root #:url-base (url-base)))]
    [dir dir]))

(define (cublas-setup-warning root
                              #:roots [roots (cuda-wheel-roots)]
                              #:platform [platform (path->string (system-library-subpath #f))]
                              #:system? [system? system-cublas?])
  (match* (platform (locate-cublas #:system? system? #:roots roots))
    [(_ (cublas-location 'bad-override dir)) (cublas-error 'override dir)]
    [("x86_64-linux" (cublas-location 'missing _))
     (with-handlers ([exn:fail:raft? exn-message])
       (printf "raft: cuBLAS is in ~a\n" (fetch-cublas root))
       #f)]
    [(_ (cublas-location 'missing _)) #f]
    [(_ (cublas-location (or 'override 'system 'fetched) _)) #f]))
