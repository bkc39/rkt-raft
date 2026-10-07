#lang racket/base

(require (only-in pict
                  blank
                  cb-find
                  cc-find
                  cc-superimpose
                  colorize
                  ct-find
                  filled-rectangle
                  frame
                  hc-append
                  ht-append
                  inset
                  lc-find
                  pict-height
                  pict-width
                  pin-arrow-line
                  rc-find
                  text
                  vc-append
                  vl-append))

(provide lifetime-diagram)

(define font-size 13)

(define (words s)
  (text s null font-size))

(define (code s)
  (text s 'modern font-size))

(define (node fill . lines)
  (define body (inset (apply vl-append 3 lines) 8 6))
  (cc-superimpose (colorize (filled-rectangle (pict-width body) (pict-height body)) fill)
                  (frame body #:color "gray")))

(define (heading s)
  (colorize (text s '(bold) font-size) "dimgray"))

(define racket-fill "aliceblue")
(define gpu-fill "honeydew")
(define release-fill "seashell")

(define call (node racket-fill (code "(device-matrix 1000 128 #:resources r)")))
(define view-a (node racket-fill (words "array: shape, strides,") (words "offset, dtype")))
(define buffer
  (node racket-fill
        (words "buffer: native handle, device, bytes")
        (words "phantom bytes: the GC sees the size")))
(define resources (node racket-fill (words "resources r: a CUDA stream,") (words "library handles")))
(define scoped
  (node release-fill
        (hc-append (code "with-device-resources") (words ": releases r at body exit"))
        (hc-append (code "with-array-views") (words ": holds the arrays for a native"))
        (words "call, then clears its views")))
(define pool
  (node gpu-fill (words "RMM async pool on the device") (code "cudaMallocAsync / cudaFreeAsync")))
(define finalizer
  (node release-fill
        (words "GC finalizer, after the last reference:")
        (words "set the device, free on the stream")))

(define left-lane
  (vc-append 38 call view-a buffer (ht-append 60 (vc-append 38 resources scoped) finalizer)))

(define canvas
  (ht-append 110
             (vc-append 12 (heading "Racket heap") left-lane)
             (vc-append 12
                        (heading "GPU memory")
                        (blank 0 (pict-height (vc-append 38 call view-a)))
                        (blank 0 26)
                        pool)))

(define (arrow p from find-from to find-to note #:x [x 0] #:y [y 0])
  (pin-arrow-line 8
                  p
                  from
                  find-from
                  to
                  find-to
                  #:label (colorize (words note) "dimgray")
                  #:x-adjust-label x
                  #:y-adjust-label y
                  #:line-width 1.2))

(define lifetime-diagram
  (let* ([p canvas]
         [p (arrow p call cb-find view-a ct-find "returns" #:x -40)]
         [p (arrow p view-a cb-find buffer ct-find "")]
         [p (arrow p buffer rc-find pool lc-find "allocates on r's stream" #:y -12)]
         [p (arrow p buffer cb-find resources ct-find "keeps alive" #:x -55)]
         [p (arrow p buffer cb-find finalizer ct-find "last reference dropped" #:x 95)]
         [p (arrow p finalizer rc-find pool cb-find "frees in stream order" #:x 85 #:y 10)]
         [p (arrow p scoped ct-find resources cb-find "")])
    (inset p 10)))
