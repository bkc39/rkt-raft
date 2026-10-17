#lang racket/base

(require (only-in file/convertible convertible?)
         (only-in racket/file file->list make-directory*)
         (only-in racket/match == match match-lambda)
         (only-in racket/path path-only)
         (only-in racket/pretty pretty-print-print-hook pretty-print-size-hook pretty-write)
         (only-in racket/sandbox call-in-sandbox-context)
         (only-in scribble/example make-base-eval))

(provide docs-mode
         make-logged-eval)

(define (docs-mode)
  (match (getenv "RAFT_DOCS")
    [(or #f "replay") 'replay]
    ["record" 'record]
    ["live" 'live]
    [other
     (raise-user-error 'raft-docs
                       "RAFT_DOCS is ~s; want live, record or replay (the default when unset)"
                       other)]))

(define (make-logged-eval mode log make-live)
  (match mode
    ['live (make-live)]
    ['record (recording-eval (make-live) log)]
    ['replay (replaying-eval log)]))

(struct recorded (text)
  #:property prop:custom-write
  (lambda (v out _mode) (write-string (recorded-text v) out)))

(define (form->expr form)
  (match (syntax->datum (datum->syntax #f form))
    [(cons '#%top-interaction expr) expr]
    [expr expr]))

(define (output-since port start)
  (bytes->string/utf-8 (get-output-bytes port #f start) #\?))

(define (refuse-convertible obj _mode _out)
  (raise-user-error 'raft-docs "cannot record ~e: it renders as an image, not text" obj))

(define (print->string v)
  (define out (open-output-string))
  (parameterize ([current-output-port out]
                 [pretty-print-size-hook (lambda (obj _mode _out) (and (convertible? obj) 1))]
                 [pretty-print-print-hook refuse-convertible])
    ((current-print) v))
  (get-output-string out))

(define (raised->message e)
  (match e
    [(? exn?) (exn-message e)]
    [_ (format "uncaught exception: ~s" e)]))

(define (append-entry! log entry)
  (with-output-to-file log #:exists 'append (lambda () (pretty-write entry))))

(define inside-example? (make-parameter #f))

(define ((recording-handler log live-eval) form)
  (match (inside-example?)
    [#t (live-eval form)]
    [#f
     (parameterize ([inside-example? #t])
       (record-example log live-eval form))]))

(define (record-example log live-eval form)
  (define expr (form->expr form))
  (define out (current-output-port))
  (define err (current-error-port))
  (define out-start (file-position out))
  (define err-start (file-position err))
  (define (record! result)
    (append-entry! log (list expr result (output-since out out-start) (output-since err err-start))))
  (define results
    (with-handlers ([(lambda (e) (not (exn:break? e))) (lambda (e)
                                                         (record! (list 'raise (raised->message e)))
                                                         (raise e))])
      (call-with-values (lambda () (live-eval form)) list)))
  (record! (cons 'values (map print->string results)))
  (apply values results))

(define (recording-eval ev log)
  (make-directory* (path-only (path->complete-path log)))
  (with-output-to-file log #:exists 'truncate void)
  (call-in-sandbox-context ev (lambda () (current-eval (recording-handler log (current-eval)))))
  ev)

(define ((replaying-handler log entries) form)
  (define expr (form->expr form))
  (match (unbox entries)
    [(cons (list (== expr) result out err) rest)
     (set-box! entries rest)
     (write-string out (current-output-port))
     (write-string err (current-error-port))
     (match result
       [(cons 'values texts) (apply values (map recorded texts))]
       [(list 'raise message) (raise (exn:fail message (current-continuation-marks)))])]
    [_
     (raise-user-error 'raft-docs
                       "~a has no recorded evaluation of ~.s next; re-record it with RAFT_DOCS=record"
                       log
                       expr)]))

(define (replaying-eval log)
  (define entries (box (file->list log)))
  (define ev (make-base-eval))
  (call-in-sandbox-context ev
                           (lambda ()
                             (current-print (match-lambda
                                              [(? recorded? v) (write v)]))
                             (current-eval (replaying-handler log entries))))
  ev)
