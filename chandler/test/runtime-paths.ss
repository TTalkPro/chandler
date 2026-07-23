#!chezscheme
;;; chandler/test/runtime-paths.ss --- (chandler runtime-paths) 测试

(library (chandler test runtime-paths)
  (export suite)
  (import (chezscheme)
          (chandler test harness)
          (chandler test fixtures)
          (chandler runtime-paths)
          (chandler layout)
          (chandler fs))

  ;; Chez 的 putenv 不能删除变量，清理时以空值恢复未设置状态。
  (define (with-app-root root thunk)
    (let ([old (getenv "APP_ROOT")])
      (dynamic-wind
        (lambda () (putenv "APP_ROOT" root))
        thunk
        (lambda () (putenv "APP_ROOT" (or old ""))))))

  (define (with-app-name name thunk)
    (let ([old (getenv "APP_NAME")])
      (dynamic-wind
        (lambda () (putenv "APP_NAME" name))
        thunk
        (lambda () (putenv "APP_NAME" (or old ""))))))

  ;; 造一个「部署态」根:.chandler/<app>/manifest.ss + share/<app>/resources/
  (define (deploy-app! root app)
    (let ([m (join-paths root ".chandler" app "manifest.ss")])
      (ensure-parent m)
      (write-file m "(manifest (format 1))")))

  ;; 每个文件系统用例独占临时根，并在异常时也完成清理。
  (define (with-temp-app thunk)
    (let ([root (mktmp)])
      (dynamic-wind
        (lambda () (void))
        (lambda () (with-app-root root (lambda () (thunk root))))
        (lambda () (rm-rf root)))))

  (define-suite suite
    (app-root-env-set
      (with-app-root "/tmp/some-test-dir"
        (lambda ()
          (assert-string= "/tmp/some-test-dir" (app-root)))))

    (app-root-env-empty
      (with-app-root ""
        (lambda ()
          (assert-true (string? (app-root))))))

    (app-resource-path-valid
      (with-temp-app
        (lambda (root)
          (deploy-app! root "myapp")
          (let ([path (join-paths root "share" "myapp" "resources" "sub" "file.txt")])
            (ensure-parent path)
            (write-file path "test")
            (assert-string= path (app-resource-path "sub" "file.txt"))))))

    (app-resource-path-missing-raises
      (with-temp-app
        (lambda (root)
          (deploy-app! root "myapp")
          (assert-raises
            (lambda () (app-resource-path "nonexistent" "file"))))))

    (find-app-resource-path-missing
      (with-temp-app
        (lambda (root)
          (deploy-app! root "myapp")
          (assert-false (find-app-resource-path "nonexistent" "file")))))

    (app-resource-path-dotdot-rejected
      (assert-raises (lambda () (app-resource-path ".." "secret"))))

    (app-resource-path-absolute-rejected
      (assert-raises (lambda () (app-resource-path "/etc" "passwd"))))

    (app-resource-path-separator-rejected
      (assert-raises (lambda () (app-resource-path "a/b"))))

    (app-resource-path-zero-segs
      (with-temp-app
        (lambda (root)
          (deploy-app! root "myapp")
          (let ([resources (join-paths root "share" "myapp" "resources")])
            (ensure-dir resources)
            (assert-string= resources (app-resource-path))))))

    ;; ── P1:部署态资源落在 <app-root>/share/<app>/resources/ ──
    ;; 应用名由 .chandler/ 下的唯一条目认出(pack 恒只写一个),故不必加第二个 env。
    (app-resource-path-share-app-layout
      (with-temp-app
        (lambda (root)
          (deploy-app! root "myapp")
          (let ([path (join-paths root "share" "myapp" "resources" "greeting.txt")])
            (ensure-parent path)
            (write-file path "hi")
            (assert-string= "myapp" (app-name))
            (assert-string= path (app-resource-path "greeting.txt"))))))

    ;; APP_NAME 显式 > .chandler 推断(共享前缀里装了多个应用时由启动器传)
    (app-resource-path-app-name-env-wins
      (with-temp-app
        (lambda (root)
          (deploy-app! root "other")
          (with-app-name "myapp"
            (lambda ()
              (let ([path (join-paths root "share" "myapp" "resources" "greeting.txt")])
                (ensure-parent path)
                (write-file path "hi")
                (assert-string= "myapp" (app-name))
                (assert-string= path (app-resource-path "greeting.txt"))))))))

    ;; .chandler 有多个条目(共享前缀装了多个应用)→ 认不出应用名,返回 #f,不猜
    (app-name-ambiguous-when-multiple-entries
      (with-temp-app
        (lambda (root)
          (deploy-app! root "a")
          (deploy-app! root "b")
          (with-app-name ""
            (lambda () (assert-false (app-name)))))))

    ;; APP_ROOT 不是个前缀(没 .chandler/、也没 APP_NAME)→ 报「认不出是哪个 app」,
    ;; 不去猜项目根下的 resources/:一种拼法,错了就明说该怎么起进程。
    (app-resource-path-without-prefix-identity-raises
      (with-temp-app
        (lambda (root)
          (with-app-name ""
            (lambda ()
              (let ([path (join-paths root "resources" "file.txt")])
                (ensure-parent path)
                (write-file path "x")
                (assert-false (app-name))
                (assert-raises (lambda () (app-resource-path "file.txt")))
                (assert-false (find-app-resource-path "file.txt"))))))))

    ;; 认不出应用名也不能把非法 segment 降级成 #f:路径穿越照旧当场拒
    (find-app-resource-path-still-rejects-traversal
      (with-temp-app
        (lambda (root)
          (with-app-name ""
            (lambda ()
              (assert-raises (lambda () (find-app-resource-path ".." "secret"))))))))

    ;; ── M3:lib 资源定位(designs/11 §4)──
    ;; library-object-filename 对未加载库抛异常(ignore-errors 捕获后走 source fallback)
    (lib-resource-path-missing-raises
      (assert-raises (lambda () (lib-resource-path '(nonexistent-xyz) "file.dat"))))

    (find-lib-resource-path-missing-returns-false
      (assert-false (find-lib-resource-path '(nonexistent-xyz) "file.dat")))

    (lib-resource-path-dotdot-rejected
      (assert-raises (lambda () (lib-resource-path '(testlib) ".." "secret"))))

    (lib-resource-path-absolute-rejected
      (assert-raises (lambda () (lib-resource-path '(testlib) "/etc" "passwd"))))
    ))