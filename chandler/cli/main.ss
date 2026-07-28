#!chezscheme
;;; chandler/cli/main.ss --- dispatch + sysexits 退出码(designs/01 §退出码)

(library (chandler cli main)
  (export main
          ;; D42 的判别件:导出供单元测试。broken-pipe? 是这条路上唯一的决策点,
          ;; pipe-phrase-match? 单独导出是因为它那半边(Windows-only 那张表)
          ;; 在 Linux 上只能靠 parameterize windows-shell? 来驱动。
          broken-pipe? pipe-phrase-match?)
  (import (chezscheme)
          (chandler util)
          (chandler runtime-detector)
          ;; windows-shell?:文案表的平台闸门。stdout-pipe-gone?:探针,住在
          ;; proc 的 §FFI(全仓唯一碰 FFI 的地方)。
          (only (chandler proc) windows-shell? stdout-pipe-gone?)
          (chandler cli args)
          (chandler cli make)
          (chandler cli commands))

  (define chandler-cli-version chandler-version)

  ;; ══════════════════════════════════════════════════════════════════
  ;; broken pipe —— `chandler make -P | head` 不得假报错(D42)
  ;;
  ;; 症状:下游读够就退出,chandler 的 stdout 写失败 ⇒ report-error 打一行
  ;; 「failed on #<binary output port stdout>: broken pipe」+ 退出码 65。
  ;; 实测:`make -P`(649 行)必现;`make -T`(几行,塞得进管道缓冲)不现。
  ;;
  ;; 判别【MUST】分两步,顺序不得调换:**先认人,再问 OS**。
  ;; 机制层面的根因与两平台读数见 (chandler proc) 的 §FFI。
  ;; ══════════════════════════════════════════════════════════════════

  ;; **自证型**文案:句子本身就说明"管道对端没了",不可能来自别的失败。
  ;; 无条件匹配即可 —— POSIX 的 strerror 不会吐 Win32 措辞,反之亦然。
  (define pipe-gone-phrases
    '("broken pipe"                        ; POSIX EPIPE
      "the pipe has been ended"            ; Win32 ERROR_BROKEN_PIPE (109)
      "the pipe is being closed"           ; Win32 ERROR_NO_DATA (232)
      "no process is on the other end of the pipe"))

  ;; **非自证型**文案,仅 Windows。bake 在 a6nt 上实测:报的既不是上面任何一句,
  ;; 也不是 EPIPE,而是 `invalid argument` —— MSVCRT 的 `_dosmaperr` 映射表里
  ;; **没有** ERROR_BROKEN_PIPE(109),未收录的一律落到默认 EINVAL,于是 Win32
  ;; 那三句在 Chez 这一层根本到不了。
  ;;
  ;; 【已知取舍 —— D42 之后只在探针不可用的降级路径上还生效】
  ;; EINVAL 不自证,理论上别的写失败也可能映射到它。收下的理由是代价与风险不对称:
  ;; 不收 ⇒ `chandler make -P | more` 在 Windows 上**必然**假报错;收下 ⇒ 风险是
  ;; 假想的第二种映射到 EINVAL 的真实写失败。【MUST】只在 Windows 上放松。
  (define pipe-gone-phrases/windows-only
    '("invalid argument"))

  ;; 大小写不敏感:Chez 给的是 "Broken pipe"(大写 B),而 report-error 那条
  ;; `~(~a~)` 会折叠成小写 —— 同一件事在两处长得不一样,比较前统一降格。
  (define (pipe-phrase-match? s)
    (let ([low (string-downcase s)])
      (define (any-of phrases)
        (exists (lambda (ph) (string-contains? low ph)) phrases))
      (or (any-of pipe-gone-phrases)
          (and (windows-shell?) (any-of pipe-gone-phrases/windows-only)))))

  (define (phrase-says-pipe-gone? e)
    (and (irritants-condition? e)
         (exists (lambda (x) (and (string? x) (pipe-phrase-match? x)))
                 (condition-irritants e))))

  ;; 出错的到底是不是 chandler 自己的 stdout。#t / #f / 'unknown
  ;;
  ;; 这一步是相对「只比文案」的实质收紧:老判别没有它,recipe 自己开的文件 port
  ;; 写失败时若文案撞上表里的句子(Windows 上就是那句通用的 invalid argument),
  ;; 一样会被静默。本机实测:stdout 给 fd=1 name="stdout",另开的文件 port 给别的 fd。
  (define (stdout-error? e)
    (if (not (i/o-port-error? e))
        'unknown
        (let* ([p  (i/o-error-port e)]
               [fd (ignore-errors (port-file-descriptor p))])
          (cond
            [(eqv? fd 1) #t]
            [(equal? (ignore-errors (port-name p)) "stdout") #t]
            [fd #f]                        ; 确定是别的 fd ⇒ 不静默
            [else 'unknown]))))            ; 两样都问不出 ⇒ 退回文案表

  (define (broken-pipe? e)
    (and (i/o-write-error? e)
         (let ([whose (stdout-error? e)])
           (cond
             [(eq? whose #f) #f]                     ; 确定不是 stdout ⇒ 不静默
             [(eq? whose 'unknown)                   ; 认不出人 ⇒ 老路
              (phrase-says-pipe-gone? e)]
             [else
              (let ([ans (stdout-pipe-gone?)])       ; 问 OS
                (if (eq? ans 'unknown)               ; 这台机器问不了 ⇒ 老路
                    (phrase-says-pipe-gone? e)
                    ans))]))))

  ;; main:argv(不含程序名)→ 退出码
  (define (main argv)
    (call/cc
      (lambda (return)
        (with-exception-handler
          (lambda (e)
            (if (broken-pipe? e)
                (begin
                  ;; 【MUST】缓冲里剩下的内容必须丢掉:留着的话 main.sps 的
                  ;; `(exit …)` 在 flush 时会**再抛一次**,那次在本 handler 之外,
                  ;; 退出码又变回非零 —— 静默等于没做。
                  (ignore-errors (clear-output-port (current-output-port)))
                  (return 0))
                (return (report-error e))))
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
            (eprintf
                     "unknown command: ~a (run `chandler help` for usage)~%" sub)
            64
            ]))]))

  ;; Chez 自带的条件(尤其 I/O)把格式指令写在 message 里、值放 irritants ——
  ;; 例如 open-file 失败是 message "failed for ~a: ~(~a~)" + irritants (路径 原因)。
  ;; 直接 display 会把 `~a` 原样打给用户,故先按 format 试;chandler 自己 error 出来的
  ;; message 不含指令,那条路会失败(实参多余),再退回「消息 + 写出 irritants」。
  (define (report-error e)
    (eprintf "chandler: ")
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
