#lang racket/base

(require (for-syntax racket/base)
         (only-in ffi/unsafe
                  _fpointer
                  _pointer
                  compute-offsets
                  ctype-sizeof
                  get-ffi-obj
                  make-cstruct-type
                  memcpy
                  ptr-ref
                  ptr-set!)
         (only-in ffi/unsafe/alloc allocator deallocator)
         (only-in ffi/unsafe/custodian make-custodian-at-root register-custodian-shutdown)
         (only-in ffi/unsafe/port unsafe-fd->evt)
         (only-in ffi/unsafe/schedule unsafe-poll-ctx-fd-wakeup unsafe-poller)
         (only-in racket/match match match*)
         ;; whole-module: it also provides syntax/parse at phase 1
         syntax/parse/define
         (only-in "array.rkt" array-buffer-handle settled-view)
         (only-in "error.rkt" call/raft)
         (only-in "exn.rkt" raise-raft)
         (only-in "foreign/array.rkt" _rr-view blank-view rr-view-size)
         (only-in "foreign/core.rkt" rr-resources-handle)
         (only-in "foreign/job-api.rkt"
                  rr-executor-threads
                  rr-exit-arm
                  rr-job-args
                  rr-job-done
                  rr-job-fd
                  rr-job-message
                  rr-job-release
                  rr-job-status
                  rr-job-submit
                  rr-job-times
                  rr-jobs-in-flight
                  rr-jobs-live
                  rr-now-ns)
         (only-in "resource.rkt" with-release)
         (only-in "resources.rkt" resources-handle))

(provide current-exit-wait
         current-job-breaks
         current-job-log
         current-job-wait
         define-job
         (rename-out [rr-executor-threads executor-threads]
                     [rr-jobs-in-flight jobs-in-flight]
                     [rr-jobs-live jobs-live]
                     [rr-now-ns now-ns]))

