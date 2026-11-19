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
    (namespace-set-variable-value! 'released-resources released-resources)
    (current-namespace)))

(define (with-who form who)
  (if who
      `(,@form #:who ',who)
      form))

(define (check-refusals refusals)
  (for* ([refusal (in-list refusals)]
         [who (in-list '(caller #f))])
    (match-define (list form text) refusal)
    (check-raft-error 'logic
                      (format "~a: ~a" (or who (car form)) text)
                      (lambda () (eval (with-who form who) namespace)))))

(define released "the device resources on device 0 were released")

(define released-refusals
  `([(device-matrix 2 2 #:resources (released-resources)) ,released]
    [(device-vector 2 #:resources (released-resources)) ,released]
    [(list->device-vector '(1) #:resources (released-resources)) ,released]
    [(list*->device-matrix '((1)) #:resources (released-resources)) ,released]
    [(flvector->device-vector (flvector 1.0) #:resources (released-resources)) ,released]
    [(list*->device-csr-matrix '((1)) #:resources (released-resources)) ,released]
    [(triplets->device-csr-matrix '(0) '(0) '(1.0) #:shape '(1 1) #:resources (released-resources))
     ,released]
    [(vector->device-vector #(1) #:resources (released-resources)) ,released]
    [(vector*->device-matrix #(#(1)) #:resources (released-resources)) ,released]
    [(list*->device-array '(1) #:resources (released-resources)) ,released]
    [(vector*->device-array #(1) #:resources (released-resources)) ,released]
    [(f32vector->device-vector (f32vector 1.0) #:resources (released-resources)) ,released]
    [(f64vector->device-vector (f64vector 1.0) #:resources (released-resources)) ,released]
    [(bytes->device-vector (bytes 0 0 0 0) #:dtype 'int32 #:resources (released-resources)) ,released]
    [(array->device-array (array #[1]) #:resources (released-resources)) ,released]
    [(matrix->device-matrix (matrix [[1]]) #:resources (released-resources)) ,released]
    [(matrix->device-vector (matrix [[1]]) #:resources (released-resources)) ,released]))

(test-gpu "W2: every upload on released resources is refused under #:who, or its own name"
  (check-refusals released-refusals))

(define conversion-refusals
  '([(list->device-vector '(3000000000) #:dtype 'int32) "3000000000 does not fit int32"]
    [(list*->device-matrix '((1e300)) #:dtype 'float32) "1e+300 does not fit float32"]
    [(list*->device-matrix '((1 2) (3))) "row 1 has 1 element, but row 0 has 2: '(3)"]
    [(list->device-vector '(a)) "cannot infer a dtype: 'a is not a real number"]
    [(triplets->device-csr-matrix '(5) '(0) '(1.0) #:shape '(2 2))
     "triplet 0 has row 5, outside [0, 2)"]
    [(bytes->device-vector (bytes 0 0 0 0 0) #:dtype 'int32)
     "5 bytes do not hold a whole number of 4-byte int32 elements"]
    [(matrix->device-vector (matrix [[1 2] [3 4]]))
     "a 2×2 matrix is neither a row nor a column matrix"]
    [(list*->device-csr-matrix '((1 2) (3))) "row 1 has 1 element, but row 0 has 2: '(3)"]
    [(list*->device-csr-matrix '((a))) "'a is not a real number"]
    [(list*->device-csr-matrix '() #:cols 3000000000)
     "shape: 3000000000 columns do not fit int32 indices"]
    [(list*->device-csr-matrix '((0 1)) #:cols 3) "row 0 has 2 elements, but #:cols is 3: '(0 1)"]
    [(triplets->device-csr-matrix '(0) '() '(1.0) #:shape '(2 2))
     "cols has 0 elements, but rows has 1"]
    [(triplets->device-csr-matrix '() '() '() #:shape '(3000000000 1))
     "shape: 3000000000 rows do not fit int32 indices"]
    [(vector*->device-matrix #(#(a))) "cannot infer a dtype: 'a is not a real number"]
    [(vector*->device-matrix #(#(1 2)) #:cols 1) "row 0 has 2 elements, but #:cols is 1: '#(1 2)"]
    [(list*->device-array '((1 2) (3))) "row 1 has 1 element, but row 0 has 2: '(3)"]
    [(list*->device-array '(1 (2))) "element 1 is a list, but element 0 is not: '(2)"]
    [(vector*->device-array #(#(a))) "cannot infer a dtype: 'a is not a real number"]
    [(array->device-array (array #[#[#[1]]]))
     "rank 3 is not supported yet; rank 1 and 2 convert, and any rank arrives in leg 3"]))

(test-gpu "W3: a conversion refusal begins with #:who, or the procedure's own name"
  (check-refusals conversion-refusals))

(test-gpu "W5: a 4 TiB request is refused as out of memory under #:who"
  (check-raft-error 'out-of-memory
                    #rx"^caller: "
                    (lambda () (device-vector (expt 2 40) #:who 'caller))))
