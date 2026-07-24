#!chezscheme
;;; chandler/cli/commands.ss --- 各子命令实现(designs/01)
;;;
;;; 命令函数取 (root flags),返回退出码(sysexits 风格,见 main.ss)。
;;; 依赖获取/物化归 (chandler install);解析归 (chandler resolve)。

(library (chandler cli commands)
  (export cmd-init cmd-deps cmd-install cmd-add cmd-remove cmd-run cmd-env cmd-repl
          cmd-build cmd-pack cmd-verify-pack
          cmd-uninstall-global cmd-doctor
          cmd-deps-list cmd-deps-tree
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
          (only (chandler compile) compiler-available?)
          (chandler pack)
          (chandler env)
          (only (chandler recipe) default-tasks-file)   ; 只取文件名常量,避开 task/file/run 等宏
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
      (printf "wrote ~a~%" mpath)
      ;; 与 manifest.ss(数据)配对的 chandler-tasks.ss(程序):跑自定义任务。
      ;; 编译入口 = app 的 entry 或 lib 的 (name)。
      (write-tasks-file! root name (or entry (list (string->symbol name))) (flag? flags 'force))
      (ensure-gitignore-lib root)
      (write-dotenv-skeleton! root)
      (when lib? (scaffold-lib root name))
      0))

  ;; .env 骨架(C6):run/repl/env 消费(build/deps/install 不碰,保可复现)。
  ;; 已存在则不覆盖。只写注释 + 说明,不给假变量(避免误导)。
  (define (write-dotenv-skeleton! root)
    (let ([epath (join-paths root ".env")])
      (unless (file-exists? epath)
        (write-text epath
          (string-append
            "# chandler .env — consumed by `chandler run`/`repl`/`env` ONLY.\n"
            "# NOT read by build/deps/install (reproducibility).\n"
            "# Syntax: KEY=value  |  # comment  |  optional `export ` prefix\n"
            "# Quoting: 'literal'  \"\\\\n \\\\t escapes\"  bare (trailing ws trimmed)\n"
            "# Expansion: ${VAR} (earlier entries then process env then empty)\n")))))

  ;; 生成 chandler-tasks.ss(由 chandler make 消费)。它是**可选的**——chandler build
  ;; 已能从 manifest 推导编译;留它是给你写 test / release 之类自定义任务的地儿。
  ;; 已存在则不覆盖(除非 --force),免得抹掉你手写的任务。
  (define (write-tasks-file! root name build-lib force?)
    (let ([tpath (join-paths root default-tasks-file)]
          [libref (string-append "(" (string-join (map symbol->string build-lib) " ") ")")])
      (when (or (not (file-exists? tpath)) force?)
        (write-text tpath
          (string-append
            "#!chezscheme\n"
            ";;; " default-tasks-file " --- " name " 的构建/任务描述(chandler make 消费)\n"
            ";;;\n"
            ";;; **可选**:chandler build 会从 manifest.ss 推导编译,不需要本文件。\n"
            ";;; 留它是为了写自定义任务(如 test)。task/file/rule/default-task 是 DSL,\n"
            ";;; 加载即求值——它是程序,与数据文件 manifest.ss 配对。\n"
            "\n"
            "(define-lib-roots \".\")\n"
            "\n"
            ";; build:编译 " libref " 及其 import 闭包(与 `chandler build` 等价,可删)\n"
            "(library-task 'build '" libref ")\n"
            "\n"
            ";; test:跑测试(改成你的测试命令)\n"
            "(task 'test \"run the test suite\"\n"
            "  '()\n"
            "  (lambda ()\n"
            "    (run \"scheme\" \"--libdirs\" \".\" \"--program\" \"tests/run-tests.sps\")))\n"
            "\n"
            "(default-task 'build)\n"))
        (printf "wrote ~a~%" tpath))))

  ;; chandler 是**运行时门**,与 (chez …)/(skiff …) 同类:只声明版本区间,不声明
  ;; 来源 —— 实体是全局前缀里装好的那一份,`chandler deps` 校验版本并把它的 runtime
  ;; 子集铺进 vendor/ 与 lib/(designs/12 §5)。故模板写区间,不写 URL/path。
  ;; 区间取「当前这个 chandler 的次版本兼容」:装得比它旧就该报错。
  (define (chandler-gate-range)
    (string-append ">=" chandler-version))

  (define (skeleton-manifest-datum name)
    `(manifest (format 1) (name ,name) (version "0.1.0") (chez ">=10.0")
       (chandler ,(chandler-gate-range)) (srcdir ".")
       (deps)))

  ;; app 形态:多一个 (app (entry …) (main …)) 字段。entry 是 symbol list(库名),
  ;; main 是 symbol(入口过程名)。这两个就是 pack 的入口契约 —— 声明了就能 pack,
  ;; 没声明(走 skeleton-manifest-datum)就是 lib,pack 会拒绝。
  (define (skeleton-app-manifest-datum name entry main)
    `(manifest (format 1) (name ,name) (version "0.1.0") (chez ">=10.0")
       (chandler ,(chandler-gate-range)) (srcdir ".")
       (deps)
       (app (entry ,entry) (main ,main))))

  ;; ── deps:resolve + vendor + install source(合并旧 install + update)──

  ;; N5:项目是否声明了 chandler 运行时门;缺则 warning(--strict 则拒绝)。
  ;; 声明形式是 (chandler ">=X"),**不是** (deps (chandler …)) —— 它没有来源可 fetch,
  ;; 实体来自全局前缀(designs/12 §5)。自举例外:项目名 = "chandler"。
  (define (check-chandler-dep root flags)
    (let ([mpath (join-paths root "manifest.ss")])
      (if (not (file-exists? mpath))
          #t
          (let ([mf (read-manifest mpath)])
            (cond
              [(string=? (or (manifest-name mf) "") "chandler") #t]
              [(manifest-chandler mf) #t]
              [(flag? flags 'strict)
               (fprintf (current-error-port)
                 "chandler: project does not declare a chandler runtime gate; add (chandler \">=~a\") to manifest.ss\n"
                 chandler-version)
               #f]
              [else
               (fprintf (current-error-port)
                 "warning: project does not declare a chandler runtime gate; add (chandler \">=~a\") to manifest.ss\n"
                 chandler-version)
               #t])))))

  ;; --global:装当前项目库树到全局 libdir(注册表事务,designs/05)
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

  (define (cmd-deps root flags)
    (cond
      [(flag? flags 'list)  (cmd-deps-list root flags)]
      [(flag? flags 'tree)  (cmd-deps-tree root flags)]
      [(flag? flags 'global) (cmd-install-global root flags)]
      [else
       (if (check-chandler-dep root flags)
           (let ([rc (install root (list (cons 'production (flag? flags 'production))
                                         (cons 'force (flag? flags 'force))
                                         (cons 'keep-extra (flag? flags 'keep-extra))
                                         (cons 'offline (flag? flags 'offline))
                                         (cons 'update (flag? flags 'update))))])
             ;; BUG-1(2026-07-24):deps 期就地编译 chandler runtime 子集进
             ;; _vendor/chandler/_build/<mt>/。build 与 pack 都从此处取对象 → 实例一致,
             ;; pack 出的包不再报 "different compilation instance"。Petite 无编译器则跳过
             ;; (只铺源码;pack 本就需要编译器,Petite 打不出包)。
             (when (and (= rc 0)
                        (compiler-available?)
                        (project-has-chandler-gate? root))
               (build-chandler-runtime! root))
             rc)
           65)]))

  ;; manifest 是否声明了 (chandler …) 运行时门
  (define (project-has-chandler-gate? root)
    (let ([mpath (join-paths root "manifest.ss")])
      (and (file-exists? mpath)
           (manifest-chandler (read-manifest mpath))
           #t)))

  ;; ── P3:app install 生成命令行入口(本机运行时,不打包 binary/boot)──
  ;; runner: <libdir>/.chandler/<name>/run.sps — 极简程序(import entry + 调 main)。
  ;; launcher: <bindir>/<name>(POSIX sh) / <bindir>/<name>.ps1(Windows)— 本机运行时
  ;; 发现(skiff 优先) + 挂全局前缀 src::<mt> 对 + --program runner。
  ;; 对称于 chandler 自己的启动器(bootstrap.ss 生成的,也是"本机运行时 + 挂前缀"模式)。
  ;; 方案 A:launcher 模板在此重写一份,不提取 bootstrap.ss 的(保其自含红线,designs/08)。

  (define (app-launcher-sh name libdir mt)
    (string-append
      "#!/bin/sh\n"
      "# " name " launcher — generated by chandler install; do not edit.\n"
      "# Uses the local Scheme runtime (skiff preferred); mounts the install prefix.\n"
      "PREFIX=\"" libdir "\"\n"
      "MT=\"" mt "\"\n"
      "RUNNER=\"$PREFIX/.chandler/" name "/run.sps\"\n"
      "case \"${CHANDLER_RUNTIME:-}\" in\n"
      "  skiff) _rt=\"${CHANDLER_SKIFF:-skiff}\" ;;\n"
      "  chez)  _rt=\"${CHANDLER_SCHEME:-scheme}\" ;;\n"
      "  \"\")    for _c in skiff scheme chez; do\n"
      "            command -v \"$_c\" >/dev/null 2>&1 && { _rt=\"$_c\"; break; } \\\n"
      "          done ;;\n"
      "  *) echo \"" name ": invalid CHANDLER_RUNTIME (want: skiff|chez)\" 1>&2; exit 64 ;;\n"
      "esac\n"
      "[ -z \"$_rt\" ] && { echo \"" name ": no Scheme runtime found (install skiff or Chez Scheme)\" 1>&2; exit 127; }\n"
      "[ ! -f \"$RUNNER\" ] && { echo \"" name ": install broken — $RUNNER missing (reinstall with chandler install)\" 1>&2; exit 70; }\n"
      "exec \"$_rt\" -q --libdirs \"$PREFIX/src::$PREFIX/$MT\" --program \"$RUNNER\" \"$@\"\n"))

  (define (app-launcher-ps1 name libdir mt)
    (string-append
      "#!/usr/bin/env pwsh\n"
      "# " name " launcher — generated by chandler install; do not edit.\n"
      "$ErrorActionPreference = 'Continue'\n"
      "$AppArgs = $args\n"
      "$Prefix = '" libdir "'\n"
      "$Mt = '" mt "'\n"
      "$Runner = \"$Prefix/.chandler/" name "/run.sps\"\n"
      "$Sep = [System.IO.Path]::PathSeparator\n"
      "$LibDirs = \"$Prefix/src$Sep$Sep$Prefix/$Mt\"\n"
      "switch ($env:CHANDLER_RUNTIME) {\n"
      "  'skiff' { $rt = if ($env:CHANDLER_SKIFF) { $env:CHANDLER_SKIFF } else { 'skiff' } }\n"
      "  'chez'  { $rt = if ($env:CHANDLER_SCHEME) { $env:CHANDLER_SCHEME } else { 'scheme' } }\n"
      "  ''      { foreach ($c in @('skiff','scheme','chez')) { if (Get-Command $c -ErrorAction SilentlyContinue) { $rt = $c; break } } }\n"
      "  $null   { foreach ($c in @('skiff','scheme','chez')) { if (Get-Command $c -ErrorAction SilentlyContinue) { $rt = $c; break } } }\n"
      "  default { [Console]::Error.WriteLine(\"" name ": invalid CHANDLER_RUNTIME (want: skiff|chez)\"); exit 64 }\n"
      "}\n"
      "if (-not $rt) { [Console]::Error.WriteLine(\"" name ": no Scheme runtime found\"); exit 127 }\n"
      "if (-not (Test-Path -LiteralPath $Runner)) { [Console]::Error.WriteLine(\"" name ": install broken — $Runner missing\"); exit 70 }\n"
      "& $rt -q --libdirs $LibDirs --program $Runner @AppArgs\n"
      "exit $LASTEXITCODE\n"))

  (define (write-app-launcher! name entry main libdir bindir)
    (let* ([mt (current-machine-type)]
           [win? (windows-mt? mt)]
           [runner-dir (join-paths libdir ".chandler" name)]
           [entry-str (string-join (map symbol->string entry) " ")])
      ;; runner:极简程序(import entry + 调 main)。pack 的 bootstrap.ss 末尾同构,
      ;; 但无 target 校验(pack 独有,install 环境已知)、无 native 预扫(build 生成的
      ;; native-loader 自加载)。(chezscheme) 给 --program 模式下的 cdr/command-line。
      (ensure-dir runner-dir)
      (write-text (join-paths runner-dir "run.sps")
        (string-append "(import (chezscheme) (" entry-str "))\n"
                       "(" (symbol->string main) " (cdr (command-line)))\n"))
      ;; launcher:本机运行时发现 + 挂前缀对 + 跑 runner
      (ensure-dir bindir)
      (if win?
          (write-text (join-paths bindir (string-append name ".ps1"))
            (app-launcher-ps1 name libdir mt))
          (let ([f (join-paths bindir name)])
            (write-text f (app-launcher-sh name libdir mt))
            (run-status "chmod" (list "+x" f) '())))
      (printf "installed command '~a' to ~a~%" name bindir)))

  (define (remove-app-launcher! name bindir)
    ;; 删 launcher(sh 和 .ps1 都试,防跨平台残留)。runner 在 .chandler/<name>/,
    ;; 由 cmd-uninstall 删整个 .chandler/<name>/ 时一并清。
    (let ([sh (join-paths bindir name)]
          [ps1 (join-paths bindir (string-append name ".ps1"))])
      (when (file-exists? sh) (delete-file sh))
      (when (file-exists? ps1) (delete-file ps1))))

  ;; ── install:安装 lib + 依赖 + resources + manifest 到全局前缀 ──
  (define (cmd-install root flags)
    (let* ([libdir (target-libdir flags)]
           [mpath (join-paths root "manifest.ss")]
           [mf (and (file-exists? mpath) (read-manifest mpath))])
      (unless mf (error 'install "manifest.ss not found; run `chandler init` first"))
      (let ([name (or (manifest-name mf) (basename root))]
            [version (or (manifest-version mf) "0.0.0")])
        ;; 前置:deps + build 必须已完成
        (unless (file-exists? (project-lock-path root))
          (error 'install "manifest.lock not found; run `chandler deps` first"))
        ;; 1. 安装项目自身(经 registry:冲突检测 + hash 追踪 + 清卸)
        (let* ([meta (list name version `(path ,root) (now-iso) 'chandler)]
               [opts (list (cons 'adopt (flag? flags 'adopt))
                           (cons 'force (flag? flags 'force)))])
          (install-global root libdir meta opts))
        ;; 2. 合并依赖源码 + 编译产物 + 资源(从 lib/ → 全局前缀)
        (merge-lib-to-global! root libdir)
        ;; 3. 安装项目自身 resources(manifest 声明的)
        (install-project-resources! root mf libdir)
        ;; 4. 安装 manifest 到 .chandler/<name>/manifest.ss
        (let ([manifest-dir (join-paths libdir ".chandler" name)])
          (ensure-dir manifest-dir)
          (copy-file mpath (join-paths manifest-dir "manifest.ss")))
        ;; 5. P3:app 生成命令行入口(runner + launcher),用本机运行时
        (let ([app (manifest-app mf)])
          (when app
            (write-app-launcher! name (app-entry app) (app-main app)
                                 libdir (target-bindir flags))))
        (printf "installed ~a ~a + dependencies to ~a~%" name version libdir)
        0)))

  ;; 把各依赖装进全局前缀(合并,不覆盖同名)。C0:来源是**每个依赖自己的树**,
  ;; 不再有汇总的 lib/。一个依赖贡献三样,恰好对应前缀的两层:
  ;;   <src-root>/**(除 _build/、.git/)  → <prefix>/src/     源码 + resources/<ns>/
  ;;   <src-root>/_build/<mt>/**          → <prefix>/<mt>/    编译对象 + native
  ;; **资源不必单独搬**:它在源码树里就住在 `resources/<ns>/`,而前缀要的是
  ;; `src/resources/<ns>/` —— 拷源码树时自动就位(C4 选这个落点的收益之一)。
  (define (merge-lib-to-global! root libdir)
    (let ([mt (current-machine-type)]
          [all (lambda (_) #t)])   ; 源码/对象全拷(对象层暂无 ext 过滤;registry 按包兜)
      (for-each
        (lambda (d)
          (let* ([src-root (srcdir-join (vendor-dir root (locked-dep-name d))
                                        (or (locked-dep-srcdir d) "."))]
                 [obj (join-paths src-root "_build" mt)])
            ;; P7:改调共享 copy-tree!。累积前缀 → skip-existing + warn。
            ;; 别包拥有的文件由 registry check-conflicts 兜硬错;warn 抓依赖间同名悄悄丢。
            (copy-tree! src-root (join-paths libdir "src") '("_build" ".git") all 'skip-existing #t)
            (copy-tree! obj (join-paths libdir mt) '() all 'skip-existing #t)))
        (project-locked-deps root))))

  (define (project-locked-deps root)
    (let ([lpath (project-lock-path root)])
      (if (file-exists? lpath) (lock-deps (read-lock lpath)) '())))

  ;; 安装项目自身的 resources(manifest 的 (resources ...) 声明)
  (define (install-project-resources! root mf libdir)
    (let ([resources (manifest-resources mf)]
          [name (manifest-name mf)])
      (when resources
        (for-each
          (lambda (entry)
            (let* ([libref (car entry)]
                   [rel-path (cdr entry)]
                   [src-dir (join-paths root rel-path)]
                   [libpath (string-join (map symbol->string libref) "/")]
                   [dst-dir (prefix-resource-dir libdir libpath)])
              (when (file-directory? src-dir)
                (ensure-dir dst-dir)
                (let ([pre (string-append src-dir "/")])
                  (for-each
                    (lambda (abs)
                      (let* ([rel (strip-prefix abs pre)]
                             [dst (join-paths dst-dir rel)])
                        (ensure-parent dst)
                        (copy-file abs dst)))
                    (files-under src-dir))))))
          resources))))

  ;; uninstall 只操作全局前缀(无本地卸载一说),故不再强制 --global —— 直接卸载。
  (define (cmd-uninstall-global root flags)
    (let ([libdir (target-libdir flags)]
          [name (flag flags 'name)])
      (unless name (error 'uninstall "usage: chandler uninstall --name=<name> [--prefix=DIR|--system]"))
      (uninstall-global name libdir (list (cons 'keep-modified (flag? flags 'keep-modified))))
      ;; P3:删 app launcher + .chandler/<name>/(runner + manifest 快照;不经 registry,须单独清)
      (remove-app-launcher! name (target-bindir flags))
      (let ([snap (join-paths libdir ".chandler" name)])
        (when (file-directory? snap) (rm-rf snap)))
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

  ;; install/uninstall/doctor 的**安装落点**:`--prefix=DIR` / `--user`(默认)/ `--system`。
  ;;   --prefix=DIR → 任意目录(测试/隔离/自定义前缀)
  ;;   --user       → ~/.local/share/chez(POSIX)/ %LOCALAPPDATA%\chez(Windows)
  ;;   --system     → /usr/local/share/chez(POSIX)/ %ProgramData%\chez(Windows)
  ;; 优先级:--prefix > --system > --user。--prefix 早就在 args.ss 的 value-long 声明,
  ;; 但这里原先没接(P7 验证时发现:`install --prefix=/x` 实际装默认前缀)。
  ;; 注意:这是"装到哪",与 CHANDLER_HOME("我从哪跑")是两回事,常见情形重合。
  (define (target-libdir flags)
    (cond
      [(flag flags 'prefix) => values]              ; --prefix=DIR
      [(flag? flags 'system) (default-system-libdir)]
      [else (default-user-libdir)]))

  ;; P3:app launcher 落点(命令行入口,PATH 上)。
  ;; --prefix=DIR → <prefix>/bin(测试隔离,与前缀同根);否则平台惯例 bin 目录。
  (define (target-bindir flags)
    (cond
      [(flag flags 'prefix) => (lambda (p) (join-paths p "bin"))]
      [(flag? flags 'system) (default-system-bindir)]
      [else (default-user-bindir)]))

  ;; ISO-ish 时间戳(installed-at,纯记录)
  (define (now-iso)
    (let ([t (current-date)])
      (format "~a-~a-~aT~a:~a:~a"
              (date-year t) (pad2 (date-month t)) (pad2 (date-day t))
              (pad2 (date-hour t)) (pad2 (date-minute t)) (pad2 (date-second t)))))
  (define (pad2 n) (if (< n 10) (format "0~a" n) (format "~a" n)))

  ;; ── build:编译依赖闭包 + 当前项目 ──
  ;; 1. 依赖:bake build-all per dep → chandler lay out to lib/<mt>/
  ;; 2. 项目:有 chandler-tasks.ss 跑它的 default-task,否则从 manifest 推导
  (define (cmd-build root flags)
    (let ([verbose? (flag? flags 'verbose)])
      (build root (list (cons 'allow-build (flag flags 'allow-build))
                        (cons 'production (flag? flags 'production))
                        (cons 'verbose verbose?)))
      ;; 编译项目自身:有 chandler-tasks.ss 就跑它的 default-task,没有就从 manifest 推导。
      ;; 进程内编译(P6 阶段 B6)—— 不再 spawn bake。
      (printf "build: compiling project...~%")
      (build-project root verbose?))
    0)

  ;; ── .env 收集(C3)──
  ;; 项目根 <root>/.env,再叠加 --env-file <path>(显式指定,后到者同键覆盖)。
  ;; 依赖树里的 .env 一概不读(见 (chandler env) 头注:信任模型)。返回有序 alist。
  (define (collect-dotenv root flags)
    (let* ([base (read-dotenv (dotenv-file-path root))]
           [extra (let ([f (flag flags 'env-file)])
                    (if (string? f)
                        (read-dotenv (if (string-prefix? "/" f) f (join-paths root f)))
                        '()))])
      (append base extra)))

  ;; .env 覆盖进程环境 —— 故在传给子进程的 env alist 里排在**最后**(env-prefix
  ;; 是 shell 变量前缀,同名后者胜)。chandler 自己交接的 APP_ROOT 等排在前面。
  (define (env-with-dotenv root flags base-env)
    (append base-env (collect-dotenv root flags)))

  ;; ── env:输出依赖环境变量(eval "$(chandler env)")──
  ;;   两个变量:库搜索路径,以及 APP_ROOT(库前缀 —— 资源与 native 都挂它下面)。
  (define (cmd-env root flags)
    (let ([dirs (resolved-libdirs root)])
      (printf "export CHEZSCHEMELIBDIRS=\"~a\"~%" (libdirs->arg dirs))
      (let ([e (app-root-env root)])
        (unless (null? e) (printf "export APP_ROOT=\"~a\"~%" (cdar e))))
      ;; .env(C3):覆盖式,故放在最后 export —— 后 export 的值在 eval 后生效。
      (for-each (lambda (kv) (printf "export ~a=~a~%" (car kv) (shell-quote (cdr kv))))
                (collect-dotenv root flags))
      0))

  ;; ── deps --list / deps --tree ──
  (define (cmd-deps-list root flags)
    (if (flag? flags 'global)
        (let ([rows (list-global (target-libdir flags))])
          (if (null? rows)
              (printf "(no packages installed in the global library prefix)~%")
              (for-each (lambda (r) (printf "~a  ~a  [~a]~%" (car r) (cadr r) (caddr r))) rows))
          0)
        (let ([rows (list-deps root)])
          (if (null? rows)
              (printf "(no locked dependencies; run `chandler deps` first)~%")
              (for-each
                (lambda (r)
                  (printf "~a  ~a  ~a~a~%"
                          (car r) (cadr r) (caddr r)
                          (if (eq? 'dev (cadddr r)) "  [dev]" "")))
                rows))
          0)))

  (define (cmd-deps-tree root flags)
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

  ;; ── run:库搜索路径 + APP_ROOT + 载 native + 跑脚本(设计同 repl)──
  ;; chandler run --script <target.ss> [args...]
  (define (cmd-run root flags positionals rest)
    (let ([script (or (flag flags 'script)
                      (and (pair? positionals) (car positionals)))])
      (unless script (error 'run "usage: chandler run --script <script.ss> [args...]"))
      (let* ([dirs (resolved-libdirs root)]
             [natives (native-load-paths root)]
             [preamble (make-preamble root natives (abspath root script))]
             [interp (choose-interp root flags)]
             ;; 脚本参数 = `--` 之后的一切 + 剩余位置参数(脚本名若来自位置参数则剥掉它)。
             ;; `--script` 形式下位置参数同样是脚本的:`chandler run --script serve.ss 8099`
             ;; 里那个端口必须传下去,否则应用静默地拿默认值跑。
             [script-args (append (or rest '())
                                  (if (flag flags 'script)
                                      positionals
                                      (if (pair? positionals) (cdr positionals) '())))])
        (run-foreground interp
                        (append (list "-q" "--libdirs" (path-list dirs)
                                      "--script" preamble)
                                script-args)
                        (list (cons 'env (env-with-dotenv root flags (app-root-env root))))))))

  ;; **dev 期不设 APP_ROOT**(C0,2026-07-24)。
  ;;
  ;; 它现在只服务生成的 native-loader 的候选 1(`$APP_ROOT/<mt>/<libpath>/native/`)。
  ;; 而 C0 之后 dev 期的 native 分散在各 `_vendor/<dep>/<srcdir>/_build/<mt>/` 里,
  ;; **没有单一前缀能覆盖** —— 硬造一个只会让候选 1 恒 miss,等于留一条永远走不通的
  ;; 分支。loader 的候选 2(扫 `(library-directories)` 各条目的 obj 侧)恰好命中:
  ;; per-dep 对的 obj 侧正是 native 落点。资源定位(C1)同理已不读它。
  ;;
  ;; pack **仍然设**:那里 APP_ROOT 指向一个真前缀,且 boot / 全程序模式下
  ;; library-directories 未必已设(designs/24 §约束 3),env 是唯一时序对得上的交接。
  ;;
  ;; 外层已显式设了就原样透传(用户或 pack 启动器先到且权威),否则一个都不加。
  (define (app-root-env root)
    (let ([v (getenv* "APP_ROOT")])
      (if v (list (cons "APP_ROOT" v)) '())))

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
        (run-foreground interp args
                        (list (cons 'env (env-with-dotenv root flags (app-root-env root))))))))

  ;; 运行时:--runtime > CHANDLER_RUNTIME > manifest 声明 skiff-only > 跟随 chandler 当前所在
  ;; repl 与 run/exec 同一套(interp-kind 已把"跟随当前运行时"的兜底内置进默认分支)。
  (define (repl-interp root flags) (choose-interp root flags))

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

  ;; 选运行时**种类**(designs/06 §3)。优先级(run/exec/repl/启动器一致):
  ;;   --runtime > CHANDLER_RUNTIME > manifest(明确 chez-only→chez / skiff-only→skiff)
  ;;   > 默认:跟随 chandler 当前所在运行时
  ;;
  ;; **默认 skiff 就落在最后一条**:chandler 的启动器已 skiff 优先、无 skiff 才回退
  ;; chez,故"当前所在"天然就是"能用 skiff 就 skiff、否则 chez"——不用再单独探测
  ;; 可用性,也就不会"默认成一个没装的 skiff 然后 127"。**显式**(--runtime /
  ;; CHANDLER_RUNTIME / skiff-only manifest)则照单执行,找不到即 127,不回退。
  (define (interp-kind root flags)
    (let ([rt (flag flags 'runtime)])
      (cond
        [(equal? rt "skiff") 'skiff]
        [(equal? rt "chez") 'chez]
        [(preferred-runtime)]                          ; CHANDLER_RUNTIME=skiff|chez
        [else
         (let ([mpath (join-paths root "manifest.ss")])
           (if (file-exists? mpath)
               (let ([mf (read-manifest mpath)])
                 (cond
                   [(and (manifest-chez mf) (not (manifest-skiff mf))) 'chez]   ; 明确 chez-only
                   [(and (manifest-skiff mf) (not (manifest-chez mf))) 'skiff]  ; 明确 skiff-only
                   [else (current-runtime)]))           ; 双跑 / 未声明 → 跟随当前(默认 skiff)
               (current-runtime)))])))                  ; 无 manifest → 跟随当前

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
  ;; chandler/bake 生成物:依赖 checkout(vendor/)、装好的库前缀(lib/)、各临时
  ;; recipe/preamble,以及 `chandler build` 经 bake 产出的 _build/。
  ;; 注:`.chandler-approvals`(native 构建授权记录)**不**入此列——它是信任决定,
  ;; 提交与否属项目策略(提交=团队共享授权;不提交=各人各自授权),由用户自决。
  ;; `.chandler-build.ss` / `.chandler-install.ss` 是**已作废**的生成物:B6a 之后
  ;; build 直接在进程内排单编译,不再往依赖树里写临时 recipe 交给 bake 子进程。
  ;; 仍留在列表里 —— 老项目的 .gitignore 已经有这两行,删掉只会让它们变成噪声;
  ;; 新项目多两行无害。`.chandler-run.ss` / `.chandler-repl.ss` 仍在用(run/repl 的
  ;; native preamble)。
  (define gitignore-entries '("/vendor/" "/lib/" "/_build/"
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
