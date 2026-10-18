#lang racket/base

(require (only-in racket/file
                  delete-directory/files
                  file->bytes
                  file->list
                  file->string
                  make-temporary-directory)
         (only-in racket/path file-name-from-path path-only)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path
         (only-in rackunit check-equal? check-exn test-case)
         (only-in scribble/core part style)
         (only-in scribble/example examples make-base-eval)
         (only-in scribble/html-render render-mixin)
         (only-in scribble/render render)
         (only-in "../private/resource.rkt" with-release)
         (only-in "../scribblings/logged-eval.rkt" close-logged-eval docs-mode make-logged-eval)
         (only-in "private/env.rkt" with-environment-variables))

(define-runtime-path exit-log "fixtures/replay-exit.rktd")

(define (sample ev)
  (examples #:eval ev
            #:label #f
            (define words '("alpha" "beta" "gamma"))
            (struct tally (count) #:transparent)
            (tally-count (tally (length words)))
            (tally (string-length (car words)))
            (map string-length words)
            (printf "~a words\n" (length words))
            (eprintf "and a warning\n")
            (values 1 "two" #\3)
            (build-list 40 (lambda (i) (* i i)))
            (void)
            (eval:error (vector-ref (list->vector words) 3))
            (eval:error (raise 'not-an-exception))))

(define sample-count 12)

(define (render->string block dir)
  (render (list (part #f '() '("Sample") (style #f '()) '() (list block) '()))
          (list "sample")
          #:render-mixin render-mixin
          #:dest-dir dir)
  (file->string (build-path dir "sample.html")))

(define (call-with-log proc)
  (with-release ([dir (make-temporary-directory "raft-docs-replay-~a") delete-directory/files])
    (proc (build-path dir "logs" "sample.rktd") dir)))

(define (logged mode log)
  (make-logged-eval mode log make-base-eval))

(define (rendered mode log dir)
  (define ev (logged mode log))
  (define page (render->string (sample ev) dir))
  (check-equal? (close-logged-eval ev) "")
  page)

(define (record-log! log . exprs)
  (define recorder (logged 'record log))
  (for-each recorder exprs)
  (close-logged-eval recorder))

(define (docs-mode-for value)
  (with-environment-variables (["RAFT_DOCS" value]) (docs-mode)))

(test-case "a recorded chapter replays to the same page as a live one"
  (call-with-log (lambda (log dir)
                   (define live (rendered 'live log (build-path dir "live")))
                   (define recorded (rendered 'record log (build-path dir "record")))
                   (define replayed (rendered 'replay log (build-path dir "replay")))
                   (check-equal? (length (file->list log)) sample-count)
                   (check-equal? recorded live)
                   (check-equal? replayed live))))

(test-case "recording again starts the log afresh"
  (call-with-log (lambda (log dir)
                   (rendered 'record log (build-path dir "first"))
                   (rendered 'record log (build-path dir "second"))
                   (check-equal? (length (file->list log)) sample-count))))

(test-case "a stale eval:error example replays green but fails its chapter's close"
  (call-with-log (lambda (log _dir)
                   (record-log! log '(+ 1 2))
                   (define ev (logged 'replay log))
                   (examples #:eval ev (eval:error (car 1)) (+ 1 2))
                   (check-exn #rx"has no recorded evaluation of \\(car 1\\) next"
                              (lambda () (close-logged-eval ev))))))

(test-case "evaluations no example replayed fail the chapter's close"
  (call-with-log
   (lambda (log _dir)
     (record-log! log '(+ 1 2) '(+ 3 4))
     (define ev (logged 'replay log))
     (examples #:eval ev (+ 1 2))
     (check-exn
      #rx"has evaluations no example replayed, from \\(\\+ 3 4\\) on; re-record it with RAFT_DOCS=record"
      (lambda () (close-logged-eval ev))))))

(test-case "an eval:error example whose value cannot be recorded fails the chapter's close"
  (call-with-log
   (lambda (log _dir)
     (define ev (logged 'record log))
     (examples #:eval ev
               (require file/convertible)
               (struct picture () #:property prop:convertible (lambda (_v _request default) default))
               (eval:error (picture)))
     (check-exn #rx"cannot record .*: it renders as an image, not text"
                (lambda () (close-logged-eval ev))))))

(test-case "an example the log does not hold next stops the replay"
  (call-with-log
   (lambda (log _dir)
     (define recorder (logged 'record log))
     (check-equal? (recorder '(+ 1 2)) 3)
     (close-logged-eval recorder)
     (define replayer (logged 'replay log))
     (check-exn
      #rx"has no recorded evaluation of \\(\\+ 1 3\\) next; re-record it with RAFT_DOCS=record"
      (lambda () (replayer '(+ 1 3))))
     (define again (logged 'replay log))
     (check-equal? (format "~a" (again '(+ 1 2))) "3\n")
     (check-exn #rx"has no recorded evaluation of \\(\\+ 1 2\\) next" (lambda () (again '(+ 1 2)))))))

(test-case "an eval:check example records and replays green"
  (call-with-log (lambda (log _dir)
                   (define (checked ev)
                     (examples #:eval ev (eval:check (+ 1 2) 3))
                     (close-logged-eval ev))
                   (checked (logged 'record log))
                   (check-equal? (checked (logged 'replay log)) ""))))

(define (call-with-recorded-log proc)
  (call-with-log (lambda (log _dir)
                   (record-log! log '(+ 1 2))
                   (proc log (file->bytes log)))))

(test-case "a record stopped by an example raising outside eval:error keeps the log as it was"
  (call-with-recorded-log (lambda (log before)
                            (define ev (logged 'record log))
                            (check-exn #rx"exception raised in example"
                                       (lambda () (examples #:eval ev (+ 1 2) (car 1))))
                            (check-equal? (file->bytes log) before))))

(test-case "a record whose close fails keeps the log and deletes its recording"
  (call-with-recorded-log
   (lambda (log before)
     (define ev (logged 'record log))
     (examples #:eval ev
               (require file/convertible)
               (struct picture () #:property prop:convertible (lambda (_v _request default) default))
               (eval:error (picture)))
     (check-exn #rx"cannot record" (lambda () (close-logged-eval ev)))
     (check-equal? (file->bytes log) before)
     (check-equal? (directory-list (path-only log)) (list (file-name-from-path log))))))

(test-case "a replay of a chapter with no log names it and how to record it"
  (call-with-log
   (lambda (log _dir)
     (check-exn
      (regexp (string-append "^raft-docs: "
                             (regexp-quote (path->string log))
                             " does not exist; record it with scripts/record-docs.sh and commit it$"))
      (lambda () (logged 'replay log))))))

(test-case "a replay never runs the expression"
  (define replayer (logged 'replay exit-log))
  (check-equal? (format "~a" (replayer '(exit 7))) "'done\n"))

(test-case "a value that renders as an image cannot be recorded"
  (call-with-log
   (lambda (log _dir)
     (define recorder (logged 'record log))
     (recorder '(require file/convertible))
     (recorder '(struct picture () #:property prop:convertible (lambda (v request default) default)))
     (check-exn #rx"cannot record .*: it renders as an image, not text"
                (lambda () (recorder '(picture)))))))

(test-case "RAFT_DOCS picks the mode, replay when unset"
  (check-equal? (docs-mode-for #f) 'replay)
  (check-equal? (docs-mode-for "replay") 'replay)
  (check-equal? (docs-mode-for "record") 'record)
  (check-equal? (docs-mode-for "live") 'live))

(test-case "any other RAFT_DOCS is refused with the values it may take"
  (check-exn
   #rx"^raft-docs: RAFT_DOCS is \"Live\"; want live, record or replay \\(the default when unset\\)$"
   (lambda () (docs-mode-for "Live")))
  (check-exn #rx"^raft-docs: RAFT_DOCS is \"\";" (lambda () (docs-mode-for ""))))
