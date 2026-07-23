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
          (let ([path (join-paths root "resources" "sub" "file.txt")])
            (ensure-parent path)
            (write-file path "test")
            (assert-string= path (app-resource-path "sub" "file.txt"))))))

    (app-resource-path-missing-raises
      (with-temp-app
        (lambda (root)
          (assert-raises
            (lambda () (app-resource-path "nonexistent" "file"))))))

    (find-app-resource-path-missing
      (with-temp-app
        (lambda (root)
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
          (let ([resources (join-paths root "resources")])
            (ensure-dir resources)
            (assert-string= resources (app-resource-path))))))

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