#lang racket/base

(require (only-in compiler/cm managed-compile-zo manager-compile-notify-handler)
         (only-in racket/file delete-directory/files make-directory* make-temporary-directory)
         (only-in racket/list append-map filter-map remove-duplicates take-right)
         (only-in racket/match match match-lambda)
         (only-in racket/path find-relative-path path-has-extension? path-only simple-form-path)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path
         (only-in racket/set list->set set=?)
         (only-in racket/string string-join string-suffix?)
         (only-in rackunit check-equal? check-exn check-false check-true test-case)
         (only-in syntax/modread with-module-reading-parameterization)
         (only-in "../private/resource.rkt" with-release)
         (only-in "private/env.rkt" with-environment-variables))

(define-runtime-path scribblings-dir "../scribblings")
(define-runtime-path closing-fixture "fixtures/docs-chapter-scrbl.txt")
(define-runtime-path chapter-fixtures "fixtures/docs-chapters")

(define (module-body path)
  (match (with-module-reading-parameterization
          (lambda () (call-with-input-file path (lambda (in) (syntax->datum (read-syntax path in))))))
    [(list 'module _ _ (cons '#%module-begin body)) (filter pair? body)]))

(define quoting-forms
  '(codeblock codeblock0
              quote
              racket
              racketblock
              racketblock0
              racketinput
              racketmod
              racketresultblock))

(define example-forms
  '(def+int defexamples
            defexamples*
            defs+int
            examples
            examples*
            interaction
            interaction-eval
            interaction-eval-show
            interaction/no-prompt
            interaction0
            racketblock+eval
            racketblock0+eval
            racketmod+eval))

(define live-evaluator-makers
  '(make-base-eval make-base-eval-factory
                   make-eval-factory
                   make-evaluator
                   make-log-based-eval
                   make-module-evaluator))

(define (unquoted-forms form)
  (match form
    [(cons (? (lambda (head) (memq head quoting-forms))) _) '()]
    [(cons _ (? list?)) (cons form (append-map unquoted-forms form))]
    [(cons head tail) (append (unquoted-forms head) (unquoted-forms tail))]
    [_ '()]))

(define (evaluator-uses form)
  (filter (match-lambda
            [(list (or 'make-raft-eval 'make-downstream-eval) (? string?)) #t]
            [_ #f])
          (unquoted-forms form)))

(define (eval-argument args)
  (match args
    [(list* '#:eval value _) (list value)]
    [(cons _ rest) (eval-argument rest)]
    [_ '()]))

(define (chapter-evaluators body)
  (filter-map
   (match-lambda
     [(list 'define (? symbol? ev) (and use (list (or 'make-raft-eval 'make-downstream-eval) _)))
      (cons ev use)]
     [_ #f])
   body))

(struct source (name scrbl? body))
(struct use (source name form))

(define (scribbling-sources dir)
  (for/list ([path (in-directory dir)]
             #:when (or (path-has-extension? path #".scrbl") (path-has-extension? path #".rkt")))
    (source (path->string (find-relative-path (simple-form-path dir) (simple-form-path path)))
            (path-has-extension? path #".scrbl")
            (module-body path))))

(define (log-names dir)
  (define logs (build-path dir "logs"))
  (for/list ([file (in-list (if (directory-exists? logs)
                                (directory-list logs)
                                '()))]
             #:when (path-has-extension? file #".rktd"))
    (regexp-replace #rx"[.]rktd$" (path->string file) "")))

(define (misplaced-problems uses)
  (for/list ([u (in-list uses)]
             #:unless (and (source-scrbl? (use-source u))
                           (memq (use-form u)
                                 (map cdr (chapter-evaluators (source-body (use-source u)))))))
    (format "~a: ~s is not the value of a top-level define in a .scrbl chapter"
            (source-name (use-source u))
            (use-form u))))

(define (duplicate-problems uses)
  (for*/list ([name (in-list (remove-duplicates (map use-name uses)))]
              [names-sources (in-value (for/list ([u (in-list uses)]
                                                  #:when (equal? (use-name u) name))
                                         (source-name (use-source u))))]
              #:when (> (length names-sources) 1))
    (format "~s names the log of more than one evaluator: ~a"
            name
            (string-join (sort names-sources string<?) ", "))))

(define (closing-problems sources)
  (for*/list ([s (in-list sources)]
              #:when (source-scrbl? s)
              [closes (in-value (map (match-lambda
                                       [(cons ev _) `(close-eval ,ev)])
                                     (chapter-evaluators (source-body s))))]
              #:unless (null? closes)
              #:unless (and (<= (length closes) (length (source-body s)))
                            (set=? (list->set (take-right (source-body s) (length closes)))
                                   (list->set closes))))
    (format "~a must end with ~a" (source-name s) (string-join (map form->string closes) " "))))

(define (example-problems sources)
  (for*/list ([s (in-list sources)]
              [evaluators (in-value (map car (chapter-evaluators (source-body s))))]
              [form (in-list (append-map unquoted-forms (source-body s)))]
              #:when (memq (car form) example-forms)
              [problem (in-value
                        (match (eval-argument (cdr form))
                          ['()
                           (format "~a: ~a with no #:eval evaluates live; give it a chapter evaluator"
                                   (source-name s)
                                   (car form))]
                          [(list (? symbol? ev))
                           #:when (memq ev evaluators)
                           #f]
                          [(list value)
                           #:when (pair? (evaluator-uses value))
                           #f]
                          [(list value)
                           (format "~a: the #:eval of ~a, ~s, is not a chapter evaluator"
                                   (source-name s)
                                   (car form)
                                   value)]))]
              #:when problem)
    problem))

(define (raw-evaluator-problems sources)
  (for*/list ([s (in-list sources)]
              #:when (source-scrbl? s)
              [form (in-list (append-map unquoted-forms (source-body s)))]
              [name (in-list form)]
              #:when (memq name live-evaluator-makers))
    (format "~a: ~a makes an evaluator that runs live; use make-raft-eval or make-downstream-eval"
            (source-name s)
            name)))

(define (log-problems uses logs)
  (append
   (for/list ([log (in-list logs)]
              #:unless (member log (map use-name uses)))
     (format "logs/~a.rktd: no evaluator names it" log))
   (for/list ([u (in-list uses)]
              #:unless (member (use-name u) logs))
     (format
      "logs/~a.rktd does not exist for ~a's ~s; record it with scripts/record-docs.sh and commit it"
      (use-name u)
      (source-name (use-source u))
      (use-form u)))))

(define (form->string form)
  (format "~s" form))

(define (chapter-problems dir)
  (define sources (scribbling-sources dir))
  (define uses
    (append-map (lambda (s)
                  (map (match-lambda
                         [(and form (list _ name)) (use s name form)])
                       (evaluator-uses (source-body s))))
                sources))
  (append (misplaced-problems uses)
          (duplicate-problems uses)
          (closing-problems sources)
          (example-problems sources)
          (raw-evaluator-problems sources)
          (log-problems uses (log-names dir))))

(define (call-with-fixture name proc)
  (with-release ([dir (make-temporary-directory "raft-docs-chapters-~a") delete-directory/files])
    (define from (build-path chapter-fixtures name))
    (for ([path (in-directory from)]
          #:when (file-exists? path))
      (define to
        (build-path dir
                    (regexp-replace #rx"[.]txt$" (path->string (find-relative-path from path)) "")))
      (make-directory* (path-only to))
      (copy-file path to))
    (proc dir)))

(define (fixture-problems name)
  (call-with-fixture name chapter-problems))

(test-case "every logged evaluator is a chapter's top-level define, closed at its end, with its own log"
  (check-equal? (chapter-problems scribblings-dir) '())
  (check-equal? (length (log-names scribblings-dir)) 8))

(test-case "a chapter may define several evaluators when it closes each at its end"
  (check-equal? (fixture-problems "two-evaluators") '()))

(test-case "a chapter that does not close each of its evaluators at its end is refused"
  (check-equal? (fixture-problems "unclosed")
                '("chapter.scrbl must end with (close-eval ev) (close-eval downstream)")))

(test-case "a log no evaluator names is refused"
  (check-equal? (fixture-problems "orphan") '("logs/orphan.rktd: no evaluator names it")))

(test-case "two evaluators naming one log are refused"
  (check-equal? (fixture-problems "duplicate")
                '("\"same\" names the log of more than one evaluator: a.scrbl, b.scrbl")))

(test-case "an evaluator made inline in an example is refused"
  (check-equal?
   (fixture-problems "inline")
   '("chapter.scrbl: (make-raft-eval \"inline\") is not the value of a top-level define in a .scrbl chapter")))

(test-case "an evaluator made in a helper module is refused"
  (check-equal?
   (fixture-problems "helper")
   '("helper.rkt: (make-raft-eval \"helper\") is not the value of a top-level define in a .scrbl chapter")))

(test-case "an evaluator whose log is not recorded yet is refused"
  (check-equal?
   (fixture-problems "unrecorded")
   '(#<<MESSAGE
logs/unrecorded.rktd does not exist for chapter.scrbl's (make-raft-eval "unrecorded"); record it with scripts/record-docs.sh and commit it
MESSAGE
     )))

(test-case "an example with no #:eval is refused"
  (check-equal?
   (fixture-problems "no-eval")
   '("chapter.scrbl: examples with no #:eval evaluates live; give it a chapter evaluator")))

(test-case "an example whose #:eval is not a chapter evaluator is refused"
  (check-equal? (fixture-problems "foreign-eval")
                '("chapter.scrbl: the #:eval of examples, other, is not a chapter evaluator")))

(test-case "an evaluator made with make-base-eval is refused"
  (check-equal?
   (fixture-problems "raw-eval")
   '("chapter.scrbl: make-base-eval makes an evaluator that runs live; use make-raft-eval or make-downstream-eval")))

(test-case "an evaluator shown in quoted code is not a use"
  (check-equal? (fixture-problems "quoted") '()))

(define (copy-scribbling-modules dir)
  (for ([name (in-list '("utils.rkt" "logged-eval.rkt"))])
    (copy-file (build-path scribblings-dir name) (build-path dir name))))

(define (call-with-chapter-copy proc)
  (with-release ([dir (make-temporary-directory "raft-docs-chapters-~a") delete-directory/files])
    (copy-scribbling-modules dir)
    (make-directory* (build-path dir "logs"))
    (copy-file (build-path scribblings-dir "logs" "guide-getting-started.rktd")
               (build-path dir "logs" "guide-getting-started.rktd"))
    (copy-file closing-fixture (build-path dir "chapter.scrbl"))
    (proc dir)))

(define (recompiles? file)
  (define compiled '())
  (parameterize ([current-namespace (make-base-namespace)]
                 [manager-compile-notify-handler (lambda (path)
                                                   (set! compiled (cons path compiled)))])
    (managed-compile-zo file))
  (and (member (simplify-path file) (map simplify-path compiled)) #t))

(test-case "re-recording a chapter's log makes raco make compile the chapter again"
  (call-with-chapter-copy (lambda (dir)
                            (define chapter (build-path dir "chapter.scrbl"))
                            (define log (build-path dir "logs" "guide-getting-started.rktd"))
                            (check-true (recompiles? chapter))
                            (check-false (recompiles? chapter))
                            (with-output-to-file log #:exists 'append (lambda () (newline)))
                            (file-or-directory-modify-seconds log (+ (current-seconds) 10))
                            (check-true (recompiles? chapter)))))

(test-case "a chapter with no log yet compiles, and its replay names the log and how to record it"
  (call-with-fixture
   "unrecorded"
   (lambda (dir)
     (copy-scribbling-modules dir)
     (define chapter (build-path dir "chapter.scrbl"))
     (check-true (recompiles? chapter))
     (check-exn
      (lambda (e)
        (and
         (exn:fail:user? e)
         (string-suffix?
          (exn-message e)
          "logs/unrecorded.rktd does not exist; record it with scripts/record-docs.sh and commit it")))
      (lambda ()
        (with-environment-variables (["RAFT_DOCS" #f])
                                    (parameterize ([current-namespace (make-base-namespace)])
                                      (dynamic-require chapter #f))))))))
