#lang racket/base

(require (only-in file/convertible convertible?)
         (only-in racket/file file->list make-directory*)
         (only-in racket/match == match)
         (only-in racket/path path-only)
         (only-in racket/pretty pretty-print-print-hook pretty-print-size-hook pretty-write)
         (only-in racket/sandbox call-in-sandbox-context)
         (only-in scribble/example close-eval make-base-eval))

(provide close-logged-eval
         docs-mode
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

(struct ledger (log recording [pending #:mutable] [problem #:mutable]))

(define ledgers (make-weak-hasheq))

(define (keep-ledger! ev l)
  (hash-set! ledgers ev l)
  ev)

(define (ledger-fail! l message)
  (set-ledger-problem! l (or (ledger-problem l) message))
  (raise-user-error 'raft-docs "~a" message))

(define (recording-path log)
  (string->path (string-append (path->string (path->complete-path log)) ".recording")))

(define (recorded-entries log)
  (cond
    [(file-exists? log) (file->list log)]
    [else
     (raise-user-error 'raft-docs
                       "~a does not exist; record it with scripts/record-docs.sh and commit it"
                       log)]))

(define (make-logged-eval mode log make-live)
  (match mode
    ['live (make-live)]
    ['record (recording-eval (make-live) (ledger log (recording-path log) '() #f))]
    ['replay (replaying-eval (ledger log #f (recorded-entries log) #f))]))

(define (close-logged-eval ev)
  (close-eval ev)
  (define l (hash-ref ledgers ev #f))
  (hash-remove! ledgers ev)
  (match l
    [(ledger _ recording _ (? string? problem))
     (discard-recording recording)
     (raise-user-error 'raft-docs "~a" problem)]
    [(ledger log #f (cons (cons expr _) _) #f)
     (raise-user-error
      'raft-docs
      "~a has evaluations no example replayed, from ~.s on; re-record it with RAFT_DOCS=record"
      log
      expr)]
    [(ledger log (? path? recording) _ #f)
     (rename-file-or-directory recording log #t)
     ""]
    [_ ""]))

(define (discard-recording recording)
  (match recording
    [(? path?) (delete-file recording)]
    [#f (void)]))

(struct recorded (text)
  #:transparent
  #:property prop:custom-write
  (lambda (v out _mode) (write-string (recorded-text v) out)))

(define (form->expr form)
  (match (syntax->datum (datum->syntax #f form))
    [(cons '#%top-interaction expr) expr]
    [expr expr]))

(define (output-since port start)
  (bytes->string/utf-8 (get-output-bytes port #f start) #\?))

(define (call-with-captured-output proc)
  (define out (current-output-port))
  (define err (current-error-port))
  (define out-start (file-position out))
  (define err-start (file-position err))
  (proc (lambda () (list (output-since out out-start) (output-since err err-start)))))

(define ((refuse-convertible l) obj _mode _out)
  (ledger-fail! l (format "cannot record ~e: it renders as an image, not text" obj)))

(define ((print->string l) v)
  (define out (open-output-string))
  (parameterize ([current-output-port out]
                 [pretty-print-size-hook (lambda (obj _mode _out) (and (convertible? obj) 1))]
                 [pretty-print-print-hook (refuse-convertible l)])
    ((current-print) v))
  (get-output-string out))

(define (raised->message e)
  (cond
    [(exn? e) (exn-message e)]
    [else (format "uncaught exception: ~s" e)]))

(define (not-a-break? raised)
  (not (exn:break? raised)))

(define (append-entry! log entry)
  (with-output-to-file log #:exists 'append (lambda () (pretty-write entry))))

(define ((recording-handler l live-eval) form)
  (call-with-captured-output (lambda (captured)
                               (define (record! result)
                                 (append-entry! (ledger-recording l)
                                                (list* (form->expr form) result (captured))))
                               (define (record-raise! raised)
                                 (record! (list 'raise (raised->message raised)))
                                 (raise raised))
                               (define results
                                 (with-handlers ([not-a-break? record-raise!])
                                   (parameterize ([current-eval live-eval])
                                     (call-with-values (lambda () (live-eval form)) list))))
                               (record! (cons 'values (map (print->string l) results)))
                               (apply values results))))

(define (recording-eval ev l)
  (define recording (ledger-recording l))
  (make-directory* (path-only recording))
  (with-output-to-file recording #:exists 'truncate void)
  (call-in-sandbox-context ev (lambda () (current-eval (recording-handler l (current-eval)))))
  (keep-ledger! ev l))

(define ((replaying-handler l) form)
  (define expr (form->expr form))
  (match (ledger-pending l)
    [(cons (list (== expr) result out err) rest)
     (set-ledger-pending! l rest)
     (write-string out (current-output-port))
     (write-string err (current-error-port))
     (match result
       [(cons 'values texts) (apply values (map recorded texts))]
       [(list 'raise message) (raise (exn:fail message (current-continuation-marks)))])]
    [_
     (ledger-fail!
      l
      (format "~a has no recorded evaluation of ~.s next; re-record it with RAFT_DOCS=record"
              (ledger-log l)
              expr))]))

(define (replaying-eval l)
  (define ev (make-base-eval))
  (call-in-sandbox-context ev
                           (lambda ()
                             (current-print write)
                             (current-eval (replaying-handler l))))
  (keep-ledger! ev l))
