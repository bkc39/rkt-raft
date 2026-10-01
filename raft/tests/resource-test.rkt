#lang racket/base

(require (only-in racket/generator generator in-generator yield)
         (only-in rackunit check-equal? check-exn check-pred check-regexp-match test-case)
         (only-in "../private/exn.rkt" exn:fail:raft-kind exn:fail:raft?)
         (only-in "../private/resource.rkt" with-release))

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
  (check-regexp-match #rx"^with-release: cannot re-enter its body" (exn-message e))
  (check-equal? acquisitions 1)
  (check-equal? released '(a)))
