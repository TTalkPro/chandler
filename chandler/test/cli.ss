#!chezscheme
;;; chandler/test/cli.ss --- (chandler cli args) 单测 + CLI 端到端(经 main)

(library (chandler test cli)
  (export suite)
  (import (chezscheme)
          (chandler test harness)
          (chandler test fixtures)
          (chandler fetch)
          (chandler fs)
          (chandler layout)
          (chandler install)
          (chandler manifest)
          (chandler cli args)
          (chandler cli main))

  (define-suite suite
    ;; ── args ──
    (parse-subcommand
      (let-values ([(sub pos flags rest) (parse-args '("install" "--production"))])
        (assert-string= "install" sub)
        (assert-true (flag? flags 'production))
        (assert-false rest)))

    (parse-long-value-space
      (let-values ([(sub pos flags rest) (parse-args '("add" "greet" "url" "--branch" "main"))])
        (assert-string= "add" sub)
        (assert-equal '("greet" "url") pos)
        (assert-string= "main" (flag flags 'branch))))

    (parse-long-value-eq
      (let-values ([(sub pos flags rest) (parse-args '("add" "x" "u" "--tag=v1.2.0"))])
        (assert-string= "v1.2.0" (flag flags 'tag))))

    (parse-short-C
      (let-values ([(sub pos flags rest) (parse-args '("-C" "/proj" "install"))])
        (assert-string= "/proj" (flag flags 'C))
        (assert-string= "install" sub)))

    (parse-double-dash-rest
      (let-values ([(sub pos flags rest) (parse-args '("exec" "--" "scheme" "-q"))])
        (assert-string= "exec" sub)
        (assert-equal '("scheme" "-q") rest)))

    (parse-boolean-long
      (let-values ([(sub pos flags rest) (parse-args '("install" "--offline" "--force"))])
        (assert-true (flag? flags 'offline))
        (assert-true (flag? flags 'force))))

    ;; ── main dispatch ──
    (main-version
      (assert-equal 0 (main '("--version"))))

    (main-unknown-command
      (assert-equal 64 (main '("bogus"))))

    (main-help-no-args
      (assert-equal 0 (main '())))

    ;; ── init:lib / app / 默认 ──
    ;; 默认(无 flag)= lib 形态 manifest,无 (app ...)
    (init-default-is-lib
      (let ([app (mktmp)])
        (assert-equal 0 (main (list "-C" app "init" "--name=foo")))
        (let ([mf (read-manifest (string-append app "/chandler-manifest.ss"))])
          (assert-false (manifest-app mf))           ; 默认无 (app ...)
          ;; N4:init 模板写 chandler **运行时门**(版本区间),不是依赖 ——
          ;; 它没有来源可 fetch,实体取自全局前缀(designs/12 §5)
          (assert-true (string? (manifest-chandler mf)))
          (assert-false (exists (lambda (d) (eq? (dep-name d) 'chandler))
                                (manifest-deps mf))))))

    ;; --app:写 (app (entry (name)) (main main)),entry 默认取 name
    (init-app-writes-app-declaration
      (let ([app (mktmp)])
        (assert-equal 0 (main (list "-C" app "init" "--app" "--name=foo")))
        (let ([mf (read-manifest (string-append app "/chandler-manifest.ss"))])
          (assert-true (manifest-app mf))
          (assert-equal '(foo) (app-entry (manifest-app mf)))
          (assert-equal 'main (app-main (manifest-app mf))))))

    ;; --app + --entry + --main:显式覆盖
    (init-app-custom-entry-and-main
      (let ([app (mktmp)])
        (assert-equal 0 (main (list "-C" app "init" "--app" "--name=foo"
                                    "--entry=(bar baz)" "--main=start")))
        (let ([mf (read-manifest (string-append app "/chandler-manifest.ss"))])
          (assert-equal '(bar baz) (app-entry (manifest-app mf)))
          (assert-equal 'start (app-main (manifest-app mf))))))

    ;; --lib / --app 互斥:配置期就报
    (init-lib-and-app-mutually-exclusive
      (let ([app (mktmp)])
        (assert-raises
          (lambda () (main (list "-C" app "init" "--lib" "--app" "--name=foo"))))))

    ;; init 也生成 chandler-tasks.ss(程序,与 manifest 数据配对),编译入口按 name/entry。
    (init-writes-tasks-file
      (let ([app (mktmp)])
        (main (list "-C" app "init" "--name=foo"))
        (let ([tp (string-append app "/chandler-tasks.ss")])
          (assert-true (file-exists? tp))
          (let ([txt (read-file tp)])
            (assert-true (substr? txt "(library-task 'build '(foo))"))
            (assert-true (substr? txt "(default-task 'build)"))
            (assert-true (substr? txt "(task 'test"))))))

    ;; app 的 --entry 决定编译入口(可与 name 不同名)
    (init-tasks-uses-app-entry
      (let ([app (mktmp)])
        (main (list "-C" app "init" "--app" "--name=coolapp" "--entry=(coolapp core)"))
        (assert-true (substr? (read-file (string-append app "/chandler-tasks.ss"))
                              "(library-task 'build '(coolapp core))"))))

    ;; 已有 chandler-tasks.ss 不被覆盖(手写任务不能被 init 抹掉)
    (init-does-not-clobber-existing-tasks
      (let ([app (mktmp)])
        (write-file (string-append app "/chandler-tasks.ss") ";; MY HAND-WRITTEN TASKS\n")
        (main (list "-C" app "init" "--name=foo"))
        (assert-true (substr? (read-file (string-append app "/chandler-tasks.ss"))
                              "MY HAND-WRITTEN TASKS"))))

    ;; ── 端到端:init→add→deps→list 全经 main ──
    (main-full-workflow
      (parameterize ([cache-root (mktmp)])
        (let* ([greet (make-lib-repo "greet")]
               [app (mktmp)])
          (assert-equal 0 (main (list "-C" app "init" "--name=app")))
          ;; 测试环境无法 git clone chandler → 覆写为无 chandler dep 的纯净 manifest
          (let ([mp (string-append app "/chandler-manifest.ss")])
            (delete-file mp)
            (call-with-output-file mp
              (lambda (p) (display "(manifest (format 1) (name \"app\") (version \"0.1.0\") (chez \">=10.0\") (srcdir \".\") (deps))" p))))
          (assert-equal 0 (main (list "-C" app "add" "greet" greet "--branch" "main")))
          (assert-equal 0 (main (list "-C" app "deps")))
          (assert-equal 0 (main (list "-C" app "deps" "--list")))
          ;; C0:git 依赖整仓 checkout 到 _vendor/,**只此一份** —— 不再拷进任何前缀
          (assert-true (file-exists? (string-append app "/_vendor/greet/greet.ss")))
          (assert-false (file-directory? (string-append app "/lib")))
          (assert-false (file-exists? (string-append app "/chandler-setup.ss"))))))

    ;; ── 库搜索模式判定(run/exec/repl 统一):无 lock/依赖 → 全局;有 → 项目(最高优先)──
    (libdir-mode-detection
      (parameterize ([cache-root (mktmp)])
        (let* ([greet (make-lib-repo "greet")]
               [app (mktmp)])
          ;; 仅 init(有 manifest,无 lock)→ 非项目 → 全局模式
          (main (list "-C" app "init" "--name=app"))
          ;; 测试环境无法 git clone chandler → 覆写为无 chandler dep 的纯净 manifest
          (let ([mp (string-append app "/chandler-manifest.ss")])
            (delete-file mp)
            (call-with-output-file mp
              (lambda (p) (display "(manifest (format 1) (name \"app\") (version \"0.1.0\") (chez \">=10.0\") (srcdir \".\") (deps))" p))))
          (assert-false (project-mode? app))
          (assert-equal (list (global-libdir)) (resolved-libdirs app))
          ;; add + deps → lock 有依赖 → 项目模式
          (main (list "-C" app "add" "greet" greet "--branch" "main"))
          (main (list "-C" app "deps"))
          (assert-true (project-mode? app))
          ;; C0 项目 libdirs:**逐依赖**一对 (src . obj) 在前 + 项目自身 + 全局兜底在末尾
          (let ([dirs (resolved-libdirs app)])
            (assert-true (>= (length dirs) 3))
            (let ([first (car dirs)])
              (assert-true (pair? first))
              ;; 第一条是依赖 greet 自己的树:源在 _vendor/greet,对象在它的 _build/<mt>
              (assert-true (substr? (car first) "/_vendor/greet"))
              (assert-true (substr? (cdr first) (string-append "_build/" (current-machine-type)))))
            (assert-equal (global-libdir) (list-ref dirs (- (length dirs) 1)))))))  ; 全局兜底在末尾

    ;; 错误输出不许把格式指令原样打给用户:Chez 的 I/O 条件把 "~a" 写在 message 里、
    ;; 值放 irritants,report-error 必须 format 出来(回归钉:曾打出
    ;; `failed for ~a: ~(~a~) "/path" "No such file or directory"`)。
    (error-report-interpolates-condition-irritants
      (let* ([missing (join-paths (mktmp) "no-such-dir")]
             [op (open-output-string)]
             [rc (parameterize ([current-error-port op])
                   (main (list "-C" missing "init" "--name=demo")))])
        ;; get-output-string 会**清空**该端口,故只取一次
        (let ([err (get-output-string op)])
          (assert-equal 65 rc)
          (assert-false (substr? err "~a"))
          (assert-true (substr? err missing)))))

    ;; ── N5: chandler dep warning / --strict(designs/12 §5)──
    (install-strict-rejects-without-chandler-dep
      (let ([app (mktmp)])
        (let ([mp (string-append app "/chandler-manifest.ss")])
          (when (file-exists? mp) (delete-file mp))
          (call-with-output-file mp
            (lambda (p) (display "(manifest (format 1) (name \"test\") (version \"0.1.0\") (chez \">=10.0\") (srcdir \".\") (deps))" p))))
        (assert-equal 65 (main (list "-C" app "deps" "--strict")))))

    (install-non-strict-warns-but-not-rejected
      (let ([app (mktmp)])
        (let ([mp (string-append app "/chandler-manifest.ss")])
          (when (file-exists? mp) (delete-file mp))
          (call-with-output-file mp
            (lambda (p) (display "(manifest (format 1) (name \"test\") (version \"0.1.0\") (chez \">=10.0\") (srcdir \".\") (deps))" p))))
        (assert-true (not (= 65 (main (list "-C" app "deps")))))))

    (install-self-bootstrap-skips-check
      (let ([app (mktmp)])
        (let ([mp (string-append app "/chandler-manifest.ss")])
          (when (file-exists? mp) (delete-file mp))
          (call-with-output-file mp
            (lambda (p) (display "(manifest (format 1) (name \"chandler\") (version \"0.1.0\") (chez \">=10.0\") (srcdir \".\") (deps))" p))))
        (assert-true (not (= 65 (main (list "-C" app "deps" "--strict")))))))
    ))