(define current-exit-wait
  (make-parameter 10
                  (lambda (v)
                    (if (and (real? v) (>= v 0))
                        v
                        (raise-raft 'current-exit-wait
                                    'logic
                                    "expected a non-negative real number of seconds, given ~e"
                                    v)))
                  'current-exit-wait))

(define current-job-wait (make-parameter 'poller))
(define current-job-breaks (make-parameter 'deferred))
(define current-job-log (make-parameter #f))

(define rearm
  (and (not (getenv "RAFTRKT_SPIKE_NO_REARM"))
       (register-custodian-shutdown 'raft-executor
                                    (lambda (_) (rr-exit-arm))
                                    (make-custodian-at-root)
                                    #:at-exit? #t)))

(struct param (kind type))

(define (handle-param)
  (param 'handle _pointer))
(define (view-param optional?)
  (param (if optional? 'view? 'view) _rr-view))
(define (in-param type)
  (param 'in type))
(define (out-param type)
  (param 'out type))

(define (release-job job [registered? #t])
  (when registered?
    (unsafe-fd->evt (rr-job-fd job) 'remove #f))
  (rr-job-release job))

(define release-job! ((deallocator) release-job))
(define register-job! ((allocator release-job!) values))

(struct job-evt (job fd)
  #:property prop:evt
  (unsafe-poller (lambda (self wakeups)
                   (cond
                     [(eqv? 1 (rr-job-done (job-evt-job self))) (values (list self) #f)]
                     [else
                      (when wakeups
                        (unsafe-poll-ctx-fd-wakeup wakeups (job-evt-fd self) 'read))
                      (values #f self)]))))

(define (spin-until-done job)
  (unless (eqv? 1 (rr-job-done job))
    (spin-until-done job)))

(define (ready-evt job mode)
  (match mode
    ['spin
     (spin-until-done job)
     always-evt]
    ['poller (job-evt job (rr-job-fd job))]
    ['fd-evt (unsafe-fd->evt (rr-job-fd job) 'read #f)]))

(define (await evt breaks)
  (match breaks
    ['deferred
     (parameterize-break #f
       (sync evt))
     (parameterize-break (break-enabled)
       (void))]
    ['abandon (sync evt)]))

(define (handle-pointer who r)
  (call/raft who (lambda () (rr-resources-handle (resources-handle who r)))))

(define (pack! who block r params offsets args)
  (let loop ([ps params]
             [offs offsets]
             [args args]
             [pins '()])
    (match* (ps offs args)
      [('() '() _) pins]
      [((cons (param 'out _) ps) (cons _ offs) args) (loop ps offs args pins)]
      [((cons (param 'handle _) ps) (cons off offs) args)
       (ptr-set! block _pointer 'abs off (handle-pointer who r))
       (loop ps offs args pins)]
      [((cons (param (or 'view 'view?) _) ps) (cons off offs) (cons #f args))
       (memcpy block off (blank-view) rr-view-size)
       (loop ps offs args pins)]
      [((cons (param (or 'view 'view?) _) ps) (cons off offs) (cons a args))
       (memcpy block off (settled-view who a) rr-view-size)
       (loop ps offs args (cons (array-buffer-handle a) pins))]
      [((cons (param 'in type) ps) (cons off offs) (cons v args))
       (ptr-set! block type 'abs off v)
       (loop ps offs args pins)])))

(define error-kinds #(generic out-of-memory cuda logic))

(define (submit who r entry block pins)
  (define native (resources-handle who r))
  (define seconds (real->double-flonum (current-exit-wait)))
  (define job
    (call/raft who
               (lambda ()
                 (match (rr-job-submit native entry block (bytes-length block) pins seconds)
                   [#f #f]
                   ['refused 'refused]
                   [j (register-job! j)]))))
  (cond
    [(eq? job 'refused) (sync never-evt)]
    [else job]))

(define (outcome who job outs)
  (define log (current-job-log))
  (when log
    (call-with-values (lambda () (rr-job-times job)) log))
  (define-values (status kind) (rr-job-status job))
  (cond
    [(zero? status)
     (define args (rr-job-args job))
     (apply values
            (for/list ([o (in-list outs)])
              (ptr-ref args (car o) 'abs (cdr o))))]
    [else
     (raise-raft who
                 (vector-ref error-kinds kind)
                 "~a"
                 (bytes->string/utf-8 (rr-job-message job) #\uFFFD))]))

(define (run-job who resources entry params offsets size outs args)
  (define block (make-bytes size 0))
  (define pins (pack! who block resources params offsets args))
  (define mode (current-job-wait))
  (define breaks (current-job-breaks))
  (with-release #:who who
                ([job (submit who resources entry block pins)
                      (lambda (j) (release-job! j (eq? mode 'fd-evt)))])
                (await (ready-evt job mode) breaks)
                (outcome who job outs)))

(define (make-job-procedure name entry params)
  (define types (map param-type params))
  (define offsets (compute-offsets types))
  (define size (ctype-sizeof (make-cstruct-type types)))
  (define inputs
    (for/sum ([p (in-list params)])
      (if (memq (param-kind p) '(out handle)) 0 1)))
  (define outs
    (for/list ([p (in-list params)]
               [off (in-list offsets)]
               #:when (eq? (param-kind p) 'out))
      (cons (param-type p) off)))
  (procedure-rename (procedure-reduce-arity
                     (lambda (who resources . args)
                       (run-job who resources entry params offsets size outs args))
                     (+ 2 inputs))
                    name))

(begin-for-syntax
  (define-syntax-class job-param
    #:description "a job parameter: handle, view, view?, (out ctype) or a ctype"
    #:datum-literals (handle out view view?)
    (pattern handle
      #:attr handle? #t
      #:with spec #'(handle-param))
    (pattern view
      #:attr handle? #f
      #:with spec #'(view-param #f))
    (pattern view?
      #:attr handle? #f
      #:with spec #'(view-param #t))
    (pattern (out type:expr)
      #:attr handle? #f
      #:with spec #'(out-param type))
    (pattern type:expr
      #:attr handle? #f
      #:with spec #'(in-param type))))

(define-syntax-parse-rule (define-job name:id library:expr c-id:expr (p:job-param ...))
  #:fail-when (< 1 (length (filter values (attribute p.handle?)))) "expected at most one handle"
  (define name
    (make-job-procedure 'name (get-ffi-obj c-id library _fpointer) (list p.spec ...))))
