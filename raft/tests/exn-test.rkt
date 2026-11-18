#lang racket/base

(require (only-in racket/match match-define)
         (only-in rackunit check-equal? test-case)
         (only-in "../private/exn.rkt" exn:fail:raft raise-native raise-raft)
         (only-in "private/raft-error.rkt"
                  check-raft-error
                  exn:fail:canary
                  exn:fail:canary?
                  raised-and-logged))

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
    ("\n \n" "demo: " ())
    ("a\rb" "demo: a" ,(logged "a\rb"))
    (" \t\ntoken 7\n#1" "demo: token 7" ,(logged " \t\ntoken 7\n#1"))
    ("\ntoken 7" "demo: token 7" ())
    ("a b" "demo: a b" ())
    ("a\u0085b" "demo: a\u0085b" ())
    ("a\u2028b" "demo: a\u2028b" ())
    ("\v\ntoken 7" "demo: token 7" ())
    ("\u00A0\ntoken 7" "demo: token 7" ())
    ("\u3000\ntoken 7" "demo: token 7" ())
    ("\f\ntoken 7" "demo: token 7" ())
    ("token 7\v\u00A0\u3000" "demo: token 7" ())
    ("\u00A0token 7" "demo: \u00A0token 7" ())))

(test-case "a native message is its first non-blank line; the whole text goes to the raft logger"
  (for ([row (in-list native-cases)])
    (match-define (list text message log) row)
    (check-equal? (native text) (list message log) (format "~s" text))))

(test-case "a native message keeps the downstream's exception type and the kind"
  (check-raft-error 'out-of-memory
                    "fit: RAFT failure at file=/src/fit.cu line=12: token 7"
                    #:exn exn:fail:canary?
                    (lambda () (raise-native exn:fail:canary 'fit 1 backtrace))))

(test-case "a message raft composes keeps all its lines and logs nothing"
  (define advice
    "libraftrkt was found but would not load\n  found in: /opt/raft\n  the loader said: no")
  (check-equal? (raised-and-logged (lambda () (raise-raft 'raft 'generic "~a" advice)))
                (list (string-append "raft: " advice) '())))
