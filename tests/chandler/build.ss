#!chezscheme
;;; tests/chandler/build.ss --- (chandler build) 排单/授权/**进程内编译**测试
;;;
;;; 2026-07-24(P6 阶段 B6):bake 子进程没了,mock bake 与 `CHANDLER_BAKE` 随之作废。
;;; 断言从「生成的 recipe 文本里有没有 library-task」改成看**真产物**:
;;; 依赖被编进 `lib/<mt>/`、native 落在 `<lib>/native/<soname>.<ext>`。
;;; 授权那几条不变 —— 它们本来就不依赖谁来执行构建,而吸收之后反而更要紧:
;;; 依赖的构建不再隔在子进程里,而是在本进程执行。

(library (tests chandler build)
  (export suite)
  (import (chezscheme)
          (tests chandler harness)
          (tests chandler fixtures)
          (chandler fetch)
          (chandler fs)
          (chandler layout)
          (chandler util)
          (chandler install)
          (chandler build))

  ;; when-compiler 来自 (tests chandler fixtures):编译产物断言需要真编译器,
  ;; Petite 上跳过(授权逻辑照跑 —— 它在编译之前就完成了)。

    ;; C0:依赖的编译产物留在**它自己的** _vendor 树里,不再搬进汇总的 lib/
  (define (dep-obj app dep rel)
    (join-paths app "_vendor" dep "_build" (current-machine-type) rel))
  ;; rel 形如 "b.so" / "b/opt.so" / "n/native/libn.so" —— 首段即依赖名
  (define (obj app rel)
    (let ([i (char-index rel #\/)])
      (dep-obj app (if i (substring rel 0 i)
                       (let ([d (char-index rel #\.)]) (if d (substring rel 0 d) rel)))
               rel)))

  (define-suite suite
    ;; 无 native 的依赖:build 直接排单,无需授权,产物落 lib/<mt>/
    (build-plain-no-auth
      (when-compiler (lambda ()
  (parameterize ([cache-root (mktmp)])
          (let* ([b (make-lib-repo "b")]
                 [app (make-app (list (cons 'b b)))])
            (install app '())
            (assert-equal 0 (build app '()))
            (assert-true (file-exists? (obj app "b.so"))))))))

    ;; 编的是依赖树里的**每一个库**,不只 umbrella 闭包。
    ;; 回归钉:曾经只发 (library-task 'c-<dep> '(<dep>)),于是 umbrella 从不 import 的
    ;; 子库(chez-markding 的 extensions/ 全是选择性启用的)一个都没编 —— 装出来的
    ;; lib/<mt>/ 残缺(实测 107 源码库只出 49 个对象),而消费方会退回从
    ;; lib/src/ 现编进应用自己的 _build/,把同一个依赖劈成两棵对象树。
    (build-enumerates-every-library-not-just-the-umbrella
      (let ([tree (mktmp)])
        (write-file (string-append tree "/b.ss")
                    "(library (b) (export b-ok) (import (chezscheme)) (define b-ok #t))")
        ;; umbrella 不 import 它 —— 只有消费方会直接 import
        (ensure-dir (string-append tree "/b"))
        (write-file (string-append tree "/b/opt.sls")
                    "(library (b opt) (export opt-ok) (import (chezscheme)) (define opt-ok #t))")
        ;; 不是库的文件(测试脚本)必须被跳过,否则会被当 program 编
        (write-file (string-append tree "/b/run-tests.ss") "(display \"not a library\")(newline)")
        (let ([files (tree-library-files tree "b")])
          (assert-true  (find (lambda (f) (substr? f "b/opt.sls")) files))
          (assert-true  (find (lambda (f) (substr? f "b.ss")) files))
          (assert-false (find (lambda (f) (substr? f "run-tests.ss")) files)))))

    ;; 子库同样要出对象(上一条验排单,这条验真编出来了)
    (build-compiles-sublibraries
      (when-compiler (lambda ()
        (parameterize ([cache-root (mktmp)])
          (let* ([b (make-lib-repo "b")]
                 [app (make-app (list (cons 'b b)))])
            ;; 给依赖加一个 umbrella 从不 import 的子库
            (ensure-dir (string-append b "/b"))
            (write-file (string-append b "/b/opt.sls")
                        "(library (b opt) (export opt-ok) (import (chezscheme)) (define opt-ok #t))")
            (git-commit! b "add sublib")
            (install app '())
            (assert-equal 0 (build app '()))
            (assert-true (file-exists? (obj app "b.so")))
            (assert-true (file-exists? (obj app "b/opt.so"))))))))

    ;; 有 native 的依赖:无授权 → 报错(pending),且**一次构建也不能发生**
    (build-native-needs-auth
      (parameterize ([cache-root (mktmp)])
        (let* ([n (make-native-lib "n" "libn")]
               [app (make-app (list (cons 'n n)))])
          (install app '())
          (assert-raises (lambda () (build app '())))
          ;; 授权判定在排单**之前**:被拒时不该已经编出任何东西
          (assert-false (file-exists? (obj app "n.so"))))))

    ;; --allow-build → 真跑 native 后端,产物落在不变量位置,授权落盘
    (build-native-authorized
      (when-compiler (lambda ()
  (parameterize ([cache-root (mktmp)])
          (let* ([n (make-native-lib "n" "libn")]
                 [app (make-app (list (cons 'n n)))])
            (install app '())
            (assert-equal 0 (build app (list (cons 'allow-build #t))))
            ;; native 落点不变量:<lib>/native/<soname>.<ext>
            (assert-true (file-exists?
                           (obj app (string-append "n/native/libn." (so-ext)))))
            (assert-true (file-exists? (obj app "n.so")))
            ;; approvals 落盘
            (assert-true (file-exists? (string-append app "/.chandler-approvals")))
            ;; 再 build 无需 --allow-build(已授权且描述未变)
            (assert-equal 0 (build app '())))))))

    ;; 白名单粒度:--allow-build=<别的包> 不该放行本包
    (build-allow-list-is-scoped
      (when-compiler (lambda ()
  (parameterize ([cache-root (mktmp)])
          (let* ([n (make-native-lib "n" "libn")]
                 [app (make-app (list (cons 'n n)))])
            (install app '())
            (assert-raises (lambda () (build app (list (cons 'allow-build "other")))))
            (assert-equal 0 (build app (list (cons 'allow-build "n")))))))))

    ;; 描述变更(掉包)→ 已有授权失效,重新需要 --allow-build
    (build-approval-invalidated-on-change
      (when-compiler (lambda ()
  (parameterize ([cache-root (mktmp)])
          (let* ([n (make-native-lib "n" "libn")]
                 [app (make-app (list (cons 'n n)))])
            (install app '())
            (build app (list (cons 'allow-build #t)))
            ;; 改依赖 _vendor/n/chandler-manifest.ss 的 native 描述 → 哈希变
            (write-file (string-append (vendor-dir app 'n) "/chandler-manifest.ss")
              "(manifest (format 1) (name \"n\") (version \"0.1.0\") (srcdir \".\") (native (libn (path \"native/libn\") (build (script \"evil.sh\")))))")
            ;; 未重新授权 → 报错
            (assert-raises (lambda () (build app '()))))))))

    ;; ── 根项目自己的编译(B6:chandler-tasks.ss 可选)──

    ;; 没有 chandler-tasks.ss → 从 manifest 推导:(name) 给库名、(srcdir) 给搜索根
    (build-project-without-recipe
      (when-compiler (lambda ()
        (let ([app (mktmp)])
          (write-file (join-paths app "chandler-manifest.ss")
                      "(manifest (format 1) (name \"myapp\") (version \"0.1.0\") (srcdir \".\"))")
          (write-file (join-paths app "myapp.ss")
                      "(library (myapp) (export ok) (import (chezscheme)) (define ok #t))")
          (ensure-dir (join-paths app "myapp"))
          (write-file (join-paths app "myapp/sub.sls")
                      "(library (myapp sub) (export s) (import (chezscheme)) (define s 1))")
          (build-project app #f)
          (let ([bdir (join-paths app "_build" (current-machine-type))])
            (assert-true (file-exists? (join-paths bdir "myapp.so")))
            (assert-true (file-exists? (join-paths bdir "myapp/sub.so"))))))))

    ;; 有 chandler-tasks.ss → 跑它的 default-task,且**只跑它**(test 之类不该被 build 带跑)
    (build-project-with-recipe-runs-default-task-only
      (when-compiler (lambda ()
        (let ([app (mktmp)])
          (write-file (join-paths app "chandler-manifest.ss")
                      "(manifest (format 1) (name \"myapp\") (version \"0.1.0\") (srcdir \".\"))")
          (write-file (join-paths app "myapp.ss")
                      "(library (myapp) (export ok) (import (chezscheme)) (define ok #t))")
          (write-file (join-paths app "chandler-tasks.ss")
                      (string-append
                        "(define-lib-roots \".\")\n"
                        "(library-task 'build '(myapp))\n"
                        "(task 'test (lambda () (write-text \"RAN-TEST\" \"x\")))\n"
                        "(default-task 'build)\n"))
          (build-project app #f)
          (assert-true (file-exists?
                         (join-paths app "_build" (current-machine-type) "myapp.so")))
          (assert-false (file-exists? (join-paths app "RAN-TEST")))))))

    ;; app 的入口库与 manifest name 不同名时,按**入口**编,不按 name 找 umbrella。
    ;; 回归钉:skiff-demo 清单叫 "skiff-demo",入口却是 (mdserver) —— 先前
    ;; build-project 用 name 找 skiff-demo.ss,一个库都没编,build-project 静默空跑。
    (build-project-app-entry-differs-from-name
      (when-compiler (lambda ()
        (let ([app (mktmp)])
          (write-file (join-paths app "chandler-manifest.ss")
                      "(manifest (format 1) (name \"toolpkg\") (version \"0.1.0\") (srcdir \".\")\n  (app (entry (mytool)) (main go)))")
          (write-file (join-paths app "mytool.ss")
                      "(library (mytool) (export go) (import (chezscheme) (mytool core)) (define (go) core-ok))")
          (ensure-dir (join-paths app "mytool"))
          (write-file (join-paths app "mytool/core.sls")
                      "(library (mytool core) (export core-ok) (import (chezscheme)) (define core-ok 1))")
          (build-project app #f)
          (let ([bdir (join-paths app "_build" (current-machine-type))])
            (assert-true (file-exists? (join-paths bdir "mytool.so")))
            (assert-true (file-exists? (join-paths bdir "mytool/core.so"))))))))

    ;; 没有 chandler-manifest.ss 也没有 chandler-tasks.ss → 什么都不做,不报错
    (build-project-noop-without-manifest
      (let ([app (mktmp)])
        (build-project app #f)
        (assert-false (file-exists? (join-paths app "_build")))))

    ))
