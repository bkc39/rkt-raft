#lang racket/base
;; Spike #32 measurements b, c, e, f: racket fit.rkt <ticker|break|kill|serial> [poller|fd-evt]
(require (only-in kmeans-canary blobs kmeans-fit kmeans-predict)
         (only-in racket/match match)
         (only-in raft current-device-resources device-resources shape)
         (only-in raft/private/foreign/memory buffer-drop-count resources-drop-count)
         (only-in raft/tests/private/collect drain-finalizers!)
         (only-in raft/tests/private/ticker call-with-ticker)
         (only-in raft/unsafe
                  current-job-breaks
                  current-job-log
                  current-job-wait
                  executor-threads
                  jobs-in-flight
                  jobs-live
                  now-ns))

(define args (current-command-line-arguments))
(define what (vector-ref args 0))
(define mode (string->symbol (if (> (vector-length args) 1) (vector-ref args 1) "poller")))

(define r (current-device-resources))
(define-values (X truth) (blobs 2500000 32 #:centers 64 #:cluster-std 4.0 #:seed 1 #:resources r))

(define (long-fit [resources r])
  (kmeans-fit X
              #:n-clusters 64
              #:init 'random
              #:n-init 1
              #:max-iter 100
              #:tol 1e-12
              #:seed 1
              #:resources resources))

(define (ms-since start)
  (- (current-inexact-monotonic-milliseconds) start))

(define (timed thunk)
  (define start (current-inexact-monotonic-milliseconds))
  (call-with-values thunk (lambda results (values (ms-since start) results))))

(define (fit-checked [resources r])
  (define-values (centroids inertia n-iter) (long-fit resources))
  (list (shape centroids) inertia n-iter))

(define (sanity)
  (define-values (centroids inertia n-iter) (long-fit))
  (define-values (labels score) (kmeans-predict centroids X #:resources r))
  (list (shape centroids) (shape labels) (> inertia 0) (> score 0) n-iter))

(parameterize ([current-job-wait mode])
  (long-fit)
  (match what
    ["ticker"
     (for ([_ (in-range 3)])
       (define-values (ticks elapsed+results)
         (call-with-ticker (lambda () (call-with-values (lambda () (timed long-fit)) list))))
       (printf "ticker (~a): ~a ticks of 10 ms during a ~a ms fit\n"
               mode
               ticks
               (round (car elapsed+results))))]
    ["break"
     (define-values (unbroken _) (timed long-fit))
     (for ([breaks (in-list '(deferred abandon))])
       (define start (current-inexact-monotonic-milliseconds))
       (define broken-at (box #f))
       (define in-flight-at-break (box #f))
       (define caller
         (thread (lambda ()
                   (parameterize ([current-job-breaks breaks])
                     (with-handlers ([exn:break? (lambda (_)
                                                   (set-box! broken-at (ms-since start))
                                                   (set-box! in-flight-at-break (jobs-in-flight)))])
                       (long-fit))))))
       (sleep 0.05)
       (break-thread caller)
       (thread-wait caller)
       (define after-wait (ms-since start))
       (define-values (next-ms next) (timed sanity))
       (printf
        "break (~a, ~a): unbroken fit ~a ms; break sent at 50 ms, raised at ~a ms; jobs in flight when raised ~a; next fit+predict ~a ms (waited behind the abandoned job: ~a) -> ~a; live jobs ~a\n"
        mode
        breaks
        (round unbroken)
        (and (unbox broken-at) (round (unbox broken-at)))
        (unbox in-flight-at-break)
        (round next-ms)
        (if (eq? breaks 'abandon) "yes, same resources" "n/a")
        next
        (jobs-live)))]
    ["kill"
     (drain-finalizers!)
     (define (counters)
       (list 'buffers-dropped
             (buffer-drop-count)
             'resources-dropped
             (resources-drop-count)
             'jobs-in-flight
             (jobs-in-flight)
             'jobs-live
             (jobs-live)
             'workers
             (executor-threads)))
     (printf "kill: before          ~a\n" (counters))
     (define caller (thread (lambda () (long-fit (current-device-resources)))))
     (sleep 0.1)
     (kill-thread caller)
     (drain-finalizers!)
     (printf "kill: killed + 3 GCs  ~a\n" (counters))
     (let loop ()
       (unless (zero? (jobs-in-flight))
         (sleep 0.02)
         (loop)))
     (drain-finalizers!)
     (printf "kill: job finished    ~a\n" (counters))
     (printf "kill: a later fit     ~a\n" (sanity))
     (drain-finalizers!)
     (printf "kill: end             ~a\n" (counters))]
    ["serial"
     (define log (box '()))
     (define (logged tag)
       (lambda (submitted started finished)
         (set-box! log (cons (list tag submitted started finished) (unbox log)))))
     (define (pair resources-a resources-b label)
       (set-box! log '())
       (define t0 (now-ns))
       (define threads
         (for/list ([tag (in-list '(A B))]
                    [res (in-list (list resources-a resources-b))])
           (thread (lambda ()
                     (parameterize ([current-job-log (logged tag)])
                       (fit-checked res)))
                   #:keep 'results)))
       (define results (map thread-wait threads))
       (printf "serial (~a): results ~a\n" label results)
       (for ([row (in-list (sort (unbox log) < #:key caddr))])
         (match row
           [(list tag s b f)
            (printf "  ~a submitted ~a ms, started ~a ms, finished ~a ms (ran ~a ms)\n"
                    tag
                    (round (/ (- s t0) 1e6))
                    (round (/ (- b t0) 1e6))
                    (round (/ (- f t0) 1e6))
                    (round (/ (- f b) 1e6)))])))
     (printf "serial: one fit alone -> ~a\n" (fit-checked r))
     (pair r r "two threads, one resources")
     (define r2 (device-resources))
     (parameterize ([current-job-log void])
       (long-fit r2))
     (pair r r2 "two threads, two resources")
     (printf "workers: ~a\n" (executor-threads))]))
