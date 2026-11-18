#lang racket/base

(require (only-in racket/match match match-define)
         (only-in rackunit check-equal? check-pred test-case)
         (only-in "../private/exn.rkt"
                  exn:fail:raft
                  exn:fail:raft-kind
                  exn:fail:raft?
                  raise-native
                  raise-raft))

(define (drain receiver)
  (match (sync/timeout 0 receiver)
    [#f '()]
    [(vector level message _ topic) (cons (list level topic message) (drain receiver))]))

(define (raised-and-logged thunk)
  (define receiver (make-log-receiver (current-logger) 'debug 'raft))
  (define e
    (with-handlers ([exn:fail:raft? values])
      (thunk)))
  (list (exn-message e) (drain receiver)))

(define (native text)
  (raised-and-logged (lambda () (raise-native exn:fail:raft 'demo 'logic text))))

(define (logged text)
  (list (list 'debug 'raft (string-append "raft: demo: " text))))

(define backtrace
  (string-append "RAFT failure at file=/src/fit.cu line=12: token 7\n"
                 "Obtained 2 stack frames\n"
                 "#1 in /nix/store/0000-raft/lib/libraft.so: raft::fit() +0x10 [0x7f00]\n"
                 "#2 in /nix/store/0000-raft/lib/libraft.so: main +0x20 [0x7f10]\n"))

(define native-cases
  `(("token 7" "demo: token 7" ())
    (,backtrace "demo: RAFT failure at file=/src/fit.cu line=12: token 7" ,(logged backtrace))
    ("\ntoken 7\n#1 in f" "demo: token 7" ,(logged "\ntoken 7\n#1 in f"))
    ("token 7\r\n#1 in f\r\n" "demo: token 7" ,(logged "token 7\r\n#1 in f\r\n"))
    ("token 7 \t\n#1 in f" "demo: token 7" ,(logged "token 7 \t\n#1 in f"))
    ("  token 7\n#1 in f" "demo:   token 7" ,(logged "  token 7\n#1 in f"))
    ("token 7 \t" "demo: token 7" ())
    ("token 7\n" "demo: token 7" ())
    ("token 7\r\n\r\n  \n" "demo: token 7" ())
    ("bad � byte\n#1 in f" "demo: bad � byte" ,(logged "bad � byte\n#1 in f"))
    ("token 7\n#1 in /nix/store/0000-ra" "demo: token 7"
                                         ,(logged "token 7\n#1 in /nix/store/0000-ra"))
    ("" "demo: " ())
    ("\n \n" "demo: " ())))

(test-case "a native message is its first non-blank line; the whole text goes to the raft logger"
  (for ([row (in-list native-cases)])
    (match-define (list text message log) row)
    (check-equal? (native text) (list message log) (format "~s" text))))

(test-case "a native message keeps the downstream's exception type and the kind"
  (struct exn:fail:canary exn:fail:raft ())
  (define e
    (with-handlers ([exn:fail:raft? values])
      (raise-native exn:fail:canary 'fit 1 backtrace)))
  (check-pred exn:fail:canary? e)
  (check-equal? (exn:fail:raft-kind e) 'out-of-memory)
  (check-equal? (exn-message e) "fit: RAFT failure at file=/src/fit.cu line=12: token 7"))

(test-case "a message raft composes keeps all its lines and logs nothing"
  (define advice
    "libraftrkt was found but would not load\n  found in: /opt/raft\n  the loader said: no")
  (check-equal? (raised-and-logged (lambda () (raise-raft 'raft 'generic "~a" advice)))
                (list (string-append "raft: " advice) '())))
