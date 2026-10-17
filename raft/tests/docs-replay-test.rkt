#lang racket/base

(require (only-in racket/file delete-directory/files file->list file->string make-temporary-directory)
         (only-in rackunit check-equal? check-exn test-case)
         (only-in scribble/core part style)
         (only-in scribble/example examples make-base-eval)
         (only-in scribble/html-render render-mixin)
         (only-in scribble/render render)
         (only-in "../private/resource.rkt" with-release)
         (only-in "../scribblings/logged-eval.rkt" docs-mode make-logged-eval))

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

(define (call-with-scratch proc)
  (with-release ([dir (make-temporary-directory "raft-docs-replay-~a") delete-directory/files])
    (proc dir)))

(define (rendered mode log dir)
  (render->string (sample (make-logged-eval mode log make-base-eval)) dir))

(define (with-docs-env value thunk)
  (parameterize ([current-environment-variables
                  (environment-variables-copy (current-environment-variables))])
    (environment-variables-set! (current-environment-variables)
                                #"RAFT_DOCS"
                                (and value (string->bytes/utf-8 value)))
    (thunk)))

(test-case "a recorded chapter replays to the same page as a live one"
  (call-with-scratch (lambda (dir)
                       (define log (build-path dir "logs" "sample.rktd"))
                       (define live (rendered 'live log (build-path dir "live")))
                       (define recorded (rendered 'record log (build-path dir "record")))
                       (define replayed (rendered 'replay log (build-path dir "replay")))
                       (check-equal? (length (file->list log)) sample-count)
                       (check-equal? recorded live)
                       (check-equal? replayed live))))

(test-case "recording again starts the log afresh"
  (call-with-scratch (lambda (dir)
                       (define log (build-path dir "sample.rktd"))
                       (rendered 'record log (build-path dir "first"))
                       (rendered 'record log (build-path dir "second"))
                       (check-equal? (length (file->list log)) sample-count))))

(test-case "an example the log does not hold next stops the replay"
  (call-with-scratch
   (lambda (dir)
     (define log (build-path dir "short.rktd"))
     (define recorder (make-logged-eval 'record log make-base-eval))
     (check-equal? (recorder '(+ 1 2)) 3)
     (define replayer (make-logged-eval 'replay log make-base-eval))
     (check-exn
      #rx"has no recorded evaluation of \\(\\+ 1 3\\) next; re-record it with RAFT_DOCS=record"
      (lambda () (replayer '(+ 1 3))))
     (define again (make-logged-eval 'replay log make-base-eval))
     (check-equal? (format "~a" (again '(+ 1 2))) "3\n")
     (check-exn #rx"has no recorded evaluation of \\(\\+ 1 2\\) next" (lambda () (again '(+ 1 2)))))))

(test-case "a replay never runs the expression"
  (call-with-scratch
   (lambda (dir)
     (define log (build-path dir "effect.rktd"))
     (call-with-output-file log (lambda (out) (write '((exit 7) (values "'done\n") "" "") out)))
     (define replayer (make-logged-eval 'replay log make-base-eval))
     (check-equal? (format "~a" (replayer '(exit 7))) "'done\n"))))

(test-case "a value that renders as an image cannot be recorded"
  (call-with-scratch
   (lambda (dir)
     (define recorder (make-logged-eval 'record (build-path dir "image.rktd") make-base-eval))
     (recorder '(require file/convertible))
     (recorder '(struct picture () #:property prop:convertible (lambda (v request default) default)))
     (check-exn #rx"cannot record .*: it renders as an image, not text"
                (lambda () (recorder '(picture)))))))

(test-case "RAFT_DOCS picks the mode, replay when unset"
  (check-equal? (with-docs-env #f docs-mode) 'replay)
  (check-equal? (with-docs-env "replay" docs-mode) 'replay)
  (check-equal? (with-docs-env "record" docs-mode) 'record)
  (check-equal? (with-docs-env "live" docs-mode) 'live))

(test-case "any other RAFT_DOCS is refused with the values it may take"
  (check-exn
   #rx"^raft-docs: RAFT_DOCS is \"Live\"; want live, record or replay \\(the default when unset\\)$"
   (lambda () (with-docs-env "Live" docs-mode)))
  (check-exn #rx"^raft-docs: RAFT_DOCS is \"\";" (lambda () (with-docs-env "" docs-mode))))
