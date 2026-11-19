#lang racket/base

(require (only-in rackunit check-equal? check-true test-case)
         (only-in "../../private/dtype.rkt" code->dtype dtype->code dtype-itemsize dtypes op-table)
         (only-in "../../private/foreign/array.rkt" rr-view-size)
         (only-in "../../private/foreign/host.rkt" dtype-itemsize-matches?))

(test-case "the shim's dtype table is the four M1 dtypes, in code order"
  (check-equal? dtypes '(float32 float64 int32 int64))
  (check-equal? (map dtype-itemsize dtypes) '(4 8 4 8)))

(test-case "every dtype code round-trips through its name"
  (for ([d (in-list dtypes)]
        [code (in-naturals)])
    (check-equal? (dtype->code d) code)
    (check-equal? (code->dtype (dtype->code d)) d)))

(test-case "the host element types have the shim's item sizes"
  (for ([d (in-list dtypes)])
    (check-true (dtype-itemsize-matches? d (dtype-itemsize d)) (format "~a" d))))

(test-case "the op table lists each op with its dtypes and layouts"
  (define (entry dtypes)
    (hasheq 'module 'array 'dtypes dtypes 'layouts '(row-major col-major)))
  (check-equal? op-table
                (hasheq 'contiguous (entry '(float32 float64 int32 int64))
                        'csr_indices (entry '(int32 int64))
                        'csr_data (entry '(float32 float64))
                        'gather (entry '(float32 float64 int32 int64))
                        'gather_indices (entry '(int32 int64))
                        'select (entry '(float32 float64 int32 int64))
                        'select_mask (entry '(int32 int64))
                        'compare (entry '(float32 float64 int32 int64)))))

(test-case "the rr_view mirror has the C struct's size"
  (check-equal? rr-view-size 152))
