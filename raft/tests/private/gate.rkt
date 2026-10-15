#lang racket/base

(require (only-in ffi/unsafe _bytes _fun _int _list _size _ssize get-ffi-obj)
         (only-in ffi/unsafe/port unsafe-file-descriptor->port)
         (only-in racket/match match*)
         (only-in racket/port read-bytes-evt))

(provide await-entry
         closed-gate
         gate-entered-fd
         gate-fd
         gate-opener-fd
         open-gate!
         release-gate)

(define pipe-fds
  (get-ffi-obj "pipe"
               #f
               (_fun (fds : (_list o _int 2)) -> (status : _int) -> (and (zero? status) fds))))

(define close-fd (get-ffi-obj "close" #f (_fun _int -> _int)))

(define write-fd (get-ffi-obj "write" #f (_fun _int _bytes _size -> _ssize)))

(struct gate (entries entered-fd fd opener-fd))

(define (closed-gate)
  (match* ((pipe-fds) (pipe-fds))
    [((list entries-end entered-end) (list read-end write-end))
     (gate (unsafe-file-descriptor->port entries-end 'gate-entries '(read))
           entered-end
           read-end
           write-end)]))

(define (release-gate g)
  (close-input-port (gate-entries g))
  (for-each close-fd (list (gate-entered-fd g) (gate-fd g) (gate-opener-fd g))))

(define (open-gate! g)
  (write-fd (gate-opener-fd g) #"!" 1)
  (void))

(define (await-entry g [seconds 10])
  (and (sync/timeout seconds (read-bytes-evt 1 (gate-entries g))) #t))
