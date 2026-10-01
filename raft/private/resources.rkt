#lang racket/base

(require (for-syntax racket/base
                     ;; whole-module: syntax-parse needs its syntax classes
                     syntax/parse)
         ;; whole-module: its syntax classes come with it
         syntax/parse/define)

(provide current-device-resources
         device-resources
         device-resources?
         memory-resource-kind
         resources-device
         resources-handle
         resources-sync!
         with-device-resources)

(struct device-resources (handle device)
  #:name device-resources-type
  #:constructor-name wrap-resources)

(define (device-resources #:device [device 0])
  (error 'device-resources "unimplemented"))

(define (resources-device r)
  (error 'resources-device "unimplemented"))

(define (resources-handle who r)
  (error who "unimplemented"))

(define (resources-sync! r)
  (error 'resources-sync! "unimplemented"))

(define (current-device-resources [device 0])
  (error 'current-device-resources "unimplemented"))

(define (memory-resource-kind [device 0])
  (error 'memory-resource-kind "unimplemented"))

(begin-for-syntax
  (define-syntax-class resources-binding
    #:description "a [name resources-expr] binding"
    (pattern [name:id init:expr])))

(define-syntax-parse-rule (with-device-resources (b:resources-binding ...) body:expr ...+)
  (error 'with-device-resources "unimplemented"))
