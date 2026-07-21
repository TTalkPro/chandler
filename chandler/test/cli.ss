#!chezscheme
;;; chandler/test/cli.ss --- (chandler cli args) 单测 + CLI 端到端(经 main)

(library (chandler test cli)
  (export suite)
  (import (chezscheme)
          (chandler test harness)
          (chandler test fixtures)
          (chandler fetch)
          (chandler install)
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

    ;; ── 端到端:init→add→install→verify→list 全经 main ──
    (main-full-workflow
      (parameterize ([cache-root (mktmp)])
        (let* ([greet (make-lib-repo "greet")]
               [app (mktmp)])
          (assert-equal 0 (main (list "-C" app "init" "--name=app")))
          (assert-equal 0 (main (list "-C" app "add" "greet" greet "--branch" "main")))
          (assert-equal 0 (main (list "-C" app "install")))
          (assert-equal 0 (main (list "-C" app "verify")))
          (assert-equal 0 (main (list "-C" app "list")))
          ;; 新模型:git 依赖 checkout 到 vendor/,bake install 到扁平 lib/,生成 setup
          (assert-true (file-exists? (string-append app "/vendor/greet/greet.ss")))  ; checkout
          (assert-true (file-exists? (string-append app "/lib/greet.ss")))           ; bake 装的扁平库
          (assert-true (file-exists? (string-append app "/chandler-setup.ss"))))))   ; 生成的引入文件

    ;; ── 库搜索模式判定(run/exec/repl 统一):无 lock/依赖 → 全局;有 → 项目(最高优先)──
    (libdir-mode-detection
      (parameterize ([cache-root (mktmp)])
        (let* ([greet (make-lib-repo "greet")]
               [app (mktmp)])
          ;; 仅 init(有 manifest,无 lock)→ 非项目 → 全局模式
          (main (list "-C" app "init" "--name=app"))
          (assert-false (project-mode? app))
          (assert-equal (list (global-libdir)) (resolved-libdirs app))
          ;; add + install → lock 有依赖 → 项目模式
          (main (list "-C" app "add" "greet" greet "--branch" "main"))
          (main (list "-C" app "install"))
          (assert-true (project-mode? app))
          ;; 项目 libdirs:扁平 lib/ 在前 + 项目根 + 全局兜底在末尾
          (let ([dirs (resolved-libdirs app)])
            (assert-true (>= (length dirs) 2))
            (assert-string= (string-append app "/lib") (car dirs))               ; 扁平 lib/ 在前
            (assert-string= (global-libdir) (list-ref dirs (- (length dirs) 1)))))))  ; 全局兜底在末尾
    ))
