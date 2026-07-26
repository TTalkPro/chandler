#!chezscheme
;;; chandler/cli/main.ss --- dispatch + sysexits 退出码(designs/01 §退出码)

(library (chandler cli main)
  (export main)
  (import (chezscheme)
          (chandler util)
          (chandler runtime-detector)
          (chandler cli args)
          (chandler cli make)
          (chandler cli commands))

  (define chandler-cli-version chandler-version)

  ;; main:argv(不含程序名)→ 退出码
  (define (main argv)
    (call/cc
      (lambda (return)
        (with-exception-handler
          (lambda (e) (return (report-error e)))
          (lambda ()
            ;; `chandler make …` 自带一套 argv 语法(短旗标带值:-f path / -j N),
            ;; 与 chandler 的解析器不兼容(它把未知短旗标当布尔,-j 4 会拆成
            ;; 「布尔 -j」+「位置参数 4」)。故在解析**之前**原样转交子 CLI。
            (if (and (pair? argv) (string=? (car argv) "make"))
                (make-main (cdr argv))
                (let-values ([(sub pos flags rest) (parse-args argv)])
                  (let ([root (or (flag flags 'C) (current-directory))])
                    (dispatch sub pos flags rest root)))))))))

  ;; 命令表:dispatch 与 list-tasks 的**唯一事实源** —— 加命令只动这里,
  ;; `chandler -T` 就不会再列出不存在(或漏列已存在)的命令。
  ;; make 在 main 里先于解析被拦截转交子 CLI,不在此表;version 走旗标/特例。
  (define (command-table root flags pos rest)
    (list
      (cons 'init      (lambda () (cmd-init root flags)))
      (cons 'deps      (lambda () (cmd-deps root flags)))
      (cons 'install   (lambda () (cmd-install root flags)))
      (cons 'add       (lambda () (cmd-add root flags pos)))
      (cons 'remove    (lambda () (cmd-remove root flags pos)))
      (cons 'build     (lambda () (cmd-build root flags)))
      (cons 'run       (lambda () (cmd-run root flags pos rest)))
      (cons 'test      (lambda () (cmd-test root flags pos rest)))
      (cons 'env       (lambda () (cmd-env root flags)))
      (cons 'exec      (lambda () (cmd-exec root flags rest)))
      (cons 'repl      (lambda () (cmd-repl root flags)))
      (cons 'list      (lambda () (cmd-list root flags)))
      (cons 'tree      (lambda () (cmd-deps-tree root flags)))
      (cons 'pack      (lambda () (cmd-pack root flags)))
      (cons 'verify    (lambda () (cmd-verify root flags)))
      (cons 'verify-pack (lambda () (cmd-verify-pack root flags pos)))
      (cons 'uninstall (lambda () (cmd-uninstall-global root flags)))
      (cons 'doctor    (lambda () (cmd-doctor root flags)))
      (cons 'switch    (lambda () (cmd-switch root flags pos)))))

  (define (dispatch sub pos flags rest root)
    (cond
      [(eq? (flag flags 'version) #t) (print-version) 0]
      ;; `chandler -T`:-T 被 parse-args 收成布尔旗标(不是子命令),须在这里接住
      [(flag? flags 'T) (list-tasks) 0]
      [(or (not sub) (flag? flags 'help) (equal? sub "help")) (usage) 0]
      [else
       (let ([sym (string->symbol sub)])
         (cond
           [(eq? sym 'version) (print-version) 0]
           [(assq sym (command-table root flags pos rest)) => (lambda (h) ((cdr h)))]
           [else
            (fprintf (current-error-port)
                     "unknown command: ~a (run `chandler help` for usage)~%" sub)
            64
            ]))]))

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

  ;; 从命令表派生(再补上表外的 make / version),保证只列真实存在的命令
  (define (list-tasks)
    (printf "commands: ~a~%"
            (string-join
              (list-sort string<?
                         (append '("make" "version")
                                 (map (lambda (p) (symbol->string (car p)))
                                      (command-table #f #f #f #f))))
              " ")))

  (define (usage)
    (printf "chandler -- git-first library manager for Chez Scheme (Skiff ecosystem)~%~%")
    (printf "Usage: chandler <command> [args] [flags]~%~%")
    (printf "Commands:~%")
    (printf "  init [--lib|--app] [--name=N]  scaffold a chandler-manifest.ss (lib by default)~%")
    (printf "  add <name> <url> [--tag T]   add a dependency (--tag/--rev/--branch/--path)~%")
    (printf "  remove <name>                remove a dependency~%")
    (printf "  deps [--update]              resolve + vendor to _vendor/ + write lock~%")
    (printf "                               (--update forces re-resolve; --list/--tree show deps)~%")
    (printf "  install [--user|--system|--prefix=DIR]~%")
    (printf "                               install to ~~/.local/share/chez (--user default)~%")
    (printf "                               or /usr/local/chez (--system) or custom dir~%")
    (printf "  build [--allow-build[=a,b]]  compile deps + project to _build/<mt>/~%")
    (printf "  make [-f R] [-T|-P|-n|-c]    run tasks from chandler-tasks.ss (task runner;~%")
    (printf "                               `chandler make --help` for its own options)~%")
    (printf "  run --script <s.ss> [args]   run a script with the dependency environment~%")
    (printf "                               (loads <root>/.env; --env-file <p> overrides it)~%")
    (printf "  test [args...]               run tests/run-tests.sps with the project env~%")
    (printf "                               (.env + .env.tests override; same env as `run`)~%")
    (printf "  exec -- <cmd> [args]         run a command with CHEZSCHEMELIBDIRS + .env set~%")
    (printf "  env                          export CHEZSCHEMELIBDIRS + .env (eval it)~%")
    (printf "  repl [--runtime skiff|chez]  interactive shell with library paths mounted~%")
    (printf "  verify                       check _vendor/ matches the lock (CI; read-only)~%")
    (printf "  tree                         show the locked dependency tree (deps --tree)~%")
    (printf "  list                         list installed packages in the global prefix~%")
    (printf "                               (active version marked [active])~%")
    (printf "  pack [--runtime r] [--lib]   assemble a self-contained distribution (app pack);~%")
    (printf "                               --lib for library pack (no runtime/launcher)~%")
    (printf "  verify-pack [--target] <dir> re-hash a pack; --target also checks the target triple~%")
    (printf "  uninstall --name=N [--version=V]  uninstall a package (--version for specific version)~%")
    (printf "  doctor                       inspect the global library prefix~%")
    (printf "  switch <name> <version>      switch app's active version (multi-version coexist)~%")
    (printf "                               (--latest picks highest; --list shows all active)~%~%")
    (printf "Global flags: -C <dir> --offline --production --force --keep-extra --verbose~%~%")
    (printf "Environment:~%")
    (printf "  CHANDLER_RUNTIME=skiff|chez  pick WHICH runtime (run/exec/repl and the~%")
    (printf "                               launcher); --runtime overrides it~%")
    (printf "  CHANDLER_SKIFF=<exe>         which skiff executable (name or path)~%")
    (printf "  CHANDLER_SCHEME=<exe>        which Chez executable (name or path)~%")))
