#lang racket/base

(require (only-in scribble/core part style)
         (only-in scribble/example examples make-base-eval)
         (only-in scribble/html-render render-mixin)
         (only-in scribble/render render)
         (only-in "../raft/scribblings/logged-eval.rkt" close-logged-eval docs-mode make-logged-eval))

(define ev (make-logged-eval (docs-mode) "raft/scribblings/logs/sample.rktd" make-base-eval))

(define block
  (examples #:eval ev
            #:label #f
            (define rows '((1.0 2.0) (3.0 4.0)))
            (length rows)
            (eval:error (error 'lookup (getenv "SAMPLE_MESSAGE")))))

(close-logged-eval ev)

(render (list (part #f '() '("Sample") (style #f '()) '() (list block) '()))
        (list "sample")
        #:render-mixin render-mixin
        #:dest-dir (vector-ref (current-command-line-arguments) 0))
