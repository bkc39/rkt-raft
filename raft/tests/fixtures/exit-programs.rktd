#hasheq((no-jobs-exit
         .
         (module program racket/base
           (require raft raft/tests/private/probe)
           (probe-mark-atexit!)
           (exit 3)))
        (no-jobs-return
         .
         (module program racket/base
           (require raft raft/tests/private/probe)
           (probe-mark-atexit!)))
        (clean
         .
         (module program racket/base
           (require raft
                    raft/private/resources
                    raft/tests/private/gate
                    raft/tests/private/probe)
           (probe-mark-atexit!)
           (define g (closed-gate))
           (thread (lambda () (gate-job 'demo (host-resources) g)))
           (await-entry g)
           (probe-open-after! (gate-opener-fd g) 300)
           (exit 4)))
        (timeout
         .
         (module program racket/base
           (require raft
                    raft/private/resources
                    raft/tests/private/gate
                    raft/tests/private/probe)
           (probe-mark-atexit!)
           (define g (closed-gate))
           (parameterize ([current-exit-wait 0.5])
             (thread (lambda () (gate-job 'demo (host-resources) g #:timeout-ms -1))))
           (await-entry g)
           (exit 5)))
        (code
         .
         (module program racket/base
           (require raft
                    raft/private/resources
                    raft/tests/private/gate
                    raft/tests/private/probe)
           (probe-mark-atexit!)
           (define g (closed-gate))
           (parameterize ([current-exit-wait 0.5])
             (thread (lambda () (gate-job 'demo (host-resources) g #:timeout-ms -1))))
           (await-entry g)
           (define action (read (open-input-string (getenv "RAFT_EXIT_CASE"))))
           (if (eq? action 'error)
               (error 'boom "x")
               (exit action))))
        (output
         .
         (module program racket/base
           (require raft
                    raft/private/resources
                    raft/tests/private/gate
                    raft/tests/private/probe)
           (probe-mark-atexit!)
           (define g (closed-gate))
           (parameterize ([current-exit-wait 0.5])
             (thread (lambda () (gate-job 'demo (host-resources) g #:timeout-ms -1))))
           (await-entry g)
           (printf "out\n")
           (eprintf "err\n")
           (exit 5)))
        (other-thread
         .
         (module program racket/base
           (require raft
                    raft/private/resources
                    raft/tests/private/gate
                    raft/tests/private/probe)
           (probe-mark-atexit!)
           (define g (closed-gate))
           (thread (lambda () (gate-job 'demo (host-resources) g)))
           (await-entry g)
           (probe-open-after! (gate-opener-fd g) 300)
           (thread-wait (thread (lambda () (exit 6))))))
        (break-handler
         .
         (module program racket/base
           (require raft
                    raft/private/resources
                    raft/tests/private/gate
                    raft/tests/private/probe)
           (probe-mark-atexit!)
           (define g (closed-gate))
           (define main (current-thread))
           (thread (lambda ()
                     (await-entry g)
                     (probe-open-after! (gate-opener-fd g) 300)
                     (break-thread main)))
           (with-handlers ([exn:break? (lambda (_) (exit 7))])
             (gate-job 'demo (host-resources) g))))
        (killed-caller
         .
         (module program racket/base
           (require raft
                    raft/private/resources
                    raft/tests/private/gate
                    raft/tests/private/probe)
           (probe-mark-atexit!)
           (define g (closed-gate))
           (define caller (thread (lambda () (gate-job 'demo (host-resources) g))))
           (await-entry g)
           (kill-thread caller)
           (probe-open-after! (gate-opener-fd g) 300)
           (exit 8)))
        (queued
         .
         (module program racket/base
           (require raft
                    raft/private/job
                    raft/private/resources
                    raft/tests/private/gate
                    raft/tests/private/probe)
           (probe-mark-atexit!)
           (define r (host-resources))
           (define g (closed-gate))
           (thread (lambda () (gate-job 'demo r g)))
           (await-entry g)
           (thread (lambda () (probe-sleep-job 'demo r 0)))
           (let wait ()
             (cond
               [(= (jobs-in-flight) 2) (void)]
               [else
                (sleep 0.01)
                (wait)]))
           (probe-open-after! (gate-opener-fd g) 300)
           (exit 9)))
        (looping-main
         .
         (module program racket/base
           (require raft raft/private/resources raft/tests/private/probe)
           (probe-mark-atexit!)
           (define r (host-resources))
           (thread (lambda ()
                     (let loop ()
                       (probe-sleep-job 'demo r 50)
                       (loop))))
           (sleep 0.3)
           (exit 10)))
        (looping-place
         .
         (module program racket/base
           (require racket/place raft raft/tests/private/probe)
           (probe-mark-atexit!)
           (define worker
             (place ch
               (define host-resources (dynamic-require 'raft/private/resources 'host-resources))
               (define probe-sleep-job (dynamic-require 'raft/tests/private/probe 'probe-sleep-job))
               (define r (host-resources))
               (let loop ()
                 (with-handlers ([exn:fail? (lambda (e) (eprintf "refused: ~a\n" (exn-message e)))])
                   (probe-sleep-job 'demo r 50))
                 (loop))))
           (sleep 0.5)
           (exit 11)))
        (place-job
         .
         (module program racket/base
           (require racket/place raft raft/tests/private/probe)
           (probe-mark-atexit!)
           (define worker
             (place ch
               (define host-resources (dynamic-require 'raft/private/resources 'host-resources))
               (define closed-gate (dynamic-require 'raft/tests/private/gate 'closed-gate))
               (define await-entry (dynamic-require 'raft/tests/private/gate 'await-entry))
               (define gate-opener-fd (dynamic-require 'raft/tests/private/gate 'gate-opener-fd))
               (define gate-job (dynamic-require 'raft/tests/private/probe 'gate-job))
               (define probe-open-after! (dynamic-require 'raft/tests/private/probe 'probe-open-after!))
               (define g (closed-gate))
               (thread (lambda ()
                         (await-entry g)
                         (probe-open-after! (gate-opener-fd g) 400)
                         (place-channel-put ch 'entered)))
               (gate-job 'demo (host-resources) g)))
           (place-channel-get worker)
           (exit 12)))
        (place-value
         .
         (module program racket/base
           (require racket/place raft raft/tests/private/probe)
           (probe-mark-atexit!)
           (current-exit-wait 30)
           (define worker
             (place ch
               (define host-resources (dynamic-require 'raft/private/resources 'host-resources))
               (define current-exit-wait (dynamic-require 'raft 'current-exit-wait))
               (define closed-gate (dynamic-require 'raft/tests/private/gate 'closed-gate))
               (define await-entry (dynamic-require 'raft/tests/private/gate 'await-entry))
               (define gate-job (dynamic-require 'raft/tests/private/probe 'gate-job))
               (define g (closed-gate))
               (thread (lambda ()
                         (await-entry g)
                         (place-channel-put ch 'entered)))
               (parameterize ([current-exit-wait 0])
                 (gate-job 'demo (host-resources) g #:timeout-ms -1))))
           (place-channel-get worker)
           (exit 13)))
        (place-exits
         .
         (module program racket/base
           (require racket/place
                    raft
                    raft/private/resources
                    raft/tests/private/gate
                    raft/tests/private/probe)
           (probe-mark-atexit!)
           (define r (host-resources))
           (define g (closed-gate))
           (define first-job (thread (lambda () (gate-job 'demo r g)) #:keep 'results))
           (await-entry g)
           (define worker
             (place ch
               (define host-resources (dynamic-require 'raft/private/resources 'host-resources))
               (define probe-sleep-job (dynamic-require 'raft/tests/private/probe 'probe-sleep-job))
               (probe-sleep-job 'demo (host-resources) 0)
               (exit 5)))
           (define code (place-wait worker))
           (open-gate! g)
           (define first-answer (thread-wait first-job))
           (define again (closed-gate))
           (open-gate! again)
           (printf "~a ~a ~a\n" code first-answer (gate-job 'demo r again))))
        (own-bound
         .
         (module program racket/base
           (require raft
                    raft/private/resources
                    raft/tests/private/gate
                    raft/tests/private/probe)
           (probe-mark-atexit!)
           (define stuck (closed-gate))
           (define opened (closed-gate))
           (parameterize ([current-exit-wait 0.2])
             (thread (lambda () (gate-job 'demo (host-resources) stuck #:timeout-ms -1))))
           (thread (lambda () (gate-job 'demo (host-resources) opened)))
           (await-entry stuck)
           (await-entry opened)
           (probe-open-after! (gate-opener-fd opened) 1000)
           (exit 14)))
        (largest-bound
         .
         (module program racket/base
           (require raft
                    raft/private/resources
                    raft/tests/private/gate
                    raft/tests/private/probe)
           (probe-mark-atexit!)
           (define short (closed-gate))
           (define long (closed-gate))
           (parameterize ([current-exit-wait 0.2])
             (thread (lambda () (gate-job 'demo (host-resources) short #:timeout-ms -1))))
           (parameterize ([current-exit-wait 1.0])
             (thread (lambda () (gate-job 'demo (host-resources) long #:timeout-ms -1))))
           (await-entry short)
           (await-entry long)
           (exit 15)))
        (default-bound
         .
         (module program racket/base
           (require raft
                    raft/private/resources
                    raft/tests/private/gate
                    raft/tests/private/probe)
           (probe-mark-atexit!)
           (define g (closed-gate))
           (thread (lambda () (gate-job 'demo (host-resources) g #:timeout-ms -1)))
           (await-entry g)
           (exit 16)))
        (zero-bound
         .
         (module program racket/base
           (require raft
                    raft/private/resources
                    raft/tests/private/gate
                    raft/tests/private/probe)
           (probe-mark-atexit!)
           (define g (closed-gate))
           (parameterize ([current-exit-wait 0])
             (thread (lambda () (gate-job 'demo (host-resources) g))))
           (await-entry g)
           (probe-open-after! (gate-opener-fd g) 200)
           (exit 17)))
        (infinite-bound
         .
         (module program racket/base
           (require raft
                    raft/private/resources
                    raft/tests/private/gate
                    raft/tests/private/probe)
           (probe-mark-atexit!)
           (define opened (closed-gate))
           (define stuck (closed-gate))
           (parameterize ([current-exit-wait +inf.0])
             (thread (lambda () (gate-job 'demo (host-resources) opened))))
           (parameterize ([current-exit-wait 0.2])
             (thread (lambda () (gate-job 'demo (host-resources) stuck #:timeout-ms -1))))
           (await-entry opened)
           (await-entry stuck)
           (probe-open-after! (gate-opener-fd opened) 1500)
           (exit 18)))
        (late-static-skip
         .
         (module program racket/base
           (require raft
                    raft/private/resources
                    raft/tests/private/gate
                    raft/tests/private/probe)
           (probe-mark-atexit!)
           (define g (closed-gate))
           (parameterize ([current-exit-wait 0.5])
             (thread (lambda ()
                       (probe-late-static-job 'demo (host-resources) (gate-entered-fd g) (gate-fd g) -1))))
           (await-entry g)
           (exit 19)))
        (late-static-clean
         .
         (module program racket/base
           (require raft
                    raft/private/resources
                    raft/tests/private/gate
                    raft/tests/private/probe)
           (probe-mark-atexit!)
           (define g (closed-gate))
           (thread (lambda ()
                     (probe-late-static-job 'demo (host-resources) (gate-entered-fd g) (gate-fd g) -1)))
           (await-entry g)
           (probe-open-after! (gate-opener-fd g) 300)
           (exit 20)))
        (loaded-elsewhere
         .
         (module program racket/base
           (define loader (make-custodian))
           (parameterize ([current-plumber (make-plumber)]
                          [current-custodian loader])
             (dynamic-require 'raft #f))
           (custodian-shutdown-all loader)
           (define host-resources (dynamic-require 'raft/private/resources 'host-resources))
           (define closed-gate (dynamic-require 'raft/tests/private/gate 'closed-gate))
           (define await-entry (dynamic-require 'raft/tests/private/gate 'await-entry))
           (define gate-opener-fd (dynamic-require 'raft/tests/private/gate 'gate-opener-fd))
           (define gate-job (dynamic-require 'raft/tests/private/probe 'gate-job))
           (define probe-open-after! (dynamic-require 'raft/tests/private/probe 'probe-open-after!))
           ((dynamic-require 'raft/tests/private/probe 'probe-mark-atexit!))
           (define g (closed-gate))
           (thread (lambda () (gate-job 'demo (host-resources) g)))
           (await-entry g)
           (probe-open-after! (gate-opener-fd g) 300)
           (exit 4)))
        (two-instantiations
         .
         (module program racket/base
           (require raft
                    raft/private/resources
                    raft/tests/private/gate
                    raft/tests/private/probe)
           (parameterize ([current-namespace (make-base-empty-namespace)])
             (dynamic-require 'raft #f))
           (probe-mark-atexit!)
           (define g (closed-gate))
           (thread (lambda () (gate-job 'demo (host-resources) g)))
           (await-entry g)
           (probe-open-after! (gate-opener-fd g) 300)
           (exit 4)))
        (place-only
         .
         (module program racket/base
           (require (only-in ffi/unsafe _fun _void ffi-lib get-ffi-obj) racket/place)
           ((get-ffi-obj "rr_probe_mark_atexit" (ffi-lib (getenv "RAFT_SHIM_PROBE")) (_fun -> _void)))
           (define worker
             (place ch
               (define host-resources (dynamic-require 'raft/private/resources 'host-resources))
               (define closed-gate (dynamic-require 'raft/tests/private/gate 'closed-gate))
               (define await-entry (dynamic-require 'raft/tests/private/gate 'await-entry))
               (define gate-opener-fd (dynamic-require 'raft/tests/private/gate 'gate-opener-fd))
               (define gate-job (dynamic-require 'raft/tests/private/probe 'gate-job))
               (define probe-open-after! (dynamic-require 'raft/tests/private/probe 'probe-open-after!))
               (define g (closed-gate))
               (thread (lambda ()
                         (await-entry g)
                         (probe-open-after! (gate-opener-fd g) 300)
                         (place-channel-put ch 'entered)))
               (gate-job 'demo (host-resources) g #:say? #t)))
           (place-channel-get worker)
           (exit 21))))
