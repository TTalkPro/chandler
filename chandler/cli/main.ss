#!chezscheme
;;; chandler/cli/main.ss --- dispatch + sysexits 退出码(designs/01 §退出码)

(library (chandler cli main)
  (export main)
  (import (chezscheme)
          (chandler util)
          (chandler cli args)
          (chandler cli commands)
          (chandler cli selfinstall))

  (define chandler-cli-version "0.1.0")

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
         [(verify)  (cmd-verify root flags)]
         [(list)    (cmd-list root flags)]
         [(tree)    (cmd-tree root flags)]
         [(add)     (cmd-add root flags pos)]
         [(remove)  (cmd-remove root flags pos)]
         [(run)     (cmd-run root flags pos rest)]
         [(exec)    (cmd-exec root flags rest)]
         [(uninstall) (cmd-uninstall root flags)]
         [(doctor)  (cmd-doctor root flags)]
         [(install-self) (cmd-install-self (self-src-root) flags)]
         [(uninstall-self) (cmd-uninstall-self root flags)]
         [(self-update) (cmd-self-update root flags)]
         [(-T)      (list-tasks) 0]
         [else
          (fprintf (current-error-port) "未知命令:~a(chandler help 看用法)~%" sub)
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
             "self-update:在 chandler 源码仓库执行 `git pull && ./install.sh` 即重装。~%~a~%"
             "(CHANDLER_HOME 指向已装 libdir;install.sh 复用 registry 升级事务,孤儿文件自动清理。)")
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

  (define (print-version)
    (printf "chandler ~a~%" chandler-cli-version))

  (define (list-tasks)
    (printf "命令:init install update verify list tree add remove run exec version~%"))

  (define (usage)
    (printf "chandler —— git-first 的 Chez Scheme 库管理器(Skiff 生态)~%~%")
    (printf "用法: chandler <命令> [参数] [旗标]~%~%")
    (printf "命令:~%")
    (printf "  init [--lib] [--name=N]      生成骨架 manifest.ss~%")
    (printf "  add <name> <url> [--tag T]   添加依赖(--tag/--rev/--branch/--path)~%")
    (printf "  remove <name>                移除依赖~%")
    (printf "  install [--production]       按 manifest/lock 解析并物化到 lib/~%")
    (printf "  update                       忽略旧 lock 重解析~%")
    (printf "  verify                       校验 lib/ 与 lock 一致(CI 用)~%")
    (printf "  list | tree                  显示已锁依赖~%")
    (printf "  run <script.ss> [args…]      挂依赖库路径 + 载 native 后跑脚本~%")
    (printf "  exec -- <cmd…>               设 CHEZSCHEMELIBDIRS 后跑命令~%")
    (printf "  install-self [--prefix D]    自装 chandler 到 ~~/.local(--global=/usr/local)~%")
    (printf "  uninstall-self [--prefix D]  卸载自装的 chandler~%~%")
    (printf "全局旗标: -C <dir> --offline --production --force --keep-extra --verbose~%")))
