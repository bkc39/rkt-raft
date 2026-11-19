#lang racket/base

(require (only-in racket/file make-temporary-file)
         (only-in rackunit check-equal? test-case))

(define (problems-in body)
  (define file (make-temporary-file "review-~a.rkt"))
  (dynamic-wind void
                (lambda ()
                  (with-output-to-file file
                                       #:exists 'truncate
                                       (lambda ()
                                         (displayln "#lang racket/base")
                                         (for-each writeln body)))
                  (parameterize ([current-namespace (make-base-namespace)])
                    (map (dynamic-require 'review/problem 'problem-message)
                         ((dynamic-require 'review/lint 'lint) file))))
                (lambda () (delete-file file))))

(test-case "quoted data is not read as code"
  (check-equal? (problems-in '((provide form) (define form '(define-job deposit x)))) '()))

(test-case "quasiquoted data is read only at its unquotes"
  (check-equal? (problems-in '((provide form) (define x 1) (define form `(define-job deposit ,x))))
                '()))

(test-case "an unquote inside a quasiquoted box, hash value or prefab field is a use"
  (check-equal? (problems-in '((provide forms) (define x 1)
                                               (define y 2)
                                               (define z 3)
                                               (define forms
                                                 (list `#& ,x `#hash((a . ,y)) `#s(p ,z)))))
                '()))

(test-case "each test-law body is its own scope, with its state bound in it"
  (define (law name)
    `(test-law ,name (state)
       (define x (random 2 state))
       (list x)))
  (check-equal? (problems-in (list (law "one") (law "two"))) '()))

(test-case "a file-local test-law is used by its forms"
  (check-equal? (problems-in '((require syntax/parse/define)
                               (define-syntax-parse-rule (test-law name:str (state:id) body:expr ...+)
                                 (let ([state name])
                                   body ...))
                               (test-law "one" (state)
                                 (string-length state))))
                '()))
