#!chezscheme
;;; chandler/test/build.ss --- (chandler build) 排单/授权测试(mock bake)

(library (chandler test build)
  (export suite)
  (import (chezscheme)
          (chandler test harness)
          (chandler test fixtures)
          (chandler fetch)
          (chandler fs)
          (chandler install)
          (chandler build))

  (define (mock-bake) (string-append (current-directory) "/tests/mock-bake.sh"))

  ;; 用 mock bake 跑 thunk;结束后**恢复** CHANDLER_BAKE(否则污染后续 selfinstall 测试)
  (define (with-mock log thunk)
    (let ([old-bake (getenv "CHANDLER_BAKE")] [old-log (getenv "MOCK_BAKE_LOG")])
      (putenv "CHANDLER_BAKE" (mock-bake))
      (putenv "MOCK_BAKE_LOG" log)
      (guard (e [#t (restore-env old-bake old-log) (raise e)])
        (let ([r (thunk)]) (restore-env old-bake old-log) r))))

  (define (restore-env bake log)
    ;; Chez putenv 无法删除变量;还原为原值,原本无则置空串(bake-command 视空为无 → 回退 "bake")
    (putenv "CHANDLER_BAKE" (or bake ""))
    (putenv "MOCK_BAKE_LOG" (or log "")))

  (define-suite suite
    ;; 无 native 的依赖:build 直接排单,无需授权
    (build-plain-no-auth
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b")]
               [app (make-app (list (cons 'b b)))]
               [log (string-append (mktmp) "/log")])
          (install app '())
          (with-mock log
            (lambda ()
              (assert-equal 0 (build app '()))
              ;; mock 收到生成的 recipe:含 library-task(真实 bake 任务)
              (let ([l (read-file log)])
                (assert-true (substr? l "-f"))
                (assert-true (substr? l "library-task"))))))))

    ;; 编的是依赖树里的**每一个库**,不只 umbrella 闭包。
    ;; 回归钉:曾经只发 (library-task 'c-<dep> '(<dep>)),于是 umbrella 从不 import 的
    ;; 子库(chez-markding 的 extensions/ 全是选择性启用的)一个都没编 —— 装出来的
    ;; lib/<mt>/ 残缺(实测 107 源码库只出 49 个对象),而消费方的 bake 会退回从
    ;; lib/src/ 现编进应用自己的 _build/,把同一个依赖劈成两棵对象树。
    (build-enumerates-every-library-not-just-the-umbrella
      (let ([tree (mktmp)])
        (write-file (string-append tree "/b.ss")
                    "(library (b) (export b-ok) (import (chezscheme)) (define b-ok #t))")
        ;; umbrella 不 import 它 —— 只有消费方会直接 import
        (ensure-dir (string-append tree "/b"))
        (write-file (string-append tree "/b/opt.sls")
                    "(library (b opt) (export opt-ok) (import (chezscheme)) (define opt-ok #t))")
        ;; 不是库的文件(测试脚本)必须被跳过,否则 bake 会当 program 编
        (write-file (string-append tree "/b/run-tests.ss") "(display \"not a library\")(newline)")
        (let ([files (tree-library-files tree "b")])
          (assert-true  (find (lambda (f) (substr? f "b/opt.sls")) files))
          (assert-true  (find (lambda (f) (substr? f "b.ss")) files))
          (assert-false (find (lambda (f) (substr? f "run-tests.ss")) files)))))

    ;; 有 native 的依赖:无授权 → 报错(pending)
    (build-native-needs-auth
      (parameterize ([cache-root (mktmp)])
        (let* ([n (make-native-lib "n" "libn")]
               [app (make-app (list (cons 'n n)))]
               [log (string-append (mktmp) "/log")])
          (install app '())
          (with-mock log
            (lambda ()
              (assert-raises (lambda () (build app '()))))))))

    ;; --allow-build → 执行 + 写 approvals + native 先于 compile-tree
    (build-native-authorized
      (parameterize ([cache-root (mktmp)])
        (let* ([n (make-native-lib "n" "libn")]
               [app (make-app (list (cons 'n n)))]
               [log (string-append (mktmp) "/log")])
          (install app '())
          (with-mock log
            (lambda ()
              (assert-equal 0 (build app (list (cons 'allow-build #t))))
              (let ([l (read-file log)])
                (assert-true (substr? l "native-task"))
                (assert-true (substr? l "library-task")))
              ;; approvals 落盘
              (assert-true (file-exists? (string-append app "/.chandler-approvals")))
              ;; 再 build 无需 --allow-build(已授权且描述未变)
              (assert-equal 0 (build app '())))))))

    ;; 描述变更(掉包)→ 已有授权失效,重新需要 --allow-build
    (build-approval-invalidated-on-change
      (parameterize ([cache-root (mktmp)])
        (let* ([n (make-native-lib "n" "libn")]
               [app (make-app (list (cons 'n n)))]
               [log (string-append (mktmp) "/log")])
          (install app '())
          (with-mock log
            (lambda ()
              (build app (list (cons 'allow-build #t)))
              ;; 改依赖 lib/n/manifest.ss 的 native 描述 → 哈希变
              (write-file (string-append (lib-dir app 'n) "/manifest.ss")
                "(manifest (format 1) (name \"n\") (version \"0.1.0\") (srcdir \".\") (native (libn (path \"native/libn\") (build (script \"evil.sh\")))))")
              ;; 未重新授权 → 报错
              (assert-raises (lambda () (build app '()))))))))))
