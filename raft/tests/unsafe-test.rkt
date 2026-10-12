#lang racket/base

(require (for-syntax racket/base)
         (only-in ffi/unsafe
                  _fun
                  _int
                  _int32
                  _int64
                  _uint32
                  _uintptr
                  cpointer?
                  get-ffi-obj
                  ptr-equal?
                  ptr-ref
                  void/reference-sink)
         (only-in ffi/unsafe/atomic end-atomic start-atomic)
         (only-in racket/generator in-generator yield)
         (only-in rackunit
                  check-equal?
                  check-exn
                  check-false
                  check-not-equal?
                  check-not-false
                  check-pred
                  check-true
                  test-case)
         (only-in syntax/macro-testing convert-syntax-error)
         (only-in "../main.rkt"
                  current-device-resources
                  device-matrix
                  device-resources
                  device-vector
                  exn:fail:raft
                  exn:fail:raft-kind
                  exn:fail:raft?
                  list*->device-matrix
                  raft-abi
                  raft-abi-handle-size
                  raft-abi-version
                  with-device-resources)
         (only-in "../private/array.rkt" release-array!)
         (only-in "../private/foreign/array.rkt"
                  view-data
                  view-device
                  view-dtype-code
                  view-shape
                  view-strides)
         (only-in "../private/foreign/memory.rkt" buffer-drop-count resources-drop-count)
         (only-in "../private/resource.rkt" drop-owner! hold-owner! with-release)
         (only-in "../private/resources.rkt" resources-handle)
         (only-in "../unsafe.rkt"
                  raft-abi-pointer
                  resources->handle-pointer
                  status-checker
                  with-array-views)
         (only-in "private/collect.rkt" collect-until drain-finalizers!)
         (only-in "private/gpu.rkt" test-gpu)
         (only-in "private/probe.rkt" probe-hold! probe-release! test-probe)
         (only-in "private/raft-error.rkt" check-raft-error)
         (only-in "private/ticker.rkt" call-with-ticker))

(test-case "raft-abi-pointer points at the tag raft-abi reads"
  (define tag (raft-abi-pointer))
  (check-pred cpointer? tag)
  (check-true (ptr-equal? tag (raft-abi-pointer)))
  (define abi (raft-abi))
  (check-equal? (ptr-ref tag _int32 0) (raft-abi-version abi))
  (check-equal? (ptr-ref tag _int64 6) (raft-abi-handle-size abi)))

(test-gpu "resources->handle-pointer answers the same handle for the same resources"
  (define r (device-resources))
  (define handle (resources->handle-pointer r))
  (check-pred cpointer? handle)
  (check-true (ptr-equal? handle (resources->handle-pointer r)))
  (check-false (ptr-equal? handle (resources->handle-pointer (device-resources)))))

(test-gpu "resources->handle-pointer refuses released resources, naming itself"
  (define r (with-device-resources ([r (device-resources)]) r))
  (check-raft-error 'logic
                    "resources->handle-pointer: the device resources on device 0 were released"
                    (lambda () (resources->handle-pointer r))))

