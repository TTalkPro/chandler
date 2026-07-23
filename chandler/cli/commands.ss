#!chezscheme
;;; chandler/cli/commands.ss --- 各子命令实现(designs/01)
;;;
;;; 命令函数取 (root flags),返回退出码(sysexits 风格,见 main.ss)。
;;; 依赖获取/物化归 (chandler install);解析归 (chandler resolve)。

(library (chandler cli commands)
  (export cmd-init cmd-install cmd-update cmd-verify cmd-list cmd-tree
          cmd-add cmd-remove cmd-run cmd-exec cmd-repl
          cmd-uninstall cmd-doctor cmd-build cmd-pack cmd-verify-pack
          ensure-gitignore-lib skeleton-manifest-datum)
  (import (chezscheme)
          (chandler util)
          (chandler fs)
          (chandler proc)
          (chandler sexp)
          (chandler layout)
          (chandler manifest)
          (chandler lock)
          (chandler install)
          (chandler registry)
          (chandler runtime-detector)
          (chandler build)
          (chandler pack)
          (chandler cli args))

  ;; ── pack / verify-pack(designs/09)──
  ;; pack 只**组装**:应用编译树(bake build)+ 依赖闭包(chandler build)+ 随包运行时。
  ;; 缺件一律在前置校验里停下并说清该跑哪个命令 —— native 尤其无法在消费方现编。
  (define (cmd-pack root flags)
    (pack root
          (list (cons 'runtime (and (flag flags 'runtime) (string->symbol (flag flags 'runtime))))
                (cons 'out     (flag flags 'out))
                (cons 'name    (flag flags 'name))
                (cons 'version (flag flags 'version))
                (cons 'entry   (parse-entry (flag flags 'entry)))
                (cons 'main    (and (flag flags 'main) (string->symbol (flag flags 'main)))))))

  ;; --entry '(myapp core)' —— 库名 s-表达式;缺省由 pack 取 (<manifest name>)
  (define (parse-entry s)
    (and s
         (let ([d (with-input-from-string s read)])
           (unless (and (pair? d) (for-all symbol? d))
             (error 'pack (format "--entry must be a library name like '(myapp)', got ~s" s)))
           d)))

  ;; --target(designs/10 §7b):完整性之外再对当前 runtime 跑 verify-target! 矩阵
  (define (cmd-verify-pack root flags pos)
    (let ([target (positional-ref pos 0 #f)])
      (unless target (error 'verify-pack "usage: chandler verify-pack [--target] <dir|pack.manifest>"))
      (verify-pack (if (string-prefix? "/" target) target (join-paths root target))
                   (flag? flags 'target))))

  ;; ── init ──
  ;; ── init ──
  ;; --lib:  显式声明这是 lib(顺带按[库布局规范]出目录骨架)
  ;; --app:  显式声明这是 app(写 (app (entry …)) 到 manifest);默认 entry = (name),--entry 覆盖
  ;; --lib / --app 互斥;都不传 = 默认 lib(无 (app …))
  (define (cmd-init root flags)
    (let* ([name (or (flag flags 'name) (basename root))]
           [mpath (join-paths root "manifest.ss")]
           [lib?  (flag? flags 'lib)]
           [app?  (flag? flags 'app)]
           [entry (or (parse-entry (flag flags 'entry))
                      (and app? (list (string->symbol name))))]
           [main  (or (and (flag flags 'main) (string->symbol (flag flags 'main))) 'main)])
      (when (and lib? app?)
        (error 'init "--lib and --app are mutually exclusive"))
      (when (and (file-exists? mpath) (not (flag? flags 'force)))
        (error 'init "manifest.ss already exists; use --force to overwrite" mpath))
      (write-canonical-file mpath
        (if app?
            (skeleton-app-manifest-datum name entry main)
            (skeleton-manifest-datum name)))
      (ensure-gitignore-lib root)
      (when lib? (scaffold-lib root name))
      (printf "wrote ~a~%" mpath)
      0))

  ;; chandler runtime dep 注入模板(designs/12 §5.3 soft 强制)
  (define chandler-dep-template
    `(chandler (git "https://github.com/skiffos/chandler") (version "^0.1.4")))

  (define (skeleton-manifest-datum name)
    `(manifest (format 1) (name ,name) (version "0.1.0") (chez ">=10.0") (srcdir ".")
       (deps ,chandler-dep-template)))

  ;; app 形态:多一个 (app (entry …) (main …)) 字段。entry 是 symbol list(库名),
  ;; main 是 symbol(入口过程名)。这两个就是 pack 的入口契约 —— 声明了就能 pack,
  ;; 没声明(走 skeleton-manifest-datum)就是 lib,pack 会拒绝。
  (define (skeleton-app-manifest-datum name entry main)
    `(manifest (format 1) (name ,name) (version "0.1.0") (chez ">=10.0") (srcdir ".")
       (deps ,chandler-dep-template)
       (app (entry ,entry) (main ,main))))

  ;; ── install / update ──
  ;; N5:检测项目是否依赖 chandler runtime;缺则 warning(--strict 则拒绝)。
  ;; 自举例外:项目名 = "chandler" 时跳过(designs/12 §5.2)。
  (define (dep-list-has-chandler? deps)
    (and (pair? deps)
         (exists (lambda (d) (eq? (dep-name d) 'chandler)) deps)))

  (define (check-chandler-dep root flags)
    ;; 返回 #t = 可继续;#f = --strict 拒绝(返回 65)
    (let ([mpath (join-paths root "manifest.ss")])
      (if (not (file-exists? mpath))
          #t
          (let ([mf (read-manifest mpath)])
            (cond
              [(string=? (or (manifest-name mf) "") "chandler") #t]  ; 自举例外
              [(dep-list-has-chandler? (manifest-deps mf)) #t]        ; 已声明
              [(flag? flags 'strict)
               (fprintf (current-error-port)
                 "chandler: project does not depend on chandler; add (deps (chandler ...)) to manifest.ss\n")
               #f]
              [else
               (fprintf (current-error-port)
                 "warning: project does not depend on chandler; add (deps (chandler ...)) to manifest.ss or run chandler init\n")
               #t])))))

  ;; --global:装当前项目库树到全局 libdir(注册表事务,designs/05)
  (define (cmd-install root flags)
    (if (flag? flags 'global)
        (cmd-install-global root flags)
        (if (check-chandler-dep root flags)
            (install root (install-opts flags))
            65)))  ; EX_DATAERR

  (define (cmd-install-global root flags)
    (let* ([libdir (target-libdir flags)]
           [mpath (join-paths root "manifest.ss")]
           [mf (and (file-exists? mpath) (read-manifest mpath))]
           [name (or (and mf (manifest-name mf)) (basename root))]
           [version (or (and mf (manifest-version mf)) "0.0.0")]
           [meta (list name version `(path ,root) (now-iso) 'chandler)]
           [opts (list (cons 'adopt (flag? flags 'adopt)) (cons 'force (flag? flags 'force)))])
      (install-global root libdir meta opts)
      (printf "installed ~a ~a globally to ~a~%" name version libdir)
      0))

  (define (cmd-uninstall root flags)
    (unless (flag? flags 'global) (error 'uninstall "only --global is supported"))
    (let ([libdir (target-libdir flags)]
          [name (flag flags 'name)])
      (unless name (error 'uninstall "usage: chandler uninstall --global --name=<name>"))
      (uninstall-global name libdir (list (cons 'keep-modified (flag? flags 'keep-modified))))
      (printf "uninstalled ~a~%" name)
      0))

  (define (cmd-doctor root flags)
    (let* ([libdir (target-libdir flags)]
           [issues (doctor-global libdir)])
      (if (null? issues)
          (begin (printf "doctor: no issues in global library prefix ~a~%" libdir) 0)
          (begin
            (for-each (lambda (i) (fprintf (current-error-port) "  ~a~%" i)) issues)
            (fprintf (current-error-port) "doctor: ~a issue(s) found~%" (length issues))
            65))))

  (define (target-libdir flags)
    (cond
      [(flag? flags 'system) (default-system-libdir)]
      [(and (string? (flag flags 'global))) (flag flags 'global)]  ; --global=dir
      [else (default-user-libdir)]))

  ;; ISO-ish 时间戳(installed-at,纯记录)
  (define (now-iso)
    (let ([t (current-date)])
      (format "~a-~a-~aT~a:~a:~a"
              (date-year t) (pad2 (date-month t)) (pad2 (date-day t))
              (pad2 (date-hour t)) (pad2 (date-minute t)) (pad2 (date-second t)))))
  (define (pad2 n) (if (< n 10) (format "0~a" n) (format "~a" n)))

  (define (cmd-update root flags)
    ;; 删 lock 触发重解析(全量);具名 update 的增量留待细化
    (let ([lpath (project-lock-path root)])
      (when (file-exists? lpath) (delete-file lpath)))
    (install root (install-opts flags)))

  (define (install-opts flags)
    (list (cons 'production (flag? flags 'production))
          (cons 'force (flag? flags 'force))
          (cons 'keep-extra (flag? flags 'keep-extra))
          (cons 'offline (flag? flags 'offline))))

  ;; ── verify ──
  ;; ── build:排单 → bake(designs/07)──
  (define (cmd-build root flags)
    (build root (list (cons 'allow-build (flag flags 'allow-build))
                      (cons 'production (flag? flags 'production)))))

  (define (cmd-verify root flags)
    (if (verify root)
        (begin (printf "verify: vendor/ and lib/ match manifest.lock~%") 0)
        (begin (fprintf (current-error-port) "verify: mismatch (see above)~%") 65)))

  ;; ── list / tree ──
  (define (cmd-list root flags)
    (if (flag? flags 'global)
        (cmd-list-global flags)
        (cmd-list-local root flags)))

  (define (cmd-list-global flags)
    (let ([rows (list-global (target-libdir flags))])
      (if (null? rows)
          (printf "(no packages installed in the global library prefix)~%")
          (for-each (lambda (r) (printf "~a  ~a  [~a]~%" (car r) (cadr r) (caddr r))) rows))
      0))

  (define (cmd-list-local root flags)
    (let ([rows (list-deps root)])
      (if (null? rows)
          (printf "(no locked dependencies; run `chandler install` first)~%")
          (for-each
            (lambda (r)
              (printf "~a  ~a  ~a~a~%"
                      (car r) (cadr r) (caddr r)
                      (if (eq? 'dev (cadddr r)) "  [dev]" "")))
            rows))
      0))

  (define (cmd-tree root flags)
    ;; 简树:根 → 依赖(基于 lock deps 图)
    (let ([lpath (project-lock-path root)])
      (if (not (file-exists? lpath))
          (begin (printf "(no lock file)~%") 0)
          (let ([lk (read-lock lpath)])
            (printf "(root)~%")
            (for-each (lambda (d)
                        (printf "  ├─ ~a @~a~%" (locked-dep-name d)
                                (short (locked-dep-rev d)))
                        (for-each (lambda (child)
                                    (printf "  │    └─ ~a~%" child))
                                  (locked-dep-deps d)))
                      (lock-deps lk))
            0))))

  ;; ── add / remove(datum 级改写 manifest;init 生成的规范清单适用)──
  (define (cmd-add root flags positionals)
    (let ([name (and (pair? positionals) (car positionals))]
          [url  (and (pair? positionals) (pair? (cdr positionals)) (cadr positionals))])
      (unless name (error 'add "usage: chandler add <name> <git-url> [--tag/--rev/--branch]"))
      (let* ([mpath (join-paths root "manifest.ss")]
             [datum (read-datum-file mpath)]
             [dep (build-dep-sexpr (string->symbol name) url flags)]
             [datum* (add-dep datum dep)])
        (write-canonical-file mpath datum*)
        (printf "added dependency ~a~%" name)
        0)))

  (define (build-dep-sexpr name url flags)
    (let ([path (flag flags 'path)])
      (if path
          `(,name (path ,path))
          (let ([src `(git ,url)]
                [pin (cond
                       [(flag flags 'tag) => (lambda (v) `(tag ,(as-str v)))]
                       [(flag flags 'rev) => (lambda (v) `(rev ,(as-str v)))]
                       [(flag flags 'branch) => (lambda (v) `(branch ,(as-str v)))]
                       [else #f])])
            (unless url (error 'add "a git dependency requires a URL"))
            (if pin `(,name ,src ,pin) `(,name ,src))))))

  (define (as-str v) (if (string? v) v (format "~a" v)))

  ;; 往 manifest datum 的 (deps …) 追加一项;无 deps 则新增
  (define (add-dep datum dep)
    (let ([body (cdr datum)])
      (cons 'manifest (upsert-deps body dep))))

  (define (upsert-deps body dep)
    (let loop ([b body] [seen #f] [acc '()])
      (cond
        [(null? b)
         (reverse (if seen acc (cons `(deps ,dep) acc)))]
        [(tagged-list? (car b) 'deps)
         (loop (cdr b) #t (cons (append (car b) (list dep)) acc))]
        [else (loop (cdr b) seen (cons (car b) acc))])))

  (define (cmd-remove root flags positionals)
    (let ([name (and (pair? positionals) (string->symbol (car positionals)))])
      (unless name (error 'remove "usage: chandler remove <name>"))
      (let* ([mpath (join-paths root "manifest.ss")]
             [datum (read-datum-file mpath)]
             [datum* (cons 'manifest (remove-dep (cdr datum) name))])
        (write-canonical-file mpath datum*)
        (printf "removed dependency ~a (next install will clean lib/)~%" name)
        0)))

  (define (remove-dep body name)
    (map (lambda (field)
           (if (or (tagged-list? field 'deps) (tagged-list? field 'dev-deps))
               (cons (car field)
                     (filter (lambda (d) (not (eq? (car d) name))) (cdr field)))
               field))
         body))

  ;; ── run / exec / repl:库搜索规则统一(install 的 resolved-libdirs,同 repl)──
  ;; run:组库路径 + 载 native + 跑脚本(生成 preamble,自包含,不需子进程有 (chandler))
  (define (cmd-run root flags positionals rest)
    (let ([script (and (pair? positionals) (car positionals))])
      (unless script (error 'run "usage: chandler run <script.ss> [args...]"))
      (let* ([dirs (resolved-libdirs root)]
             [natives (native-load-paths root)]
             [preamble (make-preamble root natives (abspath root script))]
             [interp (choose-interp root flags)]
             [args (append (list "-q" "--libdirs" (path-list dirs)
                                 "--script" preamble)
                           (or rest '()) (cdr positionals))])
        (run-foreground interp args))))

  ;; exec:仅设 CHEZSCHEMELIBDIRS 后跑任意命令(给编辑器/CI)
  (define (cmd-exec root flags rest)
    (unless (and rest (pair? rest)) (error 'exec "usage: chandler exec -- <cmd...>"))
    (let ([dirs (resolved-libdirs root)])
      (run-foreground (car rest) (cdr rest)
                      (list (cons 'env (list (cons "CHEZSCHEMELIBDIRS" (path-list dirs))))))))

  ;; ── repl:交互式 shell,自动挂库搜索路径(与 run/exec 同规则)──
  ;;   项目模式(lock 存在且有依赖):lib/ + path 源目录 + 项目库根 + 全局(项目最高优先)
  ;;   全局模式(无 lock / 无依赖):用户全局 lib 目录
  (define (cmd-repl root flags)
    (let* ([project? (project-mode? root)]
           [dirs     (resolved-libdirs root)]
           [natives  (if project? (native-load-paths root) '())]
           [interp   (repl-interp root flags)])
      (fprintf (current-error-port)
               "chandler repl: ~a mode, ~a library search entries, runtime ~a~%"
               (if project? "project" "global") (length dirs) interp)
      (let ([args (append (list "--libdirs" (path-list dirs))
                          (if (null? natives) '() (list (make-repl-preamble root natives))))])
        (run-foreground interp args))))

  ;; 运行时:--runtime > CHANDLER_RUNTIME > manifest 声明 skiff-only > 跟随 chandler 当前所在
  (define (repl-interp root flags)
    ;; 同 choose-interp 的优先级,末位再兜一层「跟随 chandler 当前所在运行时」
    (cond
      [(eq? 'skiff (interp-kind root flags)) (skiff-exe)]
      [(flag flags 'runtime)                 (chez-exe)]   ; 显式 --runtime chez
      [(preferred-runtime)                   (chez-exe)]   ; 显式 CHANDLER_RUNTIME=chez
      [(eq? 'skiff (current-runtime))        (skiff-exe)]
      [else                                  (chez-exe)]))

  ;; native 预载 preamble(仅项目有 native 时):加载各 .so 后落入 REPL
  (define (make-repl-preamble root natives)
    (let ([tmp (join-paths root ".chandler-repl.ss")])
      (call-with-output-file tmp
        (lambda (p)
          (for-each (lambda (so)
                      (when (file-exists? so) (fprintf p "(load-shared-object ~s)~%" so)))
                    natives))
        'truncate)
      tmp))

  ;; 选解释器(designs/06 §3)。**优先级**(run/exec/repl/启动器一致):
  ;;   --runtime 旗标 > CHANDLER_RUNTIME 环境变量 > manifest 声明 > 默认
  ;; 「哪一种」由上式定;「哪个可执行文件」由 CHANDLER_SKIFF / CHANDLER_SCHEME 定(名或路径)。
  (define (choose-interp root flags)
    (case (interp-kind root flags)
      [(skiff) (skiff-exe)]
      [else    (chez-exe)]))

  (define (skiff-exe) (or (getenv* "CHANDLER_SKIFF") "skiff"))
  (define (chez-exe)  (or (getenv* "CHANDLER_SCHEME") "scheme"))

  (define (interp-kind root flags)
    (let ([rt (flag flags 'runtime)])
      (cond
        [(equal? rt "skiff") 'skiff]
        [(equal? rt "chez") 'chez]
        [(preferred-runtime)]                          ; CHANDLER_RUNTIME=skiff|chez
        [else                                          ; 依 manifest:仅 skiff → skiff
         (let ([mpath (join-paths root "manifest.ss")])
           (if (file-exists? mpath)
               (let ([mf (read-manifest mpath)])
                 (if (and (manifest-skiff mf) (not (manifest-chez mf))) 'skiff 'chez))
               'chez))])))

  ;; 生成 preamble 临时脚本:先 load 各 native,再 load 目标脚本
  (define (make-preamble root natives script-abs)
    (let ([tmp (string-append root "/.chandler-run.ss")])
      (call-with-output-file tmp
        (lambda (p)
          (for-each (lambda (so)
                      (when (file-exists? so)
                        (fprintf p "(load-shared-object ~s)~%" so)))
                    natives)
          (fprintf p "(load ~s)~%" script-abs))
        'truncate)
      tmp))

  ;; 库搜索条目 → --libdirs / CHEZSCHEMELIBDIRS 串(pair 条目 → "src::obj",见 layout)
  (define (path-list dirs) (libdirs->arg dirs))

  (define (abspath root p)
    (if (string-prefix? "/" p) p (join-paths root p)))

  (define (short rev)
    (if (and (string? rev) (>= (string-length rev) 10)) (substring rev 0 10) rev))

  ;; ── .gitignore / scaffold / basename(init 用)──
  ;; 忽略 chandler 生成物:vendor/(依赖 checkout)、lib/(bake 装的)、chandler-setup.ss、临时文件
  ;; chandler/bake 生成物:依赖 checkout(vendor/)、装好的库前缀(lib/)、setup、
  ;; 各临时 recipe/preamble,以及 `chandler build` 经 bake 产出的 _build/。
  ;; 注:`.chandler-approvals`(native 构建授权记录)**不**入此列——它是信任决定,
  ;; 提交与否属项目策略(提交=团队共享授权;不提交=各人各自授权),由用户自决。
  (define gitignore-entries '("/vendor/" "/lib/" "/_build/" "chandler-setup.ss"
                              ".chandler-run.ss" ".chandler-repl.ss"
                              ".chandler-install.ss" ".chandler-build.ss"))
  (define (ensure-gitignore-lib root)
    (let* ([gi (join-paths root ".gitignore")]
           [lines (read-lines gi)]              ; fs.read-lines:文件缺失 → '()
           [have (map string-trim lines)]
           [missing (filter (lambda (e) (not (member e have))) gitignore-entries)])
      (unless (null? missing)
        (call-with-output-file gi
          (lambda (p)
            (for-each (lambda (l) (display l p) (newline p)) lines)
            (for-each (lambda (e) (display e p) (newline p)) missing))
          'truncate))))

  (define (scaffold-lib root name)
    (let ([umbrella (join-paths root (string-append name ".ss"))]
          [subdir (join-paths root name)])
      (unless (file-exists? umbrella)
        (call-with-output-file umbrella
          (lambda (p)
            (display "#!chezscheme\n" p)
            (fprintf p ";;; ~a.ss --- umbrella facade\n\n" name)
            (fprintf p "(library (~a)\n  (export)\n  (import (chezscheme)))\n" name))
          'truncate))
      (unless (file-exists? subdir) (mkdir subdir))))

  ;; 目录路径 → 末段名(默认 "app");通用 FS/字符串来自 fs/util
  (define (basename p)
    (let ([parts (filter (lambda (s) (> (string-length s) 0)) (string-split p #\/))])
      (if (null? parts) "app" (list-ref parts (- (length parts) 1))))))
