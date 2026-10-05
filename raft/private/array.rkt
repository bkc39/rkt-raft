#lang racket/base

(require (only-in racket/string string-join)
         (only-in "dtype.rkt" code->dtype dtype->code dtype-itemsize)
         (only-in "error.rkt" call/raft)
         (only-in "foreign/array-api.rkt"
                  rr-array-contiguous
                  rr-array-create
                  rr-buffer-read
                  rr-buffer-ready
                  rr-buffer-write)
         (only-in "foreign/array.rkt"
                  blank-view
                  describe-view!
                  view-device
                  view-dtype-code
                  view-shape
                  view-strides)
         (only-in "foreign/host.rkt" host-getter host-memory)
         (only-in "print.rkt" array-text summarised?)
         (only-in "resources.rkt" in-backoff resources-handle))

(provide allocate-array
         array-buffer-bytes
         array-buffer-handle
         array-device
         array-rank
         canonical-strides
         contiguous-array
         device-array-dtype
         device-array-shape
         device-array-strides
         device-array?
         has-layout?
         numel
         read-array
         strides->layout
         write-array!)

(struct buffer (handle device bytes phantom))

(struct device-array (buffer offset shape strides dtype memory)
  #:constructor-name buffer->device-array
  #:property prop:custom-write
  (lambda (a port _mode) (write-string (array->string a) port)))

(define (numel a)
  (apply * (device-array-shape a)))

(define (array-rank a)
  (length (device-array-shape a)))

(define (array-device a)
  (buffer-device (device-array-buffer a)))

(define (array-buffer-handle a)
  (buffer-handle (device-array-buffer a)))

(define (array-buffer-bytes a)
  (buffer-bytes (device-array-buffer a)))

(define (canonical-strides layout shape)
  (define ordered
    (case layout
      [(row-major) (reverse shape)]
      [(col-major) shape]
      [else #f]))
  (cond
    [(not ordered) #f]
    [(memv 0 shape) (map (lambda (_) 0) shape)]
    [else
     (let loop ([extents ordered]
                [step 1]
                [strides '()])
       (if (null? extents)
           (if (eq? layout 'row-major)
               strides
               (reverse strides))
           (loop (cdr extents) (* step (car extents)) (cons step strides))))]))

(define (has-layout? a layout)
  (equal? (device-array-strides a) (canonical-strides layout (device-array-shape a))))

(define (strides->layout shape strides)
  (cond
    [(equal? strides (canonical-strides 'row-major shape)) 'row-major]
    [(equal? strides (canonical-strides 'col-major shape)) 'col-major]
    [else 'strided]))

(define (view->array handle view)
  (define shape (view-shape view))
  (define dtype (code->dtype (view-dtype-code view)))
  (define bytes (* (apply * shape) (dtype-itemsize dtype)))
  (buffer->device-array (buffer handle (view-device view) bytes (make-phantom-bytes bytes))
                        0
                        shape
                        (view-strides view)
                        dtype
                        'device))

(define (allocate-array who resources dtype layout shape)
  (define view (blank-view))
  (define handle
    (call/raft who
               (lambda ()
                 (rr-array-create (resources-handle who resources) dtype layout shape view))))
  (view->array handle view))

(define (contiguous-array who a layout)
  (define source
    (describe-view! (blank-view)
                    (dtype->code (device-array-dtype a))
                    (device-array-shape a)
                    (device-array-strides a)))
  (define view (blank-view))
  (define handle
    (call/raft
     who
     (lambda ()
       (rr-array-contiguous (array-buffer-handle a) (device-array-offset a) source layout view))))
  (view->array handle view))

(define (await who a)
  (define handle (array-buffer-handle a))
  (for ([pause (in-backoff)]
        #:break (eq? 'ready (call/raft who (lambda () (rr-buffer-ready handle)))))
    (sleep pause)))

(define (byte-offset a first)
  (+ (device-array-offset a) (* first (dtype-itemsize (device-array-dtype a)))))

(define (read-array who a host [first 0])
  (await who a)
  (call/raft who (lambda () (rr-buffer-read (array-buffer-handle a) (byte-offset a first) host)))
  host)

(define (write-array! who a host)
  (await who a)
  (call/raft who (lambda () (rr-buffer-write (array-buffer-handle a) (device-array-offset a) host)))
  a)

(define (element-reader who a)
  (define dtype (device-array-dtype a))
  (define get (host-getter dtype))
  (define itemsize (dtype-itemsize dtype))
  (if (summarised? (device-array-shape a))
      (lambda (index) (get (read-array who a (host-memory itemsize) index) 0))
      (let ([all (read-array who a (host-memory (* itemsize (numel a))))])
        (lambda (index) (get all index)))))

(define (array->string a)
  (define shape (device-array-shape a))
  (define strides (device-array-strides a))
  (define read-element (element-reader 'device-array a))
  (define values-text
    (array-text (device-array-dtype a)
                shape
                (lambda indices (read-element (apply + (map * indices strides))))))
  (define header
    (string-join (append (list (format "~a~a" (device-array-dtype a) (shape-text shape)))
                         (if (= (length shape) 2)
                             (list (symbol->string (strides->layout shape strides)))
                             '())
                         (list (format "cuda:~a" (array-device a))))
                 " "))
  (define kind (if (= (length shape) 2) "device-matrix" "device-vector"))
  (if (regexp-match? #rx"\n" values-text)
      (format "#<~a ~a\n ~a>" kind header (regexp-replace* #rx"\n" values-text "\n "))
      (format "#<~a ~a ~a>" kind header values-text)))

(define (shape-text shape)
  (string-append "[" (string-join (map number->string shape) "×") "]"))
