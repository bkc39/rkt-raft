#lang racket/base

(require (only-in compiler/cm managed-compile-zo manager-compile-notify-handler)
         (only-in racket/file delete-directory/files make-directory* make-temporary-directory)
         (only-in racket/list filter-map last)
         (only-in racket/match match match-lambda)
         (only-in racket/path path-has-extension?)
         ;; whole-module: define-runtime-path needs bindings only-in strips
         racket/runtime-path
         (only-in rackunit check-equal? check-false check-true test-case)
         (only-in syntax/modread with-module-reading-parameterization)
         (only-in "../private/resource.rkt" with-release))

(define-runtime-path scribblings-dir "../scribblings")
(define-runtime-path closing-fixture "fixtures/docs-chapter-scrbl.txt")

(define (module-body path)
  (match (with-module-reading-parameterization
          (lambda () (call-with-input-file path (lambda (in) (syntax->datum (read-syntax path in))))))
    [(list 'module _ _ (cons '#%module-begin body)) (filter pair? body)]))

(define (chapter-evals body)
  (filter-map (match-lambda
                [(list 'define ev (list (or 'make-raft-eval 'make-downstream-eval) _)) ev]
                [_ #f])
              body))

(define chapters
  (for/list ([path (in-directory scribblings-dir)]
             #:when (path-has-extension? path #".scrbl")
             #:unless (null? (chapter-evals (module-body path))))
    path))

(test-case "every chapter with a logged evaluator closes it as its last form"
  (check-equal? (length chapters) 8)
  (for ([path (in-list chapters)])
    (define body (module-body path))
    (match (chapter-evals body)
      [(list ev) (check-equal? (last body) `(close-eval ,ev) (path->string path))])))

(define (call-with-chapter-copy proc)
  (with-release ([dir (make-temporary-directory "raft-docs-chapters-~a") delete-directory/files])
    (for ([name (in-list '("utils.rkt" "logged-eval.rkt"))])
      (copy-file (build-path scribblings-dir name) (build-path dir name)))
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
