#lang racket/base

(require (only-in racket/match match)
         (only-in racket/path file-name-from-path)
         (only-in setup/dirs find-share-dir))

(provide (struct-out cuda-wheel)
         (struct-out wheel-member)
         cuda-wheel-dir
         cuda-wheel-libraries
         cuda-wheel-root
         cuda-wheel-roots
         locate-cuda-wheel
         read-cuda-wheels
         wheel-member-name)

(struct cuda-wheel (name version cuda url sha256 size members))

(struct wheel-member (path size))

(define (read-cuda-wheels path)
  (for/hash ([pin (in-list (call-with-input-file path read))])
    (match pin
      [(list name
             (list 'version version)
             (list 'cuda cuda)
             (list 'url url)
             (list 'sha256 sha256)
             (list 'size size)
             (cons 'members members))
       (values name
               (cuda-wheel name
                           version
                           cuda
                           url
                           sha256
                           size
                           (map (lambda (member) (apply wheel-member member)) members)))])))

(define (wheel-member-name member)
  (path->string (file-name-from-path (wheel-member-path member))))

(define (cuda-wheel-libraries wheel)
  (map wheel-member-name (cuda-wheel-members wheel)))

(define (cuda-wheel-dir root wheel)
  (simplify-path (build-path root
                             "rapids"
                             (cuda-wheel-cuda wheel)
                             (format "~a-~a" (cuda-wheel-name wheel) (cuda-wheel-version wheel))
                             "lib")))

(define (cuda-wheel-present? dir wheel)
  (for/and ([member (in-list (cuda-wheel-members wheel))])
    (define file (build-path dir (wheel-member-name member)))
    (and (file-exists? file) (= (file-size file) (wheel-member-size member)))))

(define (cuda-wheel-root user-specific?)
  (if user-specific?
      (find-system-path 'addon-dir)
      (find-share-dir)))

(define (cuda-wheel-roots)
  (filter values (list (cuda-wheel-root #t) (cuda-wheel-root #f))))

(define (locate-cuda-wheel wheel roots)
  (for/first ([root (in-list roots)]
              #:when (cuda-wheel-present? (cuda-wheel-dir root wheel) wheel))
    (cuda-wheel-dir root wheel)))
