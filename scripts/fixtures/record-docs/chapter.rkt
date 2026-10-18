#lang racket/base

(require (for-syntax racket/base
                     (only-in compiler/cm-accomplice register-external-file))
         (only-in scribble/core part style)
         (only-in scribble/example examples make-base-eval)
         (only-in scribble/html-render render-mixin)
         (only-in scribble/render render)
         (only-in "logged-eval.rkt" close-logged-eval docs-mode make-logged-eval))

(define-syntax (register-log! stx)
  (define log (build-path (current-load-relative-directory) "logs" "sample.rktd"))
  (when (file-exists? log)
    (register-external-file log))
  #'(void))

(register-log!)

(define ev (make-logged-eval (docs-mode) "raft/scribblings/logs/sample.rktd" make-base-eval))

(define block
  (examples #:eval ev
            #:label #f
            (define rows '((1.0 2.0) (3.0 4.0)))
            (if (getenv "SAMPLE_RAISE")
                (error 'sample "raised outside eval:error")
                (length rows))
            (eval:error (error 'lookup (getenv "SAMPLE_MESSAGE")))))

(close-logged-eval ev)

(render (list (part #f '() '("Sample") (style #f '()) '() (list block) '()))
        (list "sample")
        #:render-mixin render-mixin
        #:dest-dir (vector-ref (current-command-line-arguments) 0))
