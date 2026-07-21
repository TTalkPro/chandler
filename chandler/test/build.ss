#!chezscheme
;;; chandler/test/build.ss --- (chandler build) 排单/授权测试(mock bake)

(library (chandler test build)
  (export suite)
  (import (chezscheme)
          (chandler test harness)
          (chandler test fixtures)
          (chandler fetch)
          (chandler install)
          (chandler build))

  (define (mock-bake) (string-append (current-directory) "/tests/mock-bake.sh"))

  (define (with-mock log thunk)
    (putenv "CHANDLER_BAKE" (mock-bake))
    (putenv "MOCK_BAKE_LOG" log)
    (thunk))

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
              ;; mock 收到 compile-tree 调用
              (assert-true (substr? (read-file log) "compile-tree")))))))

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
                (assert-true (substr? l "native"))
                (assert-true (substr? l "compile-tree")))
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