(test-gpu "with-array-views binds each array's view in the body"
  (define X (list*->device-matrix '((1 2 3) (4 5 6)) #:dtype 'float32 #:layout 'col-major))
  (define y (device-vector 4 #:dtype 'int64))
  (with-array-views ([x X] [v y])
    (check-not-false (view-data x))
    (check-equal? (list (view-dtype-code x) (view-shape x) (view-strides x) (view-device x))
                  '(0 (2 3) (1 2) 0))
    (check-equal? (list (view-dtype-code v) (view-shape v) (view-strides v)) '(3 (4) (1)))))

(test-gpu "with-array-views binds #f to #f, for optional arrays"
  (check-equal? (with-array-views ([w #f] [x (device-vector 3)])
                  (list w (and x #t)))
                '(#f #t)))

(test-gpu "with-array-views answers its body's values"
  (define-values (a b)
    (with-array-views ([x (device-vector 3)])
      (values 1 2)))
  (check-equal? (list a b) '(1 2)))

(test-gpu "a view that escapes the body is cleared"
  (define escaped (with-array-views ([x (device-vector 3)]) x))
  (check-false (view-data escaped))
  (check-equal? (view-device escaped) -1))

(test-gpu "with-array-views keeps an array reachable until the body ends"
  (drain-finalizers!)
  (define before (buffer-drop-count))
  (with-array-views ([x (device-matrix 64 64)])
    (drain-finalizers!)
    (check-equal? (buffer-drop-count) before "the array lives while its view is bound")
    (check-not-false (view-data x)))
  (drain-finalizers!)
  (check-equal? (buffer-drop-count) (add1 before) "and is freed once the body ends"))

(test-gpu "a generator resuming with-array-views raises instead of binding again"
  (check-raft-error 'logic
                    "with-array-views: cannot re-enter its body after its resources were released"
                    (lambda ()
                      (for/list ([v (in-generator (with-array-views ([x (device-vector 2)])
                                                    (yield x)
                                                    (yield x)))])
                        v))))

(test-gpu "with-array-views refuses a released array"
  (define a (device-vector 3))
  (release-array! a)
  (check-raft-error 'logic
                    "device-array: used after its release"
                    (lambda () (with-array-views ([x a]) x))))

(test-gpu "with-array-views #:resources binds the handle and keeps its resources reachable"
  (drain-finalizers!)
  (define before (resources-drop-count))
  (with-array-views #:resources [handle (device-resources)] ()
    (drain-finalizers!)
    (check-equal? (resources-drop-count) before "the resources live while the handle is bound")
    (check-pred cpointer? handle))
  (drain-finalizers!)
  (check-equal? (resources-drop-count) (add1 before) "and are freed once the body ends"))

(test-gpu "with-array-views #:resources binds the same handle resources->handle-pointer answers"
  (define r (device-resources))
  (with-array-views #:resources [handle r] ([x (device-vector 2 #:resources r)])
    (check-true (ptr-equal? handle (resources->handle-pointer r)))
    (check-not-false (view-data x))))

(test-gpu "with-array-views #:resources refuses released resources, naming itself"
  (define finished (with-device-resources ([r (device-resources)]) r))
  (check-raft-error 'logic
                    "with-array-views: the device resources on device 0 were released"
                    (lambda () (with-array-views #:resources [handle finished] () handle))))

(test-case "a name bound twice is a syntax error"
  (check-exn #rx"duplicate binding name"
             (lambda () (convert-syntax-error (with-array-views ([a #f] [a #f]) a))))
  (check-exn #rx"duplicate binding name"
             (lambda ()
               (convert-syntax-error
                (with-array-views #:resources [a (device-resources)] ([a #f]) a)))))

(test-probe "with-array-views waits for work queued on the array's stream"
  (define r (device-resources))
  (define a (device-vector 8 #:resources r))
  (define entered (box #f))
  (define released (box #f))
  (define worker
    (with-release ([held
                    (probe-hold! (resources-handle 'hold r))
                    (lambda (_)
                      (set-box! released (current-inexact-milliseconds))
                      (probe-release!))])
      (check-true held)
      (define body-thread
        (thread (lambda ()
                  (with-array-views ([x a])
                    (set-box! entered (current-inexact-milliseconds))))))
      (check-false (sync/timeout 0.2 body-thread) "the body waits while the stream is held")
      (check-false (unbox entered))
      body-thread))
  (check-not-false (sync/timeout 10 worker))
  (check-true (>= (unbox entered) (unbox released))))

(define (checker message kind)
  (status-checker (lambda () message) (lambda () kind)))

(test-case "status-checker answers the values after a zero status"
  (define check (checker #"unused" 0))
  (define-values (a b) (check 'demo (lambda () (values 0 'a 'b))))
  (check-equal? (list a b) '(a b))
  (check-equal? (call-with-values (lambda () (check 'demo (lambda () 0))) list) '()))

(test-case "status-checker raises exn:fail:raft with the library's message and kind"
  (check-raft-error 'logic
                    "kmeans-fit: X: expected float32"
                    (lambda () ((checker #"X: expected float32" 3) 'kmeans-fit (lambda () 1))))
  (check-raft-error 'out-of-memory
                    "fit: pool exhausted"
                    (lambda () ((checker "pool exhausted" 1) 'fit (lambda () (values 2 'ignored)))))
  (check-raft-error 'generic "fit: odd" (lambda () ((checker #"odd" 9) 'fit (lambda () 1))))
  (check-raft-error 'cuda
                    "fit: bad � byte"
                    (lambda () ((checker #"bad \377 byte" 'cuda) 'fit (lambda () 1)))))

(struct exn:fail:canary exn:fail:raft ())

(test-case "status-checker builds a downstream's own exception"
  (define check (status-checker (lambda () #"refused") (lambda () 3) #:exn exn:fail:canary))
  (check-exn (lambda (e)
               (and (exn:fail:canary? e)
                    (equal? (exn-message e) "blobs: refused")
                    (eq? (exn:fail:raft-kind e) 'logic)))
             (lambda () (check 'blobs (lambda () 1)))))

(test-case "status-checker reads the error only after a failure"
  (define reads 0)
  (define check
    (status-checker (lambda ()
                      (set! reads (add1 reads))
                      #"")
                    (lambda () 0)))
  (check 'demo (lambda () 0))
  (check-equal? reads 0))

(define os-thread-id (get-ffi-obj "pthread_self" #f (_fun -> _uintptr)))
(define sleep-microseconds (get-ffi-obj "usleep" #f (_fun #:blocking? #t _uint32 -> _int)))

(test-case "status-checker calls the thunk and reads the error on one other OS thread"
  (define call-thread (box #f))
  (define read-thread (box #f))
  (define check
    (status-checker (lambda ()
                      (set-box! read-thread (os-thread-id))
                      #"failed")
                    (lambda () 1)))
  (check-raft-error 'out-of-memory
                    "demo: failed"
                    (lambda ()
                      (check 'demo
                             (lambda ()
                               (set-box! call-thread (os-thread-id))
                               1))))
  (check-equal? (unbox read-thread) (unbox call-thread))
  (check-not-equal? (unbox call-thread) (os-thread-id)))

(test-case "concurrent failures each read the error of their own call"
  (define tokens (box (hash)))
  (define (record! token)
    (define id (os-thread-id))
    (let retry ([old (unbox tokens)])
      (unless (box-cas! tokens old (hash-set old id token))
        (retry (unbox tokens)))))
  (define check (status-checker (lambda () (hash-ref (unbox tokens) (os-thread-id))) (lambda () 3)))
  (define (failure-message token)
    (with-handlers ([exn:fail:raft? exn-message])
      (check 'call
             (lambda ()
               (record! token)
               (sleep-microseconds 20000)
               1))))
  (define (call-token caller attempt)
    (format "~a.~a" caller attempt))
  (define callers
    (for/list ([caller (in-range 4)])
      (thread (lambda ()
                (for/list ([attempt (in-range 10)])
                  (failure-message (call-token caller attempt))))
              #:keep 'results)))
  (for ([caller (in-list callers)]
        [index (in-naturals)])
    (check-equal? (thread-wait caller)
                  (for/list ([attempt (in-range 10)])
                    (format "call: ~a" (call-token index attempt))))))

(test-case "status-checker raises the thunk's own exception on the caller's thread"
  (define check (checker #"unused" 0))
  (check-exn #rx"^usleep: given value does not fit primitive C type"
             (lambda () (check 'demo (lambda () (sleep-microseconds -1)))))
  (check-exn #rx"^demo: contract violation"
             (lambda () (check 'demo (lambda () (raise-argument-error 'demo "fixnum?" 'x)))))
  (check-exn #rx"arity mismatch" (lambda () (check 'demo (lambda () (values))))))

(test-case "other Racket threads run during a blocking call"
  (define ticks
    (call-with-ticker (lambda ()
                        ((checker #"unused" 0) 'demo (lambda () (sleep-microseconds 300000))))))
  (check-true (> ticks 10) (format "~a ticks in 300 ms" ticks)))

(test-case "a break during the call is raised once the call returns"
  (define start (current-inexact-milliseconds))
  (define outcome (box #f))
  (define caller
    (thread (lambda ()
              (with-handlers ([exn:break? (lambda (_)
                                            (set-box! outcome
                                                      (- (current-inexact-milliseconds) start)))])
                ((checker #"unused" 0) 'demo (lambda () (sleep-microseconds 300000)))
                (set-box! outcome 'returned)))))
  (sleep 0.05)
  (break-thread caller)
  (thread-wait caller)
  (check-pred real? (unbox outcome))
  (check-true (>= (unbox outcome) 300) (format "the break arrived at ~a ms" (unbox outcome))))

(test-case "with breaks disabled a break stays pending past the call"
  (define outcome (box #f))
  (define caller
    (thread
     (lambda ()
       (with-handlers ([exn:break? (lambda (_) (set-box! outcome (cons 'broken (unbox outcome))))])
         (parameterize-break #f
                             ((checker #"unused" 0) 'demo (lambda () (sleep-microseconds 100000)))
                             (set-box! outcome '(returned)))
         (sync never-evt)))))
  (sleep 0.02)
  (break-thread caller)
  (check-not-false (sync/timeout 5 caller))
  (check-equal? (unbox outcome) '(broken returned)))

(test-case "a break pending in atomic mode waits for atomic mode to end"
  (define answer (box #f))
  (define caller
    (thread (lambda ()
              (with-handlers ([exn:break? (lambda (_) 'broken)])
                (parameterize-break
                 #f
                 (break-thread (current-thread))
                 (start-atomic)
                 (break-enabled #t)
                 (set-box! answer ((checker #"unused" 0) 'demo (lambda () (values 0 'kept))))
                 (end-atomic))))
            #:keep 'results))
  (check-equal? (list (thread-wait caller) (unbox answer)) '(broken kept)))

(define (sleep-then-mark! slept)
  (sleep-microseconds 500000)
  (set-box! slept #t)
  0)

(define (caller-holding-an-owner wills slept)
  (define owner (make-bytes 64))
  (will-register wills owner (lambda (_) 'collected))
  (thread (lambda ()
            (with-release ([view
                            (hold-owner! (box 'view) owner)
                            (lambda (view)
                              (drop-owner! view)
                              (void/reference-sink owner))])
              ((checker #"unused" 0) 'demo
                                     (lambda ()
                                       (void/reference-sink view)
                                       (sleep-then-mark! slept)))))))

(test-case "a killed caller's held owners live until its call returns"
  (define wills (make-will-executor))
  (define slept (box #f))
  (define caller (caller-holding-an-owner wills slept))
  (sleep 0.05)
  (kill-thread caller)
  (drain-finalizers!)
  (check-false (will-try-execute wills) "the owner lives while the call runs")
  (check-false (unbox slept) "checked before the call returned")
  (sleep 0.5)
  (check-equal? (collect-until (lambda () (and (unbox slept) (will-try-execute wills))))
                'collected
                "and is collected once the call returns"))

(define (drops-while-a-killed-call-runs released start-call)
  (drain-finalizers!)
  (define before (list (buffer-drop-count) (resources-drop-count)))
  (define (drops)
    (map - (list (buffer-drop-count) (resources-drop-count)) before))
  (define slept (box #f))
  (define caller (thread (lambda () (start-call slept))))
  (sleep 0.05)
  (kill-thread caller)
  (drain-finalizers!)
  (define during (drops))
  (check-false (unbox slept) "checked before the call returned")
  (sleep 0.5)
  (collect-until (lambda () (and (unbox slept) (equal? (drops) released))))
  (list during (drops)))

(test-gpu "a killed caller's arrays and resources live until its call returns"
  (check-equal? (drops-while-a-killed-call-runs
                 '(1 1)
                 (lambda (slept)
                   (define r (device-resources))
                   (with-array-views #:resources [handle r] ([x (device-matrix 64 64 #:resources r)])
                     ((checker #"unused" 0) 'demo
                                            (lambda ()
                                              (void/reference-sink handle x)
                                              (sleep-then-mark! slept))))))
                '((0 0) (1 1))))

(test-gpu "a killed caller's resources->handle-pointer keeps its resources until the call returns"
  (check-equal?
   (drops-while-a-killed-call-runs '(0 1)
                                   (lambda (slept)
                                     (define handle (resources->handle-pointer (device-resources)))
                                     ((checker #"unused" 0) 'demo
                                                            (lambda ()
                                                              (void/reference-sink handle)
                                                              (sleep-then-mark! slept)))))
   '((0 0) (0 1))))

(test-gpu "the handle pointer and views of the default resources work together"
  (define r (current-device-resources))
  (define handle (resources->handle-pointer r))
  (with-array-views ([x (device-vector 5 #:resources r)])
    (check-pred cpointer? handle)
    (check-pred cpointer? x)))
