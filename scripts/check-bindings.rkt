#lang racket/base

(require (only-in file/sha1 bytes->hex-string)
         (only-in racket/list filter-map group-by)
         (only-in racket/match match match-lambda)
         (only-in racket/port with-output-to-string)
         (only-in racket/string string-split)
         (only-in racket/system system*)
         (only-in raft/tests/private/bindings binding-c-id foreign-bindings))

(define library
  (build-path (collection-file-path "native-libs" "raft") "libraftrkt.so"))

(define (nm-output path)
  (define nm (or (find-executable-path "nm")
                 (error 'check-bindings "nm is not on PATH")))
  (with-output-to-string
    (lambda ()
      (unless (system* nm "-D" "--defined-only" (path->string path))
        (error 'check-bindings "nm failed on ~a" path)))))

(define (exports path)
  (for*/list ([line (in-list (string-split (nm-output path) "\n"))]
              [symbol (in-value (match (string-split line)
                                  [(list _ _ symbol) symbol]
                                  [_ #f]))]
              #:when (and symbol (regexp-match? #rx"^rr_" symbol)))
    symbol))

(define (missing-from present wanted)
  (sort (remove* present wanted) string<?))

(define (main)
  (define digest (call-with-input-file library sha256-bytes))
  (printf "libraftrkt: ~a (sha256 ~a)\n" library (substring (bytes->hex-string digest) 0 16))
  (define bound (map binding-c-id (foreign-bindings)))
  (define duplicates
    (filter-map (match-lambda [(list* id _ _) id] [_ #f])
                (group-by values bound)))
  (define exported (exports library))
  (define unbound (missing-from bound exported))
  (define missing (missing-from exported bound))
  (for ([id (in-list unbound)])
    (printf "UNBOUND  ~a is exported but has no binding\n" id))
  (for ([id (in-list missing)])
    (printf "MISSING  ~a is bound but not exported\n" id))
  (for ([id (in-list duplicates)])
    (printf "TWICE    ~a is bound more than once\n" id))
  (printf "~a exports, ~a bindings\n" (length exported) (length bound))
  (unless (and (null? unbound) (null? missing) (null? duplicates))
    (exit 1)))

(module+ main
  (main))
