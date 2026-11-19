#lang racket/base

(require (only-in racket/generator generator in-generator yield)
         (only-in rackunit check-equal? check-exn check-pred test-case)
         (only-in syntax/macro-testing convert-syntax-error)
         (only-in "../private/exn.rkt" exn:fail:raft exn:fail:raft-kind exn:fail:raft?)
         (only-in "../private/resource.rkt" call-with-release with-release))

(define released '())

(define (release! tag)
  (set! released (cons tag released)))

(define (fresh!)
  (set! released '()))

(test-case "resources release in reverse order on return"
  (fresh!)
  (check-equal? (with-release ([a 'a release!] [b 'b release!])
                  (list a b))
                '(a b))
  (check-equal? released '(a b)))

(test-case "a raise still releases"
  (fresh!)
  (check-exn #rx"boom"
             (lambda ()
               (with-release ([a 'a release!])
                 (error 'test "boom"))))
  (check-equal? released '(a)))

(test-case "an escape still releases"
  (fresh!)
  (check-equal? (let/ec k
                  (with-release ([a 'a release!])
                    (k 'escaped)))
                'escaped)
  (check-equal? released '(a)))

(test-case "a failed acquisition releases what was acquired before it"
  (fresh!)
  (check-exn #rx"no b"
             (lambda ()
               (with-release ([a 'a release!] [b (error 'test "no b") release!])
                 'unreached)))
  (check-equal? released '(a)))

(define x 'outer)

(test-case "an acquisition sees the enclosing binding of its own name"
  (check-equal? (with-release ([x (list 'wrapped x) void]) x) '(wrapped outer)))

(test-case "a later acquisition sees the earlier names"
  (fresh!)
  (check-equal? (with-release ([a 'a release!] [b (list a 'b) release!]) b) '(a b))
  (check-equal? released '(a (a b))))

(test-case "each release expression is evaluated once, after its acquisition"
  (fresh!)
  (define order '())
  (define (note! tag v)
    (set! order (cons tag order))
    v)
  (check-equal? (with-release ([a (note! 'acquire-a 'a) (note! 'release-a release!)]
                               [b (note! 'acquire-b 'b) (note! 'release-b release!)])
                  (note! 'body (list a b)))
                '(a b))
  (check-equal? (reverse order) '(acquire-a release-a acquire-b release-b body))
  (check-equal? released '(a b)))

(test-case "an acquisition answering #f is not released"
  (fresh!)
  (check-equal? (with-release ([a #f release!] [b 'b release!])
                  (list a b))
                '(#f b))
  (check-equal? released '(b)))

(test-case "a yield out of the body releases"
  (fresh!)
  (define g
    (generator ()
      (with-release ([a 'a release!])
        (yield a)
        'resumed)))
  (check-equal? (g) 'a)
  (check-equal? released '(a)))

(test-case "a generator resuming the body raises instead of acquiring again"
  (fresh!)
  (define acquisitions 0)
  (define (acquire! tag)
    (set! acquisitions (add1 acquisitions))
    tag)
  (define e
    (with-handlers ([exn:fail:raft? values])
      (for/list ([x (in-generator (with-release ([a (acquire! 'a) release!])
                                    (yield a)
                                    (yield a)))])
        x)))
  (check-pred exn:fail:raft? e)
  (check-equal? (exn:fail:raft-kind e) 'logic)
  (check-equal? (exn-message e) "cannot re-enter its body after its resources were released")
  (check-equal? acquisitions 1)
  (check-equal? released '(a)))

(test-case "#:who names the public form in the re-entry error"
  (fresh!)
  (define e
    (with-handlers ([exn:fail:raft? values])
      (for/list ([x (in-generator (with-release #:who 'with-device-resources ([a 'a release!])
                                    (yield a)
                                    (yield a)))])
        x)))
  (check-equal? (exn-message e)
                "with-device-resources: cannot re-enter its body after its resources were released")
  (check-equal? released '(a)))

(define (exits)
  `((return ,(lambda (proc) (call-with-values proc list)))
    (raise ,(lambda (proc)
              (with-handlers ([(lambda (e) (eq? e 'raised)) list])
                (proc (lambda _ (raise 'raised))))))
    (escape ,(lambda (proc) (call-with-values (lambda () (let/ec k (proc k))) list)))
    (yield ,(lambda (proc)
              (define g (generator () (proc yield)))
              (call-with-values g list)))))

(test-case "R3: every exit calls the release once with the acquired value and answers proc's values"
  (for ([exit (in-list (exits))])
    (fresh!)
    (define label (symbol->string (car exit)))
    (define run (cadr exit))
    (define results
      (run (lambda ([leave values])
             (call-with-release 'a
                                release!
                                (lambda (a)
                                  (leave a 1 2))))))
    (check-equal? released '(a) label)
    (check-equal? results (if (eq? (car exit) 'raise) (list 'raised) '(a 1 2)) label)))

(struct exn:fail:demo exn:fail:raft ())

(define (resumed thunk)
  (with-handlers ([exn:fail:raft? values])
    (for/list ([x (in-generator (thunk))])
      x)))

(test-case "R4: a resumed body raises its #:who and #:exn, through the form and the procedure"
  (fresh!)
  (define named
    (resumed (lambda ()
               (with-release #:who 'demo ([a 'a release!])
                 (yield a)
                 (yield a)))))
  (check-equal? (exn-message named) "demo: cannot re-enter its body after its resources were released")
  (check-equal? (exn:fail:raft-kind named) 'logic)
  (define unnamed
    (resumed (lambda ()
               (with-release ([a 'a release!])
                 (yield a)
                 (yield a)))))
  (check-equal? (exn-message unnamed) "cannot re-enter its body after its resources were released")
  (define by-form
    (resumed (lambda ()
               (with-release #:exn exn:fail:demo ([a 'a release!])
                 (yield a)
                 (yield a)))))
  (check-pred exn:fail:demo? by-form)
  (check-equal? (exn:fail:raft-kind by-form) 'logic)
  (define by-procedure
    (resumed (lambda ()
               (call-with-release 'b
                                  release!
                                  (lambda (b)
                                    (yield b)
                                    (yield b))
                                  #:who 'demo
                                  #:exn exn:fail:demo))))
  (check-pred exn:fail:demo? by-procedure)
  (check-equal? (exn-message by-procedure)
                "demo: cannot re-enter its body after its resources were released")
  (check-equal? released '(b a a a)))

(test-case "R5: a release that raises is not retried, its exception wins, and the outer ones release"
  (fresh!)
  (define raising-calls 0)
  (define (raising tag)
    (set! raising-calls (add1 raising-calls))
    (release! tag)
    (raise 'boom))
  (check-equal? (with-handlers ([symbol? values])
                  (with-release ([a 'a release!] [b 'b raising])
                    (raise 'body)))
                'boom)
  (check-equal? raising-calls 1)
  (check-equal? released '(a b)))

(test-case "R6: the release runs with breaks disabled and the break is raised after it returns"
  (fresh!)
  (define (breaking tag)
    (break-thread (current-thread))
    (sleep 0.05)
    (release! (list 'done tag)))
  (define e
    (with-handlers ([exn:break? values])
      (with-release ([a 'a breaking])
        'body)))
  (check-pred exn:break? e)
  (check-equal? released '((done a))))

(test-case "R7: #:who and #:exn come in either order, each at most once"
  (fresh!)
  (check-equal? (with-release #:who 'demo #:exn exn:fail:demo ([a 'a release!]) a) 'a)
  (check-equal? (with-release #:exn exn:fail:demo #:who 'demo ([b 'b release!]) b) 'b)
  (check-equal? released '(b a))
  (check-exn exn:fail:syntax?
             (lambda () (convert-syntax-error (with-release #:who 'a #:who 'b ([c 'c void]) c))))
  (check-exn exn:fail:syntax?
             (lambda ()
               (convert-syntax-error (with-release #:exn exn:fail:demo #:exn exn:fail:demo
                                       ([c 'c void])
                                       c)))))
