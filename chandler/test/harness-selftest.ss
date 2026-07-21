#!chezscheme
;;; chandler/test/harness-selftest.ss --- 验证测试框架自身 + umbrella 可解析

(library (chandler test harness-selftest)
  (export suite)
  (import (chezscheme)
          (chandler test harness)
          (chandler))

  (define-suite suite
    (umbrella-loads
      (assert-string= "0.1.0-dev" chandler-version))
    (assert-equal-works
      (assert-equal 42 (+ 40 2))
      (assert-equal '(a b) (list 'a 'b)))
    (assert-raises-works
      (assert-raises (lambda () (error 'x "boom")))
      (assert-raises (lambda () (car '()))))))
