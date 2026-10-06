#lang racket/base

(require (only-in racket/match match match-define)
         (only-in rackunit check-equal? check-exn check-false check-pred check-true test-case)
         (only-in "../main.rkt"
                  raft-abi
                  raft-abi-cccl
                  raft-abi-cuda-runtime
                  raft-abi-handle-size
                  raft-abi-raft
                  raft-abi-resource-types
                  raft-abi-rmm
                  raft-abi-version
                  raft-abi?
                  raft-version))

(define public-names
  '(current-device-resources device-count
                             device-resources
                             device-resources?
                             exn:fail:raft
                             exn:fail:raft-kind
                             exn:fail:raft?
                             raft-abi
                             raft-abi-cccl
                             raft-abi-cuda-runtime
                             raft-abi-handle-size
                             raft-abi-raft
                             raft-abi-resource-types
                             raft-abi-rmm
                             raft-abi-version
                             raft-abi?
                             raft-version
                             resources-device
                             resources-sync!
                             struct:exn:fail:raft
                             with-device-resources))

(define array-names
  '(contiguous contiguous?
               device-array?
               device-matrix
               device-matrix->list*
               device-matrix?
               device-vector
               device-vector->flvector
               device-vector->list
               device-vector?
               dtype
               flvector->device-vector
               layout
               list*->device-matrix
               list->device-vector
               numel
               shape
               strides))

(define compat-names
  '(array->device-array bytes->device-vector
                        device-array->array
                        device-array->list*
                        device-array->vector*
                        device-matrix->list*
                        device-matrix->matrix
                        device-matrix->vector*
                        device-vector->bytes
                        device-vector->col-matrix
                        device-vector->f32vector
                        device-vector->f64vector
                        device-vector->flvector
                        device-vector->list
                        device-vector->row-matrix
                        device-vector->vector
                        f32vector->device-vector
                        f64vector->device-vector
                        flvector->device-vector
                        list*->device-array
                        list*->device-matrix
                        list->device-vector
                        matrix->device-matrix
                        matrix->device-vector
                        vector*->device-array
                        vector*->device-matrix
                        vector->device-vector))

(define (phase-0-exports mod)
  (module-declared? mod #t)
  (define-values (variables syntax) (module->exports mod))
  (sort (for*/list ([exports (in-list (append variables syntax))]
                    [entry (in-list (match exports
                                      [(cons 0 entries) entries]
                                      [_ '()]))])
          (match-define (cons name _) entry)
          name)
        symbol<?))

(define unsafe-names '(raft-abi-pointer resources->handle-pointer status-checker with-array-views))

(test-case "raft/core, raft/array, raft/compat, raft/unsafe and raft export exactly the documented names"
  (check-equal? (phase-0-exports 'raft/core) public-names)
  (check-equal? (phase-0-exports 'raft/array) array-names)
  (check-equal? (phase-0-exports 'raft/compat) compat-names)
  (check-equal? (phase-0-exports 'raft/unsafe) unsafe-names)
  (check-equal? (phase-0-exports 'raft) (sort (append public-names array-names) symbol<?)))

(test-case "raft does not load math-lib; raft/compat does"
  (define (loads-math? mod)
    (dynamic-require mod #f)
    (define source (current-namespace))
    (parameterize ([current-namespace (make-base-empty-namespace)])
      (namespace-attach-module source mod)
      (for/or ([math (in-list '(math math/array math/base math/flonum math/matrix))])
        (module-declared? math #f))))
  (check-false (loads-math? 'raft))
  (check-true (loads-math? 'raft/compat)))

(test-case "raft-version names the pinned RAFT release"
  (check-equal? (raft-version) "26.08.00"))

(test-case "raft-abi describes the headers the shim was compiled against"
  (define abi (raft-abi))
  (check-pred raft-abi? abi)
  (check-equal? (raft-abi-version abi) 1)
  (check-equal? (raft-abi-raft abi) (raft-version))
  (check-equal? (raft-abi-rmm abi) "26.08.00")
  (check-equal? (raft-abi-cccl abi) "3.4.3")
  (check-equal? (raft-abi-cuda-runtime abi) "13.2")
  (check-equal? (raft-abi-resource-types abi) 22)
  (check-pred exact-positive-integer? (raft-abi-handle-size abi)))

(test-case "raft-abi is the same value every time"
  (check-equal? (raft-abi) (raft-abi))
  (check-false (eq? (raft-abi) (raft-abi))))

(test-case "raft-abi prints its fields"
  (check-equal? (format "~a" (raft-abi))
                (format (string-append "#<raft-abi raft 26.08.00 rmm 26.08.00 cccl 3.4.3"
                                       " cuda-runtime 13.2 version 1 resource-types 22"
                                       " handle-size ~a>")
                        (raft-abi-handle-size (raft-abi))))
  (check-equal? (format "~s" (raft-abi)) (format "~a" (raft-abi))))

(test-case "struct-copy changes one field and equal? sees it"
  (define abi (raft-abi))
  (define newer (struct-copy raft-abi abi [raft "26.10.00"]))
  (check-pred raft-abi? newer)
  (check-equal? (raft-abi-raft newer) "26.10.00")
  (check-equal? (raft-abi-rmm newer) (raft-abi-rmm abi))
  (check-false (equal? newer abi))
  (check-equal? (struct-copy raft-abi newer [raft (raft-abi-raft abi)]) abi))

(test-case "the raft-abi pattern takes any subset of the fields by keyword"
  (match-define (raft-abi #:raft raft #:cccl cccl) (raft-abi))
  (check-equal? (list raft cccl) '("26.08.00" "3.4.3"))
  (match-define (raft-abi #:version version
                          #:raft _
                          #:rmm rmm
                          #:cccl _
                          #:cuda-runtime cuda-runtime
                          #:resource-types resource-types
                          #:handle-size handle-size)
    (raft-abi))
  (check-equal? (list version rmm cuda-runtime resource-types) '(1 "26.08.00" "13.2" 22))
  (check-equal? handle-size (raft-abi-handle-size (raft-abi)))
  (check-true (match (raft-abi)
                [(raft-abi) #t]))
  (check-equal? (match (struct-copy raft-abi (raft-abi) [raft "26.10.00"])
                  [(raft-abi #:raft "26.08.00") 'this-release]
                  [(raft-abi #:raft other) other])
                "26.10.00")
  (check-false (match 'not-a-tag
                 [(raft-abi) #t]
                 [_ #f])))

(test-case "raft-abi is a procedure in expression position"
  (check-equal? (map (lambda (query) (query)) (list raft-abi)) (list (raft-abi))))

(test-case "an unknown raft-abi field keyword is a syntax error naming the fields"
  (define namespace (make-base-namespace))
  (parameterize ([current-namespace namespace])
    (namespace-require 'racket/match)
    (namespace-require 'raft))
  (check-exn (lambda (e)
               (and (exn:fail:syntax? e)
                    (regexp-match? (string-append "^raft-abi: expected one of #:version #:raft #:rmm"
                                                  " #:cccl #:cuda-runtime #:resource-types"
                                                  " #:handle-size")
                                   (exn-message e))
                    (regexp-match? #rx"at: #:release" (exn-message e))))
             (lambda ()
               (parameterize ([current-namespace namespace])
                 (expand '(match (raft-abi)
                            [(raft-abi #:release r) r]))))))
