#!chezscheme
;;; tests/chandler/cli.ss --- (chandler cli args) 单测 + CLI 端到端(经 main)

(library (tests chandler cli)
  (export suite)
  (import (chezscheme)
          (tests chandler harness)
          (tests chandler fixtures)
          (chandler fetch)
          (chandler fs)
          (chandler layout)
          (chandler install)
          (chandler manifest)
          (chandler lock)
          (chandler hash)
          (chandler proc)
          (chandler registry)
          (chandler version)
          (chandler cli args)
          (chandler cli commands)   ; app-launcher-sh:启动器端到端实跑
          (chandler cli main))

  ;; 渲染**本平台**的启动器并实跑它,返回 (values exit-code stdout)。
  ;;
  ;; runtime 用一个 stub 脚本(把收到的参数原样打出),而不是真的 skiff/scheme ——
  ;; 本测试要证明的是「shim 把 sidecar 读对了、runner 路径拼对了」,牵进真运行时
  ;; 只会让断言变模糊,还得赌 PATH 上有什么。
  ;;
  ;; C9:两族启动器**共用下面 5 条用例**,而不是把 Windows 侧跳过 —— 模板对拍
  ;; (launcher-parity)证明不了 `set /p ACTIVE=<file` 真能读出版本号,正如它
  ;; 也证明不了 `IFS= read -r`。差异只在这个函数里:
  ;;   • 启动器文件名带 `.cmd`,内容按 CRLF 写
  ;;   • stub 是批处理;`.cmd` 里不带 `call` 调另一个 `.cmd` 时控制权不返回,
  ;;     于是启动器进程直接以 stub 的退出码结束(happy path 是 0)—— 断言不受
  ;;     影响,而**错误分支根本不会走到 RT**,`exit /b 70` 照常生效
  (define (run-app-launcher libdir name)
    (if (windows-host?)
        (let* ([bin (mktmp)]
               [stub (join-paths bin "fakescheme.cmd")]
               [launcher (join-paths bin (string-append name ".cmd"))])
          (write-text-crlf stub "@echo off\r\necho %*\r\n")
          (write-text-crlf launcher (app-launcher-cmd name libdir))
          (launch launcher stub))
        (let* ([bin (mktmp)]
               [stub (join-paths bin "fakescheme")]
               [launcher (join-paths bin name)])
          (write-text stub "#!/bin/sh\necho \"$@\"\n")
          (make-executable! stub)
          (write-text launcher (app-launcher-sh name libdir))
          (make-executable! launcher)
          (launch launcher stub))))

  ;; 启动器打出的 runner 路径是否指向这个版本。**比较前把分隔符归一** ——
  ;; cmd 侧模板拼的是 `\`,join-paths 拼的是 `/`,不归一就等于在断言排版。
  (define (saw-runner? out libdir name version)
    (substr? (normalize-seps out)
             (normalize-seps (join-paths libdir name version ".chandler" "run.sps"))))

  (define (exec-runtime)
    (or (test-runtime)
        (error 'exec-runtime "no Scheme runtime found on PATH; exec e2e cannot run")))

  (define (launch launcher stub)
    (let ([r (run-capture launcher '()
                          (list (cons 'env (list (cons "CHANDLER_RUNTIME" "chez")
                                                 (cons "CHANDLER_SCHEME" stub)))))])
      (values (proc-result-code r) (proc-result-out r))))

  ;; 装一个 app 到 libdir 并补上 runner,返回 libdir
  (define (install-app-with-runner! libdir name version)
    (let ([reg (registered-set-active
                 (registered-add-version (make-registered (string->symbol name) 'app)
                                         (make-version-entry version "t" '(path "/x") 'test))
                 version)])
      (write-registered! libdir name reg)
      (write-text (join-paths libdir name version ".chandler" "run.sps") "#!chezscheme\n")
      libdir))

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

    ;; --lib / --app 互斥:配置期就报(main 有顶层 error handler catch 后返回 65 不传播,
    ;; 故检查 rc 而非 assert-raises)
    (init-lib-and-app-mutually-exclusive
      (let ([app (mktmp)])
        (assert-equal 65 (main (list "-C" app "init" "--lib" "--app" "--name=foo")))))

    ;; init 也生成 chandler-tasks.ss(程序,与 manifest 数据配对),编译入口按 name/entry。
    ;; v3:模板不再默认带 'test 任务 —— 跑测试走顶层 `chandler test`(挂全运行时环境)。
    (init-writes-tasks-file
      (let ([app (mktmp)])
        (main (list "-C" app "init" "--name=foo"))
        (let ([tp (string-append app "/chandler-tasks.ss")])
          (assert-true (file-exists? tp))
            (let ([txt (read-file tp)])
              (assert-true (substr? txt "(library-task 'build '(foo))"))
              (assert-true (substr? txt "(default-task 'build)"))
              ;; v3:不再默认生成 'test 任务(用户走 `chandler test`)
              (assert-false (substr? txt "(task 'test)"))
              ;; 模板注释里指向 `chandler test`(可发现性)
              (assert-true (substr? txt "chandler test"))))))

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
          ;; add + deps → lock 有依赖 → 项目模式
          (main (list "-C" app "add" "greet" greet "--branch" "main"))
          (main (list "-C" app "deps"))
          (assert-true (project-mode? app))
          ;; C0 项目 libdirs:**逐依赖**一对 (src . obj) 在前 + 项目自身 + 全局兜底在末尾
          (let ([dirs (resolved-libdirs app)])
            (assert-true (>= (length dirs) 2))))))

    ;; 错误输出不许把格式指令原样打给用户:Chez 的 I/O 条件把 "~a" 写在 message 里、
    ;; 值放 irritants,report-error 必须 format 出来(回归钉:曾打出
    ;; `failed for ~a: ~(~a~) "/path" "No such file or directory"`)。
    ;; 触发方式:目标父路径上是**普通文件**,mkdir 无法在其下建目录,写必然失败
    ;; (原先用「不存在目录」触发,但 write-canonical-file 现为原子写并 ensure-parent,
    ;; 不存在目录会被自动建好——那已是成功路径)。
    (error-report-interpolates-condition-irritants
      (let* ([root (mktmp)]
             [blocker (join-paths root "blocker")]
             [missing (join-paths blocker "no-such-dir")]
             [op (open-output-string)])
        (call-with-output-file blocker (lambda (p) (display "x" p)) 'truncate)
        (let ([rc (parameterize ([current-error-port op])
                    (main (list "-C" missing "init" "--name=demo")))])
          ;; get-output-string 会**清空**该端口,故只取一次
          (let ([err (get-output-string op)])
            (assert-equal 65 rc)
            (assert-false (substr? err "~a"))
            (assert-true (substr? err missing))))))

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

    ;; ── verify:校验 _vendor/ 与 lock 的 (files ...) 一致(CI;只读)──
    ;; files 条目 rel 相对项目根(如 "_vendor/greet/greet.ss")
    (verify-clean
      (let* ([app (mktmp)]
             [f (string-append app "/_vendor/greet/greet.ss")])
        (ensure-dir (string-append app "/_vendor/greet"))
        (write-file f "hello\n")
        (write-lock (string-append app "/chandler-manifest.lock")
                    (make-lock 1 "sha" "0.1.0" '()
                               (list (cons "_vendor/greet/greet.ss" (sha256-file f)))))
        (assert-equal 0 (main (list "-C" app "verify")))))

    (verify-dirty-changed
      (let* ([app (mktmp)]
             [f (string-append app "/_vendor/greet/greet.ss")])
        (ensure-dir (string-append app "/_vendor/greet"))
        (write-file f "hello\n")
        (write-lock (string-append app "/chandler-manifest.lock")
                    (make-lock 1 "sha" "0.1.0" '()
                               (list (cons "_vendor/greet/greet.ss" (sha256-file f)))))
        ;; 篡改已声明文件:sha256 不再匹配 → 65
        (write-file f "tampered\n")
        (assert-equal 65 (main (list "-C" app "verify")))))

    (verify-dirty-missing-and-extra
      (let* ([app (mktmp)]
             [f (string-append app "/_vendor/greet/greet.ss")])
        (ensure-dir (string-append app "/_vendor/greet"))
        (write-lock (string-append app "/chandler-manifest.lock")
                    (make-lock 1 "sha" "0.1.0" '()
                               (list (cons "_vendor/greet/greet.ss" "deadbeef"))))
        ;; MISSING:lock 声明了但盘上没有 → 65
        (assert-equal 65 (main (list "-C" app "verify")))
        ;; EXTRA:盘上有(hash 匹配的声明文件之外)lock 未声明的 → 65
        (write-file f "hello\n")
        (write-lock (string-append app "/chandler-manifest.lock")
                    (make-lock 1 "sha" "0.1.0" '()
                               (list (cons "_vendor/greet/greet.ss" (sha256-file f)))))
        (write-file (string-append app "/_vendor/greet/stray.txt") "stray\n")
        (assert-equal 65 (main (list "-C" app "verify")))))

    (verify-no-lock
      (let ([app (mktmp)])
        (assert-equal 65 (main (list "-C" app "verify")))))

    ;; ── verify 的 git 态检查(接自 (chandler install) 的 verify)──

    ;; D15 生产侧:deps 铺完依赖后把 _vendor/ 的文件清单 + sha256 写回 lock。
    ;; 路径相对项目根;`.git/` 与 `_build/` 不入清单。
    (deps-records-vendor-file-digests
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b" '())]
               [app (make-app (list (cons 'b b)))])
          (install app '())
          (let ([fs (lock-files (read-lock (project-lock-path app)))])
            (assert-true (pair? fs))
            ;; 相对项目根 + 源文件在内
            (assert-true (find (lambda (f) (string=? (car f) "_vendor/b/b.ss")) fs))
            ;; .git/ 一条都不该有(git 自己会改它,且 dirty? 已在管工作区)
            (assert-false (find (lambda (f) (substr? (car f) "/.git/")) fs))
            ;; 升序,canonical 写要求确定性
            (assert-equal (list-sort string<? (map car fs)) (map car fs))
            ;; 记的是真 sha256
            (assert-string= (sha256-file (string-append app "/_vendor/b/b.ss"))
                            (cdr (find (lambda (f) (string=? (car f) "_vendor/b/b.ss")) fs)))))))

    ;; deps → verify 闭环:刚铺完就该干净
    (verify-passes-right-after-deps
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b" '())]
               [app (make-app (list (cons 'b b)))])
          (install app '())
          (assert-equal 0 (main (list "-C" app "verify"))))))

    ;; 篡改 vendored 源文件 → CHANGED → 65
    (verify-detects-tampered-vendor-file
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b" '())]
               [app (make-app (list (cons 'b b)))])
          (install app '())
          (write-file (string-append app "/_vendor/b/b.ss") ";; tampered\n")
          (assert-equal 65 (main (list "-C" app "verify"))))))

    ;; 多出一个未声明的源文件 → EXTRA → 65
    (verify-detects-undeclared-vendor-file
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b" '())]
               [app (make-app (list (cons 'b b)))])
          (install app '())
          (write-file (string-append app "/_vendor/b/stray.ss") ";; stray\n")
          (assert-equal 65 (main (list "-C" app "verify"))))))

    ;; **`chandler build` 之后 verify 仍须通过**:产物落在 _vendor/<dep>/_build/,
    ;; 生产侧不记它、EXTRA 侧不数它、git 的 dirty? 也不该把它算作本地改动。
    ;; 回归:三者任一漏掉,build 之后 verify 就恒 65。
    (verify-ignores-build-artifacts
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b" '())]
               [app (make-app (list (cons 'b b)))])
          (install app '())
          (write-text (string-append app "/_vendor/b/_build/" (current-machine-type) "/b.so")
                      "FAKEOBJ")
          (assert-equal 0 (main (list "-C" app "verify"))))))

    ;; lock 没有 (files …)(v2 老 lock / deps 尚未重跑)→ 只报 git 态,不给一屏假 EXTRA
    (verify-tolerates-lock-without-files
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b" '())]
               [app (make-app (list (cons 'b b)))])
          (install app '())
          ;; 把 files 抹掉,模拟老 lock
          (let ([lk (read-lock (project-lock-path app))])
            (write-lock (project-lock-path app) (with-files lk '())))
          (assert-equal 0 (main (list "-C" app "verify"))))))

    ;; git 依赖被切到别的 rev → rev mismatch → 65
    (verify-detects-rev-mismatch
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b" '())]
               [app (make-app (list (cons 'b b)))])
          (install app '())
          (let ([lk (read-lock (project-lock-path app))])
            ;; 把 lock 里的 rev 改成另一个值,checkout 就对不上了
            (write-lock (project-lock-path app)
              (make-lock 1 (lock-manifest-sha256 lk) (lock-chandler lk)
                (map (lambda (d)
                       (make-locked-dep (locked-dep-name d) (locked-dep-source-kind d)
                                        (locked-dep-source-loc d) (locked-dep-pin-kind d)
                                        (locked-dep-pin-val d)
                                        "0000000000000000000000000000000000000000"
                                        (locked-dep-deps d) (locked-dep-natives d)
                                        (locked-dep-scope d) #f))
                     (lock-deps lk)))))
          (assert-equal 65 (main (list "-C" app "verify"))))))

    ;; 依赖工作区有未提交改动 → dirty → 65
    (verify-detects-dirty-checkout
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b" '())]
               [app (make-app (list (cons 'b b)))])
          (install app '())
          (write-file (string-append app "/_vendor/b/b.ss") ";; locally edited\n")
          (assert-equal 65 (main (list "-C" app "verify"))))))

    ;; ── exec:设 CHEZSCHEMELIBDIRS(+ .env)后透传命令;退出码 = 子进程退出码 ──
    ;; 被透传的命令用**当前 Scheme 运行时 + 一个临时脚本**,不用 `echo` / `sh -c`
    ;; (C9:两者在 Windows 上都不存在;`echo` 还是 cmd 内建,连引号都不脱)。
    (exec-passthrough
      (let ([app (mktmp)]
            [s (path-join* (mktmp) "hello.ss")])
        (write-text s "(display \"hello\")(newline)\n")
        (assert-equal 0 (main (list "-C" app "exec" "--" (exec-runtime) "-q" "--script" s)))))

    (exec-propagates-exit-code
      (let ([app (mktmp)]
            [s (path-join* (mktmp) "bad.ss")])
        (write-text s "(exit 3)\n")
        (assert-equal 3 (main (list "-C" app "exec" "--" (exec-runtime) "-q" "--script" s)))))

    (exec-no-command-is-usage-error
      (let ([app (mktmp)])
        (assert-equal 65 (main (list "-C" app "exec" "--")))))

    ;; ── tree:顶层别名 = deps --tree ──
    (tree-top-level
      (let ([app (mktmp)])
        (write-lock (string-append app "/chandler-manifest.lock")
                    (make-lock 1 "sha" "0.1.0"
                               (list (make-locked-dep 'greet 'git "https://x/greet"
                                                      'tag "v1.0.0" "0123456789abcdef"
                                                      '() '() 'runtime #f))))
        (let ([op (open-output-string)])
          (let ([rc (parameterize ([current-output-port op])
                      (main (list "-C" app "tree")))])
            (assert-equal 0 rc)
            (assert-true (substr? (get-output-string op) "greet"))))))

    ;; ── switch --latest:semver 数值序(9.9.0 < 10.0.0,不是字符串序)──
    (switch-latest-semver-order
      (let* ([libdir (mktmp)]
             [reg (registered-add-version
                    (registered-add-version (make-registered 'myapp 'app)
                                            (make-version-entry "9.9.0" "t" '(git "x") 'test))
                    (make-version-entry "10.0.0" "t" '(git "x") 'test))])
        (write-registered! libdir 'myapp reg)
        ;; switch 现在验证 vroot + runner(D19):盘上补齐两版本的落位
        (for-each
          (lambda (v)
            (write-text (join-paths libdir "myapp" v ".chandler" "run.sps")
                        "#!chezscheme\n"))
          '("9.9.0" "10.0.0"))
        (assert-equal 0 (main (list "switch" "myapp" "--latest"
                                    (string-append "--prefix=" libdir))))
        (assert-string= "10.0.0" (registered-active (read-registered libdir 'myapp)))))

    ;; ── -T:列出的命令必须真实存在(不含 update;含 verify/exec/tree/test)──
    (list-tasks-honest
      (let ([op (open-output-string)])
        (let ([rc (parameterize ([current-output-port op])
                    (main '("-T")))])
          (let ([out (get-output-string op)])
            (assert-equal 0 rc)
            (assert-false (substr? out " update"))
            (assert-true (substr? out " verify"))
            (assert-true (substr? out " exec"))
            (assert-true (substr? out " tree"))
            (assert-true (substr? out " test"))))))    ; v3:顶层 chandler test 命令

    ;; ══════════════════════════════════════════════════════════════
    ;; 启动器 shim 端到端(D35 active sidecar)
    ;;
    ;; 光比模板字符串证明不了 `IFS= read -r ACTIVE < file` 真能读出版本号 ——
    ;; 结尾换行、空文件、缺文件三种情形都得让 /bin/sh 亲自跑一遍。
    ;; ══════════════════════════════════════════════════════════════

    (launcher-resolves-active-from-sidecar
      (let ([libdir (mktmp)])
        (install-app-with-runner! libdir "myapp" "1.0.0")
        (let-values ([(rc out) (run-app-launcher libdir "myapp")])
          (assert-equal 0 rc)
          ;; stub 打出 shim 传给 runtime 的参数 —— runner 路径必须带对版本
          (assert-true (saw-runner? out libdir "myapp" "1.0.0"))
          (assert-true (substr? out "--program")))))

    ;; switch 后**不重写 launcher**(D17 稳定 shim),但下一次启动就该换版本
    (launcher-follows-switch-without-rewrite
      (let ([libdir (mktmp)])
        (install-app-with-runner! libdir "myapp" "1.0.0")
        (let ([reg (registered-add-version (read-registered libdir "myapp")
                                           (make-version-entry "2.0.0" "t" '(path "/x") 'test))])
          (write-registered! libdir "myapp" reg))
        (write-text (join-paths libdir "myapp" "2.0.0" ".chandler" "run.sps") "#!chezscheme\n")
        (switch-active libdir "myapp" "2.0.0")
        (let-values ([(rc out) (run-app-launcher libdir "myapp")])
          (assert-equal 0 rc)
          (assert-true (saw-runner? out libdir "myapp" "2.0.0"))
          (assert-false (saw-runner? out libdir "myapp" "1.0.0")))))

    ;; sidecar 缺失 → 70(而不是拿到空版本号去拼一个不存在的 runner 路径)
    (launcher-without-sidecar-exits-70
      (let ([libdir (mktmp)])
        (install-app-with-runner! libdir "myapp" "1.0.0")
        (delete-file (active-file libdir "myapp"))
        (let-values ([(rc out) (run-app-launcher libdir "myapp")])
          (assert-equal 70 rc))))

    ;; sidecar 存在但空 → 同样 70(`read` 读空行成功但 ACTIVE 是空串)
    (launcher-with-blank-sidecar-exits-70
      (let ([libdir (mktmp)])
        (install-app-with-runner! libdir "myapp" "1.0.0")
        (write-text (active-file libdir "myapp") "\n")
        (let-values ([(rc out) (run-app-launcher libdir "myapp")])
          (assert-equal 70 rc))))

    ;; 无结尾换行:`read` 返回非零,但 ACTIVE 已被赋值 —— shim 不该因此误判成
    ;; 「没有 active」。(chandler 自己写的 sidecar 恒带换行;手工编辑的未必。)
    (launcher-tolerates-sidecar-without-trailing-newline
      (let ([libdir (mktmp)])
        (install-app-with-runner! libdir "myapp" "1.0.0")
        (write-text (active-file libdir "myapp") "1.0.0")
        (let-values ([(rc out) (run-app-launcher libdir "myapp")])
          (assert-equal 0 rc)
          (assert-true (saw-runner? out libdir "myapp" "1.0.0")))))

    ;; ── uninstall 清掉三种形态的 launcher(含 D34 之前的 .ps1)──
    ;; 旧安装留下的 `.ps1` 若不带走,PATH 上就躺着一个指向已删包的僵尸启动器 ——
    ;; 而且它比 sh 版更隐蔽:POSIX 机器上没人会去看有没有 .ps1。
    (uninstall-removes-all-launcher-forms
      (let* ([prefix (mktmp)]
             [bindir (join-paths prefix "bin")]
             [reg (registered-set-active
                    (registered-add-version (make-registered 'myapp 'app)
                                            (make-version-entry "1.0.0" "t" '(path "/x") 'test))
                    "1.0.0")])
        (write-registered! prefix 'myapp reg)
        (write-text (join-paths prefix "myapp" "1.0.0" ".chandler" "run.sps") "#!chezscheme\n")
        ;; 三种形态都摆上:POSIX、当前 Windows(.cmd)、旧 Windows(.ps1)
        (for-each (lambda (f) (write-text (join-paths bindir f) "stale"))
                  '("myapp" "myapp.cmd" "myapp.ps1"))
        (assert-equal 0 (main (list "uninstall" "--name=myapp"
                                    (string-append "--prefix=" prefix))))
        (for-each (lambda (f)
                    (assert-false (file-exists? (join-paths bindir f))))
                  '("myapp" "myapp.cmd" "myapp.ps1"))))

    ;; ── usage 含 test 行(可发现性)──
    (usage-lists-test-command
      (let ([op (open-output-string)])
        (parameterize ([current-output-port op]) (main '("--help")))
        (let ([out (get-output-string op)])
          (assert-true (substr? out "test [args...]")))))

    ;; ── chandler test ──
    ;; 无 tests/run-tests.sps → 65(配置错误,经 main 顶层 handler 收成)
    (test-missing-runner-is-config-error
      (let ([app (mktmp)])
        (assert-equal 65 (main (list "-C" app "test")))))

    ;; 有 tests/run-tests.sps → 经 --program 跑,退出码透传
    ;; runner 写一段最小 sps:exit N,验证 cmd-test 把 N 透传回来。
    (test-runs-runner-and-propagates-exit-code
      (let ([app (mktmp)])
        (ensure-dir (string-append app "/tests"))
        (write-file (string-append app "/tests/run-tests.sps")
          (string-append
            "#!chezscheme\n"
            "(import (chezscheme))\n"
            "(exit 0)\n"))
        (assert-equal 0 (main (list "-C" app "test")))))

    ;; 透传非零退出码(子进程失败 = cmd-test 失败)
    (test-runner-nonzero-exit-propagates
      (let ([app (mktmp)])
        (ensure-dir (string-append app "/tests"))
        (write-file (string-append app "/tests/run-tests.sps")
          (string-append
            "#!chezscheme\n"
            "(import (chezscheme))\n"
            "(exit 7)\n"))
        (assert-equal 7 (main (list "-C" app "test")))))

    ;; .env.tests 覆盖 .env:cmd-test 经 collect-dotenv 读两份,后者覆盖前者。
    ;; runner 把 MODE 写到文件(子进程 stdout 走 OS FD 1,chez current-output-port
    ;; 截不到;用文件这个最朴素的 IPC)。
    (test-env-tests-overrides-env
      (let* ([app (mktmp)]
             [outf (string-append app "/mode-result.txt")]
             [_ (ensure-dir (string-append app "/tests"))]
             [_ (write-file (string-append app "/.env") "MODE=base\n")]
             [_ (write-file (string-append app "/.env.tests") "MODE=override\n")]
             [_ (write-file (string-append app "/tests/run-tests.sps")
                  (string-append
                    "#!chezscheme\n"
                    "(import (chezscheme))\n"
                    "(call-with-output-file \"" outf "\"\n"
                    "  (lambda (p) (display (or (getenv \"MODE\") \"\") p)))\n"
                    "(exit 0)\n"))]
             [rc (main (list "-C" app "test"))])
        (assert-equal 0 rc)
        (assert-string= "override" (read-file outf))))

    ;; ── semver>?:--latest 排序谓词(数值比核心;release 先于 prerelease;不可解析退字符串序)──
    (semver-numeric-compare
      (assert-true (semver>? "10.0.0" "9.9.0"))
      (assert-false (semver>? "9.9.0" "10.0.0")))

    (semver-prerelease-ranks-after-release
      (assert-true (semver>? "1.0.0" "1.0.0-alpha"))
      (assert-false (semver>? "1.0.0-alpha" "1.0.0")))

    (semver-unparseable-falls-back-to-string
      (assert-true (semver>? "beta" "alpha"))
      (assert-false (semver>? "alpha" "beta")))
    ))
