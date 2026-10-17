((device-count) (values "1\n") "" "")
((define (device-for-worker i) (modulo i (device-count))) (values "") "" "")
((map device-for-worker '(0 1 2 3)) (values "'(0 0 0 0)\n") "" "")
((device-resources #:device 4)
 (raise "device-resources: no device 4 among 1")
 ""
 "")
((define r (device-resources #:device (device-for-worker 0)))
 (values "")
 ""
 "")
(r (values "#<device-resources device 0>\n") "" "")
((resources-device r) (values "0\n") "" "")
((eq? r (current-device-resources 0)) (values "#f\n") "" "")
((define (process-batch rows)
   (for
    ((row (in-list rows)))
    (unless (= (length row) 2)
      (error 'process-batch "row ~a has ~a columns" row (length row))))
   (length rows))
 (values "")
 ""
 "")
((define (timed r thunk)
   (define start (current-inexact-milliseconds))
   (define result (thunk))
   (resources-sync! r)
   (values result (- (current-inexact-milliseconds) start)))
 (values "")
 ""
 "")
((timed r (lambda () (process-batch '((1.0 2.0) (3.0 4.0)))))
 (values "2\n" "0.029541015625\n")
 ""
 "")
((define (run-worker device batches)
   (with-device-resources
    ((r (device-resources #:device device)))
    (for/list
     ((rows (in-list batches)))
     (define-values (n ms) (timed r (lambda () (process-batch rows))))
     (list n ms))))
 (values "")
 ""
 "")
((run-worker 0 (list '((1.0 2.0) (3.0 4.0)) '((5.0 6.0))))
 (values "'((2 0.017822265625) (1 0.002685546875))\n")
 ""
 "")
((define (run-workers worker jobs)
   (define answers
     (for/list
      ((job (in-list jobs)))
      (match-define (list device batches) job)
      (define done (make-channel))
      (define (send thunk) (channel-put done thunk))
      (define t
        (thread
         (lambda ()
           (with-handlers
            (((lambda (_) #t) (lambda (v) (send (lambda () (raise v))))))
            (define result (worker device batches))
            (send (lambda () result))))))
      (choice-evt
       done
       (handle-evt
        (thread-dead-evt t)
        (lambda (_) (lambda () (worker-died device)))))))
   (for/list ((answer (in-list answers))) ((sync answer))))
 (values "")
 ""
 "")
((define (worker-died device)
   (error 'run-workers "the worker on cuda:~a ended without an answer" device))
 (values "")
 ""
 "")
((define (report results)
   (for
    ((batches (in-list results)) (i (in-naturals)))
    (for
     ((batch (in-list batches)))
     (match-define (list n ms) batch)
     (printf "worker ~a: ~a rows in ~a ms\n" i n (~r ms #:precision '(= 2))))))
 (values "")
 ""
 "")
((define all-batches
   (list
    (list '((1.0 2.0) (3.0 4.0)) '((5.0 6.0)))
    (list '((7.0 8.0)))
    (list '((9.0 10.0) (11.0 12.0)))))
 (values "")
 ""
 "")
((define jobs
   (for/list
    ((batches (in-list all-batches)) (i (in-naturals)))
    (list (device-for-worker i) batches)))
 (values "")
 ""
 "")
((report (run-workers run-worker jobs))
 (values "")
 "worker 0: 2 rows in 0.00 ms\nworker 0: 1 rows in 0.00 ms\nworker 1: 1 rows in 0.00 ms\nworker 2: 2 rows in 0.02 ms\n"
 "")
((define (run-worker/caught device batches)
   (with-handlers ((exn:fail:raft? values)) (run-worker device batches)))
 (values "")
 ""
 "")
((define (failures results)
   (for/list
    ((result (in-list results))
     (i (in-naturals))
     #:when
     (exn:fail:raft? result))
    (list i (exn:fail:raft-kind result) (exn-message result))))
 (values "")
 ""
 "")
((match-define (list batches-0 batches-1 _) all-batches) (values "") "" "")
((define results
   (run-workers
    run-worker/caught
    (list (list 0 batches-0) (list 4 batches-1))))
 (values "")
 ""
 "")
((failures results)
 (values "'((1 logic \"device-resources: no device 4 among 1\"))\n")
 ""
 "")
