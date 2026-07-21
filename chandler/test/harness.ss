#!chezscheme
;;; chandler/test/harness.ss --- 极简测试框架:define-suite / assert-* / run-suites
;;;
;;; 设计:每个测试库用 (define-suite name (test body ...) ...) 导出一份 suite(纯值,
;;; 不靠实例化副作用注册——空导出库不保证被实例化,故不用全局注册表)。
;;; run-tests.sps 以 prefix import 收齐各 suite,交 run-suites 运行。

(library (chandler test harness)
  (export define-suite run-suites
          assert-true assert-false assert-equal assert-raises assert-string=)
  (import (chezscheme))

  ;; (define-suite name (test-name body ...) ...) → name 绑定为 ((sym . thunk) ...)
  (define-syntax define-suite
    (syntax-rules ()
      [(_ suite-name (test-name body ...) ...)
       (define suite-name
         (list (cons 'test-name (lambda () body ...)) ...))]))

  (define (fail msg . irritants)
    (raise (condition (make-error)
                      (make-message-condition msg)
                      (make-irritants-condition irritants))))

  (define (assert-true x)
    (unless x (fail "assert-true failed" x)))

  (define (assert-false x)
    (when x (fail "assert-false failed" x)))

  (define (assert-equal expected actual)
    (unless (equal? expected actual)
      (fail "assert-equal failed" 'expected expected 'actual actual)))

  (define (assert-string= expected actual)
    (unless (and (string? actual) (string=? expected actual))
      (fail "assert-string= failed" 'expected expected 'actual actual)))

  ;; (assert-raises thunk) —— thunk 必须抛异常,否则失败
  (define (assert-raises thunk)
    (call/cc
      (lambda (k)
        (with-exception-handler
          (lambda (e) (k #t))
          (lambda () (thunk) (fail "assert-raises: expected exception, none raised"))))))

  ;; suites = ((label . ((test-name . thunk) ...)) ...);返回是否全绿
  (define (run-suites suites)
    (let ([pass 0] [failn 0])
      (for-each
        (lambda (labeled)
          (let ([label (car labeled)] [suite (cdr labeled)])
            (for-each
              (lambda (t)
                (let ([name (car t)] [thunk (cdr t)])
                  (call/cc
                    (lambda (k)
                      (with-exception-handler
                        (lambda (e)
                          (set! failn (+ failn 1))
                          (printf "  FAIL ~a / ~a: " label name)
                          (show-condition e)
                          (newline)
                          (k #f))
                        (lambda ()
                          (thunk)
                          (set! pass (+ pass 1))
                          (k #t)))))))
              suite)))
        suites)
      (printf "~%tests: ~a passed, ~a failed~%" pass failn)
      (= failn 0)))

  (define (show-condition e)
    (cond
      [(condition? e)
       (when (message-condition? e) (display (condition-message e)))
       (when (irritants-condition? e)
         (for-each (lambda (x) (display " ") (write x)) (condition-irritants e)))]
      [else (write e)])))
