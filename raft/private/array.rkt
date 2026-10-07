#lang racket/base

(require (only-in racket/string string-contains? string-join string-replace)
         (only-in "dtype.rkt" code->dtype dtype->code dtype-itemsize)
         (only-in "error.rkt" call/raft exn:fail:raft?)
         (only-in "foreign/array-api.rkt"
                  rr-array-contiguous
                  rr-array-create
                  rr-buffer-read
                  rr-buffer-ready
                  rr-buffer-write)
         (only-in "foreign/array.rkt"
                  blank-view
                  describe-view!
                  rr-buffer-view
                  view-device
                  view-dtype-code
                  view-shape
                  view-strides)
         (only-in "foreign/host.rkt" host-getter host-memory)
         (only-in "foreign/memory.rkt" released? rr-buffer-free)
         (only-in "print.rkt" array-text summarised?)
         (only-in "resources.rkt" in-backoff resources-handle))

(provide allocate-array
         array-buffer-handle
         array-device
         array-rank
         bound-view
         buffer->device-array ;; noqa
         canonical-strides
         contiguous-array
         device-array-buffer
         device-array-dtype
         device-array-shape
         device-array-strides
         device-array?
         has-layout?
         numel
         read-all
         read-array
         release-array!
         settled-view
         strides->layout
         write-array!)

(struct buffer (handle device phantom))

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
     (define strides
       (for/fold ([strides '()]
                  [step 1]
                  #:result strides)
                 ([extent (in-list ordered)])
         (values (cons step strides) (* step extent))))
     (if (eq? layout 'row-major)
         strides
         (reverse strides))]))

(define (strides-in? layout shape strides)
  (define canonical (canonical-strides layout shape))
  (and canonical
       (for/and ([extent (in-list shape)]
                 [stride (in-list strides)]
                 [expected (in-list canonical)])
         (or (<= extent 1) (= stride expected)))))

(define (has-layout? a layout)
  (strides-in? layout (device-array-shape a) (device-array-strides a)))

(define (strides->layout shape strides)
  (cond
    [(strides-in? 'row-major shape strides) 'row-major]
    [(strides-in? 'col-major shape strides) 'col-major]
    [else 'strided]))

(define (view->array handle view)
  (define shape (view-shape view))
  (define dtype (code->dtype (view-dtype-code view)))
  (define bytes (* (apply * shape) (dtype-itemsize dtype)))
  (buffer->device-array (buffer handle (view-device view) (make-phantom-bytes bytes))
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
                 (rr-array-create (resources-handle who resources) dtype shape layout view))))
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

(define (read-all who a)
  (read-array who a (host-memory (* (numel a) (dtype-itemsize (device-array-dtype a))))))

(define (release-array! a)
  (define b (device-array-buffer a))
  (rr-buffer-free (buffer-handle b))
  (set-phantom-bytes! (buffer-phantom b) 0))

(define (element-reader who a)
  (define dtype (device-array-dtype a))
  (define get (host-getter dtype))
  (define itemsize (dtype-itemsize dtype))
  (cond
    [(summarised? (device-array-shape a))
     (lambda (index) (get (read-array who a (host-memory itemsize) index) 0))]
    [else
     (define all (read-all who a))
     (lambda (index) (get all index))]))

(define memory-prefixes (hasheq 'device "cuda"))

(define (values-text a)
  (define strides (device-array-strides a))
  (cond
    [(released? (array-buffer-handle a)) "<released>"]
    [else
     (with-handlers ([exn:fail:raft? (lambda (e)
                                       (format "<values unavailable: ~a>" (exn-message e)))])
       (define read-element (element-reader 'device-array a))
       (array-text (device-array-dtype a)
                   (device-array-shape a)
                   (lambda indices (read-element (apply + (map * indices strides))))))]))

(define (bound-view who a)
  (define view
    (describe-view! (blank-view)
                    (dtype->code (device-array-dtype a))
                    (device-array-shape a)
                    (device-array-strides a)))
  (call/raft who (lambda () (rr-buffer-view (array-buffer-handle a) (device-array-offset a) view)))
  view)

(define (settled-view who a)
  (await who a)
  (bound-view who a))

(define (array->string a)
  (define shape (device-array-shape a))
  (define strides (device-array-strides a))
  (define text (values-text a))
  (define matrix? (= (length shape) 2))
  (define header
    (string-join
     `(,(format "~a~a" (device-array-dtype a) (shape-text shape))
       ,@(if matrix?
             (list (symbol->string (strides->layout shape strides)))
             '())
       ,(format "~a:~a" (hash-ref memory-prefixes (device-array-memory a)) (array-device a)))
     " "))
  (define kind (if matrix? "device-matrix" "device-vector"))
  (if (string-contains? text "\n")
      (format "#<~a ~a\n ~a>" kind header (string-replace text "\n" "\n "))
      (format "#<~a ~a ~a>" kind header text)))

(define (shape-text shape)
  (string-join (map number->string shape) "×" #:before-first "[" #:after-last "]"))
