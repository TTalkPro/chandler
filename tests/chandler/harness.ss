#!chezscheme
;;; tests/chandler/harness.ss --- 极简测试框架:define-suite / assert-* / run-suites
;;;
;;; 设计:每个测试库用 (define-suite name (test body ...) ...) 导出一份 suite(纯值,
;;; 不靠实例化副作用注册——空导出库不保证被实例化,故不用全局注册表)。
;;; run-tests.sps 以 prefix import 收齐各 suite,交 run-suites 运行。

(library (tests chandler harness)
  (export define-suite run-suites
          assert-true assert-false assert-equal assert-raises assert-string=
          register-test-tmp!)
  (import (chezscheme)
          (chandler fs))

  ;; 每个测试临时目录登记在此,run-suites 在**每条用例之后**统一清 —— 夹具的 mktmp
  ;; 从前谁造谁清、大多没清,一轮下来 /tmp 攒上万个目录直到 tmpfs 撑满,mktemp 返回
  ;; 空串、测试大面积假失败(2026-07-24 亲历)。清理集中到 harness,夹具只管登记。
  (define test-tmp-dirs '())
  (define (register-test-tmp! dir)
    (when (and (string? dir) (> (string-length dir) 0))
      (set! test-tmp-dirs (cons dir test-tmp-dirs)))
    dir)
  (define (clear-test-tmps!)
    (for-each (lambda (d) (guard (e (#t (void))) (rm-rf d))) test-tmp-dirs)
    (set! test-tmp-dirs '()))

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
  ;; 实现注:set! flag + call/cc 逃逸;flag 检查与 fail 必须在 handler 作用域**之外**,
  ;; 否则 fail 自己 raise 的 condition 会被同一个 handler 捕获 → 不抛也 pass(假绿)。
  (define (assert-raises thunk)
    (let ([raised? #f])
      (call/cc
        (lambda (k)
          (with-exception-handler
            (lambda (e) (set! raised? #t) (k #t))
            (lambda () (thunk) (k #f)))))
      (unless raised?
        (fail "assert-raises: expected exception, none raised"))))

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
                          (k #t)))))
                  ;; 无论过失,清掉这条用例造的临时目录(k 逃逸回到此处后仍会跑)。
                  (clear-test-tmps!)))
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
