#lang racket/base

(require (only-in ffi/unsafe ffi-lib)
         (only-in racket/match match match*)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path
         (only-in racket/string string-join)
         (only-in "cuda-wheels.rkt"
                  cuda-wheel-dir
                  cuda-wheel-libraries
                  cuda-wheel-present?
                  cuda-wheel-roots
                  cuda-wheel-size
                  cuda-wheel-source
                  cuda-wheel-version
                  ensure-cuda-wheel
                  find-cuda-wheel
                  read-cuda-wheel))

(provide (struct-out cublas-location)
         cublas-libraries
         cublas-missing-error
         cublas-override-error
         cublas-setup
         fetch-command
         fetch-cublas
         locate-cublas)

(define-runtime-path cuda-wheels "cuda-wheels.rktd")

(define cublas-wheel (read-cuda-wheel cuda-wheels "nvidia-cublas"))

(define cublas-libraries (cuda-wheel-libraries cublas-wheel))

(define fetch-command "racket -l- raft/fetch-cuda")

(define holding (string-join cublas-libraries " and "))

(struct cublas-location (kind dir))

(define (system-cublas?)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (ffi-lib "libcublasLt" '("13"))
    #t))

(define (override-dir)
  (match (getenv "RAFT_CUDA_LIB_PATH")
    [(or #f "") #f]
    [dir (simplify-path (path->complete-path dir))]))

(define (locate-cublas #:system? [system? system-cublas?] #:roots [roots (cuda-wheel-roots)])
  (define override (override-dir))
  (cond
    [(and override (cuda-wheel-present? override cublas-wheel)) (cublas-location 'override override)]
    [override (cublas-location 'bad-override override)]
    [(system?) (cublas-location 'system #f)]
    [(find-cuda-wheel cublas-wheel roots)
     =>
     (lambda (dir) (cublas-location 'fetched dir))]
    [else (cublas-location 'missing #f)]))

(define (cublas-missing-error [roots (cuda-wheel-roots)])
  (format
   "cuBLAS from CUDA 13 is not installed: raft needs ~a\n  looked in: RAFT_CUDA_LIB_PATH (unset), the system library path, ~a\n  fetch it with `~a`, set RAFT_CUDA_LIB_PATH to a directory holding them, or install CUDA 13 where the system loader finds it"
   holding
   (string-join (for/list ([root (in-list roots)])
                  (path->string (cuda-wheel-dir root cublas-wheel)))
                ", ")
   fetch-command))

(define (cublas-override-error dir)
  (format
   "RAFT_CUDA_LIB_PATH points at ~a, which does not hold ~a\n  unset it to use a system CUDA 13 or the copy `~a` fetches"
   dir
   holding
   fetch-command))

(define (fetch-failure e)
  (format
   "could not fetch cuBLAS: ~a\n  retry with `~a`, or set RAFT_CUDA_LIB_PATH to a directory holding ~a"
   (exn-message e)
   fetch-command
   holding))

(define (fetch-cublas root)
  (define dir (cuda-wheel-dir root cublas-wheel))
  (cond
    [(cuda-wheel-present? dir cublas-wheel)
     (printf "raft: cuBLAS is in ~a\n" dir)
     #f]
    [else
     (printf "raft: fetching cuBLAS ~a (~a MB) from ~a\n"
             (cuda-wheel-version cublas-wheel)
             (quotient (cuda-wheel-size cublas-wheel) 1000000)
             (cuda-wheel-source cublas-wheel))
     (with-handlers ([exn:fail? fetch-failure])
       (printf "raft: cuBLAS is in ~a\n" (ensure-cuda-wheel cublas-wheel root))
       #f)]))

(define (cublas-setup root
                      #:roots [roots (cuda-wheel-roots)]
                      #:platform [platform (path->string (system-library-subpath #f))]
                      #:system? [system? system-cublas?])
  (match* (platform (locate-cublas #:system? system? #:roots roots))
    [(_ (cublas-location 'bad-override dir)) (cublas-override-error dir)]
    [("x86_64-linux" (cublas-location 'missing _)) (fetch-cublas root)]
    [(_ _) #f]))
