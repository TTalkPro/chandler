#!chezscheme
;;; chandler/cli/main.ss --- dispatch + sysexits 退出码(designs/01 §退出码)

(library (chandler cli main)
  (export main)
  (import (chezscheme)
          (chandler util)
          (chandler runtime-detector)
          (chandler cli args)
          (chandler cli bake)
          (chandler cli commands))

  (define chandler-cli-version chandler-version)

  ;; main:argv(不含程序名)→ 退出码
  (define (main argv)
    (call/cc
      (lambda (return)
        (with-exception-handler
          (lambda (e) (return (report-error e)))
          (lambda ()
            ;; `chandler bake …` 自带一套 argv 语法(短旗标带值:-f path / -j N),
            ;; 与 chandler 的解析器不兼容(它把未知短旗标当布尔,-j 4 会拆成
            ;; 「布尔 -j」+「位置参数 4」)。故在解析**之前**原样转交子 CLI。
            (if (and (pair? argv) (string=? (car argv) "bake"))
                (bake-main (cdr argv))
                (let-values ([(sub pos flags rest) (parse-args argv)])
                  (let ([root (or (flag flags 'C) (current-directory))])
                    (dispatch sub pos flags rest root)))))))))

  (define (dispatch sub pos flags rest root)
    (cond
      [(flag? flags 'version) (print-version) 0]
      [(or (not sub) (flag? flags 'help) (equal? sub "help")) (usage) 0]
      [else
       (case (string->symbol sub)
         [(version) (print-version) 0]
         [(init)    (cmd-init root flags)]
         [(deps)    (cmd-deps root flags)]
         [(install) (cmd-install root flags)]
         [(add)     (cmd-add root flags pos)]
         [(remove)  (cmd-remove root flags pos)]
         [(build)   (cmd-build root flags)]
         [(run)     (cmd-run root flags pos rest)]
         [(env)     (cmd-env root flags)]
         [(repl)    (cmd-repl root flags)]
         [(pack)    (cmd-pack root flags)]
         [(verify-pack) (cmd-verify-pack root flags pos)]
         [(uninstall) (cmd-uninstall-global root flags)]
         [(doctor)  (cmd-doctor root flags)]
         [(-T)      (list-tasks) 0]
         [else
          (fprintf (current-error-port)
                   "unknown command: ~a (run `chandler help` for usage)~%" sub)
          64])]))

  ;; Chez 自带的条件(尤其 I/O)把格式指令写在 message 里、值放 irritants ——
  ;; 例如 open-file 失败是 message "failed for ~a: ~(~a~)" + irritants (路径 原因)。
  ;; 直接 display 会把 `~a` 原样打给用户,故先按 format 试;chandler 自己 error 出来的
  ;; message 不含指令,那条路会失败(实参多余),再退回「消息 + 写出 irritants」。
  (define (report-error e)
    (fprintf (current-error-port) "chandler: ")
    (cond
      [(and (condition? e) (message-condition? e))
       (let* ([msg (condition-message e)]
              [irr (if (irritants-condition? e) (condition-irritants e) '())]
              [formatted (and (pair? irr) (ignore-errors (apply format msg irr)))])
         (if formatted
             (display formatted (current-error-port))
             (begin
               (display msg (current-error-port))
               (for-each (lambda (x)
                           (display " " (current-error-port))
                           (write x (current-error-port)))
                         irr))))]
      [else (write e (current-error-port))])
    (newline (current-error-port))
    65)

  ;; 版本行同时报告**所在运行时**(与 bake --version 同款):skiff 自 0.1.1 起以内置
  ;; (skiff-version) 自证版本,故 skiff 上能精确报出;Chez 版本恒报。
  ;;   chandler 0.1.2 (skiff 0.1.1) (chez 10.4.1)
  (define (print-version)
    (printf "chandler ~a" chandler-cli-version)
    (when (eq? 'skiff (current-runtime))
      (printf " (skiff ~a)" (runtime-version)))
    (printf " (chez ~a)~%" (chez-version-string)))

  (define (list-tasks)
    (printf "commands: init add remove install update build bake pack verify verify-pack list tree run exec repl version~%"))

  (define (usage)
    (printf "chandler -- git-first library manager for Chez Scheme (Skiff ecosystem)~%~%")
    (printf "Usage: chandler <command> [args] [flags]~%~%")
    (printf "Commands:~%")
    (printf "  init [--lib|--app] [--name=N]  scaffold a manifest.ss (lib by default)~%")
    (printf "  add <name> <url> [--tag T]   add a dependency (--tag/--rev/--branch/--path)~%")
    (printf "  remove <name>                remove a dependency~%")
    (printf "  deps [--update]              resolve + vendor + install source to lib/src/~%")
    (printf "                               (--update forces re-resolve; --list/--tree show deps)~%")
    (printf "  install [--global]           install lib + deps to ~~/.local/share/chez (global)~%")
    (printf "  build [--allow-build[=a,b]]  compile deps + project to lib/<mt>/~%")
    (printf "  bake [-f R] [-T|-P|-n|-c]    run tasks from chandler-tasks.ss (task runner;~%")
    (printf "                               `chandler bake --help` for its own options)~%")
    (printf "  run --script <s.ss> [args]   run a script with the dependency environment~%")
    (printf "                               (loads <root>/.env; --env-file <p> overrides it)~%")
    (printf "  env                          export CHEZSCHEMELIBDIRS + APP_ROOT + .env (eval it)~%")
    (printf "  repl [--runtime skiff|chez]  interactive shell with library paths mounted~%")
    (printf "  pack [--runtime r]           assemble a source-less, self-contained distribution~%")
    (printf "  verify-pack [--target] <dir> re-hash a pack; --target also checks the target triple~%")
    (printf "  uninstall --global --name=N  uninstall a globally installed package~%")
    (printf "  doctor --global              inspect the global library prefix~%~%")
    (printf "Global flags: -C <dir> --offline --production --force --keep-extra --verbose~%~%")
    (printf "Environment:~%")
    (printf "  CHANDLER_RUNTIME=skiff|chez  pick WHICH runtime (run/exec/repl and the~%")
    (printf "                               launcher); --runtime overrides it~%")
    (printf "  CHANDLER_SKIFF=<exe>         which skiff executable (name or path)~%")
    (printf "  CHANDLER_SCHEME=<exe>        which Chez executable (name or path)~%")))
