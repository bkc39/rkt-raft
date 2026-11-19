#lang racket/base

(require (only-in racket/match match-define)
         (only-in "../../array.rkt" device-vector)
         (only-in "../private/gpu.rkt" test-gpu)
         (only-in "../private/raft-error.rkt" check-raft-error)
         (only-in "../private/resources.rkt" released-resources))

(define-namespace-anchor here)

(define namespace
  (parameterize ([current-namespace (namespace-anchor->empty-namespace here)])
    (for-each namespace-require
              '(racket/base ffi/vector math/array math/matrix racket/flonum raft raft/compat))
    (current-namespace)))

(define (run form)
  (eval form namespace))

(define minimal-calls
  '((device-matrix 2 2) (device-vector 2)
                        (list->device-vector '(1))
                        (list*->device-matrix '((1)))
                        (flvector->device-vector (flvector 1.0))
                        (list*->device-csr-matrix '((1)))
                        (triplets->device-csr-matrix '(0) '(0) '(1.0) #:shape '(1 1))
                        (vector->device-vector #(1))
                        (vector*->device-matrix #(#(1)))
                        (list*->device-array '(1))
                        (vector*->device-array #(1))
                        (f32vector->device-vector (f32vector 1.0))
                        (f64vector->device-vector (f64vector 1.0))
                        (bytes->device-vector (bytes 0 0 0 0) #:dtype 'int32)
                        (array->device-array (array #[1]))
                        (matrix->device-matrix (matrix [[1]]))
                        (matrix->device-vector (matrix [[1]]))))

(define (with-who form who)
  (if who
      `(,@form #:who ',who)
      form))

(test-gpu "W2: every upload on released resources is refused under #:who, or its own name"
  (define r (released-resources))
  (for* ([form (in-list minimal-calls)]
         [who (in-list '(caller #f))])
    (check-raft-error 'logic
                      (format "~a: the device resources on device 0 were released"
                              (or who (car form)))
                      (lambda () (run (with-who `(,@form #:resources ,r) who))))))

(define refusals
  '([(list->device-vector '(3000000000) #:dtype 'int32) "3000000000 does not fit int32"]
    [(list*->device-matrix '((1e300)) #:dtype 'float32) "1e+300 does not fit float32"]
    [(list*->device-matrix '((1 2) (3))) "row 1 has 1 element, but row 0 has 2: '(3)"]
    [(list->device-vector '(a)) "cannot infer a dtype: 'a is not a real number"]
    [(triplets->device-csr-matrix '(5) '(0) '(1.0) #:shape '(2 2))
     "triplet 0 has row 5, outside [0, 2)"]
    [(bytes->device-vector (bytes 0 0 0 0 0) #:dtype 'int32)
     "5 bytes do not hold a whole number of 4-byte int32 elements"]
    [(matrix->device-vector (matrix [[1 2] [3 4]]))
     "a 2×2 matrix is neither a row nor a column matrix"]))

(test-gpu "W3: a conversion refusal begins with #:who, or the procedure's own name"
  (for* ([refusal (in-list refusals)]
         [who (in-list '(caller #f))])
    (match-define (list form text) refusal)
    (check-raft-error 'logic
                      (format "~a: ~a" (or who (car form)) text)
                      (lambda () (run (with-who form who))))))

(test-gpu "W5: a 4 TiB request is refused as out of memory under #:who"
  (check-raft-error 'out-of-memory
                    (pregexp (string-append "^caller: std::bad_alloc: out_of_memory: CUDA error "
                                            "\\(failed to allocate 4398046511104 bytes\\) at: \\S+: "
                                            "cudaErrorMemoryAllocation out of memory$"))
                    (lambda () (device-vector (expt 2 40) #:who 'caller))))
