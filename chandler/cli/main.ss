#!chezscheme
;;; chandler/cli/main.ss --- dispatch + sysexits 退出码(designs/01 §退出码)

(library (chandler cli main)
  (export main)
  (import (chezscheme)
          (chandler util)
          (chandler runtime)                  ; 报告所在运行时(skiff 自证版本)
          (chandler cli args)
          (chandler cli commands)
          (chandler cli selfinstall))

  (define chandler-cli-version "0.1.4")

  ;; main:argv(不含程序名)→ 退出码
  (define (main argv)
    (call/cc
      (lambda (return)
        (with-exception-handler
          (lambda (e) (return (report-error e)))
          (lambda ()
            (let-values ([(sub pos flags rest) (parse-args argv)])
              (let ([root (or (flag flags 'C) (current-directory))])
                (dispatch sub pos flags rest root))))))))

  (define (dispatch sub pos flags rest root)
    (cond
      [(flag? flags 'version) (print-version) 0]
      [(or (not sub) (flag? flags 'help) (equal? sub "help")) (usage) 0]
      [else
       (case (string->symbol sub)
         [(version) (print-version) 0]
         [(init)    (cmd-init root flags)]
         [(install) (cmd-install root flags)]
         [(update)  (cmd-update root flags)]
         [(build)   (cmd-build root flags)]
         [(pack)    (cmd-pack root flags)]
         [(verify-pack) (cmd-verify-pack root flags pos)]
         [(verify)  (cmd-verify root flags)]
         [(list)    (cmd-list root flags)]
         [(tree)    (cmd-tree root flags)]
         [(add)     (cmd-add root flags pos)]
         [(remove)  (cmd-remove root flags pos)]
         [(run)     (cmd-run root flags pos rest)]
         [(exec)    (cmd-exec root flags rest)]
         [(repl)    (cmd-repl root flags)]
         [(uninstall) (cmd-uninstall root flags)]
         [(doctor)  (cmd-doctor root flags)]
         [(install-self) (cmd-install-self (self-src-root) flags)]
         [(uninstall-self) (cmd-uninstall-self root flags)]
         [(self-update) (cmd-self-update root flags)]
         [(-T)      (list-tasks) 0]
         [else
          (fprintf (current-error-port)
                   "unknown command: ~a (run `chandler help` for usage)~%" sub)
          64])]))

  ;; install-self 的源根 = chandler 源码 checkout(不是 -C 项目目录)。
  ;; 优先 CHANDLER_SRC(install.sh 设),否则从程序路径 …/chandler/cli/main.sps 反推。
  (define (self-src-root)
    (or (getenv "CHANDLER_SRC")
        (let ([prog (car (command-line))] [suf "/chandler/cli/main.sps"])
          (and (string-suffix? suf prog) (strip-suffix prog suf)))
        (current-directory)))

  ;; self-update:提示走 install.sh(自更新 = 对自身仓库重跑安装事务,designs/08 §2)
  (define (cmd-self-update root flags)
    (fprintf (current-error-port)
             "self-update: run `git pull && ./install.sh` in the chandler source checkout.~%~a~%"
             "(install.sh delegates the library tree to `bake install`, which replaces the previous install.)")
    0)

  (define (report-error e)
    (fprintf (current-error-port) "chandler: ")
    (cond
      [(and (condition? e) (message-condition? e))
       (display (condition-message e) (current-error-port))
       (when (irritants-condition? e)
         (for-each (lambda (x) (display " " (current-error-port)) (write x (current-error-port)))
                   (condition-irritants e)))]
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
    (printf "commands: init add remove install update build pack verify verify-pack list tree run exec repl version~%"))

  (define (usage)
    (printf "chandler -- git-first library manager for Chez Scheme (Skiff ecosystem)~%~%")
    (printf "Usage: chandler <command> [args] [flags]~%~%")
    (printf "Commands:~%")
    (printf "  init [--lib|--app] [--name=N]  scaffold a manifest.ss (lib by default)~%")
    (printf "  add <name> <url> [--tag T]   add a dependency (--tag/--rev/--branch/--path)~%")
    (printf "  remove <name>                remove a dependency~%")
    (printf "  install [--production]       resolve manifest/lock, vendor deps, install to lib/~%")
    (printf "  update                       ignore the existing lock and re-resolve~%")
    (printf "  build [--allow-build[=a,b]]  compile deps via bake into lib/<machine-type>/~%")
    (printf "  pack [--runtime r]           assemble a source-less, self-contained distribution~%")
    (printf "  verify-pack <dir>            re-hash a pack against its manifest~%")
    (printf "  verify                       check vendor/ against the lock (for CI)~%")
    (printf "  list | tree                  show locked dependencies~%")
    (printf "  run <script.ss> [args...]    run a script with the dependency environment~%")
    (printf "  exec -- <cmd...>             run a command with CHEZSCHEMELIBDIRS set~%")
    (printf "  repl [--runtime skiff|chez]  interactive shell with library paths mounted~%")
    (printf "  install --global[=dir]       install this project's library tree globally~%")
    (printf "  uninstall --global --name=N  uninstall a globally installed package~%")
    (printf "  list --global | doctor --global   inspect the global library prefix~%")
    (printf "  install-self [--global]      install chandler itself (libraries via bake install)~%")
    (printf "  uninstall-self [--global]    remove a self-installed chandler~%")
    (printf "  self-update                  how to update a self-installed chandler~%~%")
    (printf "Global flags: -C <dir> --offline --production --force --keep-extra --verbose~%~%")
    (printf "Environment:~%")
    (printf "  CHANDLER_RUNTIME=skiff|chez  pick WHICH runtime (run/exec/repl and the~%")
    (printf "                               launcher); --runtime overrides it~%")
    (printf "  CHANDLER_SKIFF=<exe>         which skiff executable (name or path)~%")
    (printf "  CHANDLER_SCHEME=<exe>        which Chez executable (name or path)~%")
    (printf "  CHANDLER_BAKE=<exe>          which bake executable (install/build delegate to it)~%")))
