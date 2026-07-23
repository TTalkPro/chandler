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
        (let ([mf (read-manifest (string-append app "/manifest.ss"))])
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
        (let ([mf (read-manifest (string-append app "/manifest.ss"))])
          (assert-true (manifest-app mf))
          (assert-equal '(foo) (app-entry (manifest-app mf)))
          (assert-equal 'main (app-main (manifest-app mf))))))

    ;; --app + --entry + --main:显式覆盖
    (init-app-custom-entry-and-main
      (let ([app (mktmp)])
        (assert-equal 0 (main (list "-C" app "init" "--app" "--name=foo"
                                    "--entry=(bar baz)" "--main=start")))
        (let ([mf (read-manifest (string-append app "/manifest.ss"))])
          (assert-equal '(bar baz) (app-entry (manifest-app mf)))
          (assert-equal 'start (app-main (manifest-app mf))))))

    ;; --lib / --app 互斥:配置期就报
    (init-lib-and-app-mutually-exclusive
      (let ([app (mktmp)])
        (assert-raises
          (lambda () (main (list "-C" app "init" "--lib" "--app" "--name=foo"))))))

    ;; ── 端到端:init→add→deps→list 全经 main ──
    (main-full-workflow
      (parameterize ([cache-root (mktmp)])
        (let* ([greet (make-lib-repo "greet")]
               [app (mktmp)])
          (assert-equal 0 (main (list "-C" app "init" "--name=app")))
          ;; 测试环境无法 git clone chandler → 覆写为无 chandler dep 的纯净 manifest
          (let ([mp (string-append app "/manifest.ss")])
            (delete-file mp)
            (call-with-output-file mp
              (lambda (p) (display "(manifest (format 1) (name \"app\") (version \"0.1.0\") (chez \">=10.0\") (srcdir \".\") (deps))" p))))
          (assert-equal 0 (main (list "-C" app "add" "greet" greet "--branch" "main")))
          (assert-equal 0 (main (list "-C" app "deps")))
          (assert-equal 0 (main (list "-C" app "deps" "--list")))
          ;; 新模型:git 依赖 checkout 到 vendor/,chandler 直接装到 lib/src,生成 setup
          (assert-true (file-exists? (string-append app "/vendor/greet/greet.ss")))     ; checkout
          (assert-true (file-exists? (string-append app "/lib/src/greet.ss")))          ; chandler 装的源(lib/src)
          ;; lib/ 是完整前缀:清单快照在 .chandler/<name>/;不再生成 chandler-setup.ss
          (assert-true (file-exists? (string-append app "/lib/.chandler/app/manifest.ss")))
          (assert-false (file-exists? (string-append app "/chandler-setup.ss"))))))

    ;; ── 库搜索模式判定(run/exec/repl 统一):无 lock/依赖 → 全局;有 → 项目(最高优先)──
    (libdir-mode-detection
      (parameterize ([cache-root (mktmp)])
        (let* ([greet (make-lib-repo "greet")]
               [app (mktmp)])
          ;; 仅 init(有 manifest,无 lock)→ 非项目 → 全局模式
          (main (list "-C" app "init" "--name=app"))
          ;; 测试环境无法 git clone chandler → 覆写为无 chandler dep 的纯净 manifest
          (let ([mp (string-append app "/manifest.ss")])
            (delete-file mp)
            (call-with-output-file mp
              (lambda (p) (display "(manifest (format 1) (name \"app\") (version \"0.1.0\") (chez \">=10.0\") (srcdir \".\") (deps))" p))))
          (assert-false (project-mode? app))
          (assert-equal (list (global-libdir)) (resolved-libdirs app))
          ;; add + deps → lock 有依赖 → 项目模式
          (main (list "-C" app "add" "greet" greet "--branch" "main"))
          (main (list "-C" app "deps"))
          (assert-true (project-mode? app))
          ;; 项目 libdirs:lib/ 一对 (src . obj) 在前 + 项目根 + 全局兜底(一对)在末尾
          (let ([dirs (resolved-libdirs app)])
            (assert-true (>= (length dirs) 2))
            (assert-equal (project-lib-pair app) (car dirs))                     ; lib/ 一对在前
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
        (let ([mp (string-append app "/manifest.ss")])
          (when (file-exists? mp) (delete-file mp))
          (call-with-output-file mp
            (lambda (p) (display "(manifest (format 1) (name \"test\") (version \"0.1.0\") (chez \">=10.0\") (srcdir \".\") (deps))" p))))
        (assert-equal 65 (main (list "-C" app "deps" "--strict")))))

    (install-non-strict-warns-but-not-rejected
      (let ([app (mktmp)])
        (let ([mp (string-append app "/manifest.ss")])
          (when (file-exists? mp) (delete-file mp))
          (call-with-output-file mp
            (lambda (p) (display "(manifest (format 1) (name \"test\") (version \"0.1.0\") (chez \">=10.0\") (srcdir \".\") (deps))" p))))
        (assert-true (not (= 65 (main (list "-C" app "deps")))))))

    (install-self-bootstrap-skips-check
      (let ([app (mktmp)])
        (let ([mp (string-append app "/manifest.ss")])
          (when (file-exists? mp) (delete-file mp))
          (call-with-output-file mp
            (lambda (p) (display "(manifest (format 1) (name \"chandler\") (version \"0.1.0\") (chez \">=10.0\") (srcdir \".\") (deps))" p))))
        (assert-true (not (= 65 (main (list "-C" app "deps" "--strict")))))))
    ))
