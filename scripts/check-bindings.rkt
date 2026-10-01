#lang racket/base

(require (only-in file/sha1 bytes->hex-string)
         (only-in racket/list group-by)
         (only-in racket/port with-output-to-string)
         (only-in racket/set list->set set->list set-subtract)
         (only-in racket/string string-split)
         (only-in racket/system system*)
         (only-in raft/tests/private/bindings binding-c-id binding-forms))

(define library
  (build-path (collection-file-path "native-libs" "raft") "libraftrkt.so"))

(define (exports path)
  (define nm (or (find-executable-path "nm")
                 (error 'check-bindings "nm is not on PATH")))
  (define out
    (with-output-to-string
      (lambda ()
        (unless (system* nm "-D" "--defined-only" (path->string path))
          (error 'check-bindings "nm failed on ~a" path)))))
  (for*/list ([line (in-list (string-split out "\n"))]
              [fields (in-value (string-split line))]
              #:when (= (length fields) 3)
              [symbol (in-value (caddr fields))]
              #:when (regexp-match? #rx"^rr_" symbol))
    symbol))

(define (sorted-difference a b)
  (sort (set->list (set-subtract (list->set a) (list->set b))) string<?))

(module+ main
  (printf "libraftrkt: ~a (sha256 ~a)\n"
          library
          (substring (bytes->hex-string (call-with-input-file library sha256-bytes)) 0 16))
  (define bound (map binding-c-id (binding-forms)))
  (define duplicates
    (for/list ([same (in-list (group-by values bound))]
               #:when (pair? (cdr same)))
      (car same)))
  (define exported (exports library))
  (define unbound (sorted-difference exported bound))
  (define missing (sorted-difference bound exported))
  (for ([id (in-list unbound)])
    (printf "UNBOUND  ~a is exported but has no binding\n" id))
  (for ([id (in-list missing)])
    (printf "MISSING  ~a is bound but not exported\n" id))
  (for ([id (in-list duplicates)])
    (printf "TWICE    ~a is bound more than once\n" id))
  (printf "~a exports, ~a bindings\n" (length exported) (length bound))
  (unless (and (null? unbound) (null? missing) (null? duplicates))
    (exit 1)))
