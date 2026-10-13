#lang racket/base

(require (only-in ffi/unsafe
                  _bytes
                  _fun
                  _int
                  _list
                  _ptr
                  _short
                  _size
                  _ssize
                  _ulong
                  define-cstruct
                  get-ffi-obj)
         (only-in ffi/unsafe/os-async-channel make-os-async-channel os-async-channel-put)
         (only-in racket/match match))

(provide await-entry
         closed-gate
         open-gate!
         release-gate
         wait-at-gate)

(define timeout-seconds 10)

(define pollin 1)

(define-cstruct _pollfd
  ([fd _int]
   [events _short]
   [revents _short]))

(define pipe-fds
  (get-ffi-obj "pipe"
               #f
               (_fun (fds : (_list o _int 2)) -> (status : _int) -> (and (zero? status) fds))))

(define close-fd (get-ffi-obj "close" #f (_fun _int -> _int)))

(define write-fd (get-ffi-obj "write" #f (_fun _int _bytes _size -> _ssize)))

(define poll-fd
  (get-ffi-obj "poll"
               #f
               (_fun #:blocking? #t (_ptr i _pollfd atomic-interior) (_ulong = 1) _int -> _int)))

(struct gate (entered read-end write-end))

(define (closed-gate)
  (match (pipe-fds)
    [(list read-end write-end) (gate (make-os-async-channel) read-end write-end)]))

(define (release-gate g)
  (close-fd (gate-write-end g))
  (close-fd (gate-read-end g)))

(define (open-gate! g)
  (write-fd (gate-write-end g) #"!" 1)
  (void))

(define (await-entry g)
  (or (sync/timeout timeout-seconds (gate-entered g))
      (error 'await-entry "no call reached the gate in ~a s" timeout-seconds)))

(define (wait-at-gate g)
  (os-async-channel-put (gate-entered g) 'entered)
  (let retry ()
    (match (poll-fd (make-pollfd (gate-read-end g) pollin 0) (* 1000 timeout-seconds))
      [1 'opened]
      [0 'timed-out]
      [_ (retry)])))
