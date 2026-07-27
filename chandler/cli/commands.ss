#!chezscheme
;;; chandler/cli/commands.ss --- 各子命令实现(designs/01)
;;;
;;; 命令函数取 (root flags),返回退出码(sysexits 风格,见 main.ss)。
;;; 依赖获取/物化归 (chandler install);解析归 (chandler resolve)。

(library (chandler cli commands)
  (export cmd-init cmd-deps cmd-install cmd-add cmd-remove cmd-run cmd-env cmd-repl
          cmd-build cmd-pack cmd-verify-pack cmd-deps-tree cmd-verify cmd-exec
          cmd-uninstall-global cmd-doctor cmd-list cmd-switch cmd-test
          ;; 启动器模板:导出供测试**实跑**渲染结果(光比字符串证明不了
          ;; `IFS= read -r` 真能读出 sidecar)。C3 的 launcher parity 测试也要它们。
          app-launcher-sh app-launcher-ps1)
  (import (chezscheme)
          (chandler util)
          (chandler fs)
          (chandler proc)
          (chandler sexp)
          (chandler layout)
          (chandler manifest)
          (chandler lock)
          (chandler hash)
          (chandler version)
          (chandler install)
          (chandler registry)
          (chandler runtime-detector)
          (chandler build)
          (only (chandler compile) compiler-available?)
          (chandler pack)
          (chandler env)
          (only (chandler recipe) default-tasks-file)   ; 只取文件名常量,避开 task/file/run 等宏
          (chandler cli args)
          (chandler cli runtime-env))    ; choose-interp / make-preamble / collect-dotenv(共享于 cmd-run/cmd-test)

;; ── pack / verify-pack(designs/05)──
;; pack 只**组装**:应用编译树 + 依赖闭包(由 chandler build 进程内编译) + 随包运行时。
;; 缺件一律在前置校验里停下并说清该跑哪个命令 —— native 尤其无法在消费方现编。
  (define (cmd-pack root flags)
    (pack root
          (list (cons 'runtime (and (flag flags 'runtime) (string->symbol (flag flags 'runtime))))
                (cons 'out     (flag flags 'out))
                (cons 'name    (flag flags 'name))
                (cons 'version (flag flags 'version))
                (cons 'entry   (parse-entry (flag flags 'entry)))
                (cons 'main    (and (flag flags 'main) (string->symbol (flag flags 'main))))
                (cons 'lib     (flag? flags 'lib)))))

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
      (verify-pack (abspath root target)
                   (flag? flags 'target))))

  ;; ── verify:校验 _vendor/ 与 lock 一致(CI;纯只读,不写任何文件)──
  ;;
  ;; 两道检查,都过才 0:
  ;;
  ;;   ① **git 态**((chandler install) 的 verify):每个 git 依赖的 checkout 在不在、
  ;;      HEAD 是否正是 lock 记的 rev、工作区有没有脏改动。这是**当前真正生效**的那道,
  ;;      诊断也最可操作("rev mismatch: at X, lock says Y")。
  ;;      它此前已实现但没接进任何命令 —— 只有测试在调。
  ;;
  ;;   ② **内容哈希**(lock 的 `(files …)`,rel . sha256):MISSING / CHANGED / EXTRA。
  ;;      清单由 `chandler deps` 在铺完依赖后写入(D15 生产侧,见 (chandler install)
  ;;      的 record-vendor-files!),路径**相对项目根**(`_vendor/greet/greet.ss`)。
  ;;
  ;;      lock 没有 `(files …)` 时**跳过 ②**:v2 老 lock、以及 deps 尚未重跑过的
  ;;      工作副本都属于这种。此时空声明配上 EXTRA 扫描会把 `_vendor/` 下每个文件
  ;;      都判成「不在 lock 里」,给出一屏假失败 —— 不如只报 ① 的结论并提示重跑 deps。
  ;;
  ;; EXTRA 扫描排除 `.git/` 与 `_build/`,与生产侧 vendor-unmanaged-path? 同一规则:
  ;; 前者是 checkout 自带的仓库元数据,后者是 `chandler build` 的产物(deps 写清单时
  ;; 还不存在)。两侧的排除规则必须一致,否则 build 之后 verify 立刻假失败。
  ;;
  ;; hash 算法与 verify-pack 同一份((chandler hash) sha256-file)。
  (define (cmd-verify root flags)
    (let ([lpath (project-lock-path root)])
      (unless (file-exists? lpath)
        (error 'verify "lock not found; run `chandler deps` first"))
      (let* ([declared (lock-files (read-lock lpath))]
             [git-ok?  (verify root)]                        ; ① git 态
             [files-bad (verify-declared-files root declared)])   ; ② 内容哈希
        (cond
          [(or (not git-ok?) (> files-bad 0))
           (when (> files-bad 0)
             (eprintf
                      "verify: ~a ~a out of sync with lock; run `chandler deps`~%"
                      files-bad (plural files-bad "file" "files")))
           65]
          [else
           (if (null? declared)
               (printf "verify: git revs clean; lock has no (files ...) -- re-run `chandler deps` to record file hashes~%")
               (printf "verify: _vendor/ matches lock (git revs clean; ~a ~a hashed)~%"
                       (length declared) (plural (length declared) "file" "files")))
           0]))))

  ;; lock 的 (files …) 与盘上内容比对,返回不一致条数。declared 为空 → 0(不比,见上)。
  (define (verify-declared-files root declared)
    (if (null? declared)
        0
        (let ([bad 0]
              ;; rel → #t 索引:EXTRA 检查要对 _vendor/ 下**每个**文件查一次
              ;;「lock 里声明过没有」,拿 assoc 线性扫 declared 就是 N×M。
              [declared-index (let ([h (make-hashtable string-hash string=?)])
                                (for-each (lambda (f) (hashtable-set! h (car f) #t)) declared)
                                h)])
          (for-each
            (lambda (f)
              (let* ([rel (car f)]
                     [abs (join-paths root rel)])
                (cond
                  [(not (file-exists? abs))
                   (set! bad (+ bad 1))
                   (eprintf "  MISSING ~a~%" rel)]
                  [(not (string=? (cdr f) (sha256-file abs)))
                   (set! bad (+ bad 1))
                   (eprintf "  CHANGED ~a (sha256 mismatch)~%" rel)])))
            declared)
          (let ([vdir (join-paths root "_vendor")])
            (when (file-directory? vdir)
              (for-each
                (lambda (abs)
                  (let ([rel (relativize root abs)])
                    (unless (or (unmanaged-path? rel)
                                (hashtable-ref declared-index rel #f))
                      (set! bad (+ bad 1))
                      (eprintf "  EXTRA ~a (not in lock)~%" rel))))
                (files-under vdir))))
          bad)))

  ;; ── init ──
  ;; --lib:  显式声明这是 lib(顺带按[库布局规范]出目录骨架)
  ;; --app:  显式声明这是 app(写 (app (entry …)) 到 manifest);默认 entry = (name),--entry 覆盖
  ;; --lib / --app 互斥;都不传 = 默认 lib(无 (app …))
  (define (cmd-init root flags)
    (let* ([name (or (flag flags 'name) (basename root))]
           [mpath (project-manifest-path root)]
           [lib?  (flag? flags 'lib)]
           [app?  (flag? flags 'app)]
           [entry (or (parse-entry (flag flags 'entry))
                      (and app? (list (string->symbol name))))]
           [main  (or (and (flag flags 'main) (string->symbol (flag flags 'main))) 'main)])
      (when (and lib? app?)
        (error 'init "--lib and --app are mutually exclusive"))
      (when (and (file-exists? mpath) (not (flag? flags 'force)))
        (error 'init "chandler-manifest.ss already exists; use --force to overwrite" mpath))
      (write-canonical-file mpath
        (if app?
            (skeleton-app-manifest-datum name entry main)
            (skeleton-manifest-datum name)))
      (printf "wrote ~a~%" mpath)
      ;; 与 chandler-manifest.ss(数据)配对的 chandler-tasks.ss(程序):跑自定义任务。
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
  ;; 已能从 manifest 推导编译;留它是给你写自定义任务的地儿(v3 起默认只装 'build)。
  ;; 已存在则不覆盖(除非 --force),免得抹掉你手写的任务。
  ;; 注:跑测试用 `chandler test`(顶层命令,挂全运行时环境:.env + .env.tests +
  ;; resolved libdirs + native preamble);若你仍想用 `chandler make test`,在本
  ;; 文件里手写 (task 'test ...) 即可。
  (define (write-tasks-file! root name build-lib force?)
    (let ([tpath (join-paths root default-tasks-file)]
          [libref (string-append "(" (string-join (map symbol->string build-lib) " ") ")")])
      (when (or (not (file-exists? tpath)) force?)
        (write-text tpath
          (string-append
            "#!chezscheme\n"
            ";;; " default-tasks-file " --- " name " 的构建/任务描述(chandler make 消费)\n"
            ";;;\n"
            ";;; **可选**:chandler build 会从 chandler-manifest.ss 推导编译,不需要本文件。\n"
            ";;; 留它是为了写自定义任务(release / bench / ... )。task/file/rule/default-task\n"
            ";;; 是 DSL,加载即求值——它是程序,与数据文件 chandler-manifest.ss 配对。\n"
            ";;; 跑测试用顶层命令 `chandler test`(挂全运行时环境,见 chandler test --help)。\n"
            "\n"
            "(define-lib-roots \".\")\n"
            "\n"
            ";; build:编译 " libref " 及其 import 闭包(与 `chandler build` 等价,可删)\n"
            "(library-task 'build '" libref ")\n"
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
    (let ([mpath (project-manifest-path root)])
      (if (not (file-exists? mpath))
          #t
          (let ([mf (read-manifest mpath)])
            (cond
              [(string=? (or (manifest-name mf) "") "chandler") #t]
              [(manifest-chandler mf) #t]
              [(flag? flags 'strict)
               (eprintf
                 "chandler: project does not declare a chandler runtime gate; add (chandler \">=~a\") to chandler-manifest.ss\n"
                 chandler-version)
               #f]
              [else
               (eprintf
                 "warning: project does not declare a chandler runtime gate; add (chandler \">=~a\") to chandler-manifest.ss\n"
                 chandler-version)
               #t])))))

  ;; --user/--system/--prefix 决定装到哪个 libdir(注册表事务,designs/04)
  (define (cmd-deps root flags)
    (cond
      [(flag? flags 'list)  (cmd-deps-list root flags)]
      [(flag? flags 'tree)  (cmd-deps-tree root flags)]
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
    (let ([mf (read-project-manifest root)])
      (and mf (manifest-chandler mf) #t)))

  ;; ── P3:app install 生成命令行入口(本机运行时,不打包 binary/boot)──
  ;; runner: <libdir>/.chandler/<name>/run.sps — 极简程序(import entry + 调 main)。
  ;; launcher: <bindir>/<name>(POSIX sh) / <bindir>/<name>.ps1(Windows)— 本机运行时
  ;; 发现(skiff 优先) + 挂全局前缀 src::<mt> 对 + --program runner。
  ;; 对称于 chandler 自己的启动器(bootstrap.ss 生成的,也是"本机运行时 + 挂前缀"模式)。
  ;; 方案 A:launcher 模板在此重写一份,不提取 bootstrap.ss 的(保其自含红线,designs/06)。

  ;; v3(D17):启动器 = 稳定 shim,运行时读 active version。
  ;; 不再在 launcher 里硬编码 VERSION —— switch 只改 .registry,所有新进程自动用新版本。
  ;;
  ;; v4(D35):读的是 `.registry/<name>.active` **纯文本 sidecar**,不是权威的
  ;; `<name>.ss`。先前 sh 侧用 awk、ps1 侧用正则各解析一遍 s-expr —— 两份实现、
  ;; 两份 bug 面,还让 shim 与 registry 的文件格式绑死。sidecar 之后两边各一行读取
  ;; (`read` / `Get-Content -TotalCount 1`),shim 不再需要理解 registry 格式。
  ;; 写入与 drift 检测见 (chandler registry io)。
  (define (app-launcher-sh name libdir)
    (string-append
      "#!/bin/sh\n"
      "# " name " launcher — chandler v3 stable shim; do not edit.\n"
      "# Reads active version from .registry/<name>.active at runtime.\n"
      "NAME=\"" name "\"\n"
      "LIBDIR=\"" libdir "\"\n"
      "REGFILE=\"$LIBDIR/.registry/$NAME.active\"\n"
      "[ -f \"$REGFILE\" ] || { echo \"$NAME: not installed, or installed by an older chandler; run: chandler install\" 1>&2; exit 70; }\n"
      "# Plain-text sidecar: one line, the active version. No s-expr parsing needed.\n"
      "IFS= read -r ACTIVE < \"$REGFILE\"\n"
      "[ -n \"$ACTIVE\" ] || { echo \"$NAME: no active version; run: chandler switch\" 1>&2; exit 70; }\n"
      "RUNNER=\"$LIBDIR/$NAME/$ACTIVE/.chandler/run.sps\"\n"
      "[ -f \"$RUNNER\" ] || { echo \"$NAME: active version $ACTIVE missing runner (reinstall)\" 1>&2; exit 70; }\n"
      "case \"${CHANDLER_RUNTIME:-}\" in\n"
      "  skiff) _rt=\"${CHANDLER_SKIFF:-skiff}\" ;;\n"
      "  chez)  _rt=\"${CHANDLER_SCHEME:-scheme}\" ;;\n"
      "  \"\")    for _c in skiff scheme chez; do\n"
      "            command -v \"$_c\" >/dev/null 2>&1 && { _rt=\"$_c\"; break; } \\\n"
      "          done ;;\n"
      "  *) echo \"$NAME: invalid CHANDLER_RUNTIME (want: skiff|chez)\" 1>&2; exit 64 ;;\n"
      "esac\n"
      "[ -z \"$_rt\" ] && { echo \"$NAME: no Scheme runtime found (install skiff or Chez Scheme)\" 1>&2; exit 127; }\n"
      "exec \"$_rt\" -q --program \"$RUNNER\" \"$@\"\n"))

  (define (app-launcher-ps1 name libdir)
    (string-append
      "#!/usr/bin/env pwsh\n"
      "# " name " launcher — chandler v3 stable shim; do not edit.\n"
      "$ErrorActionPreference = 'Continue'\n"
      "$AppArgs = $args\n"
      "$Name = '" name "'\n"
      "$LibDir = '" libdir "'\n"
      "$RegFile = Join-Path $LibDir \".registry\" \"$Name.active\"\n"
      "if (-not (Test-Path $RegFile)) { [Console]::Error.WriteLine(\"$Name: not installed, or installed by an older chandler; run: chandler install\"); exit 70 }\n"
      "$Active = (Get-Content $RegFile -TotalCount 1).Trim()\n"
      "if (-not $Active) { [Console]::Error.WriteLine(\"$Name: no active version; run: chandler switch\"); exit 70 }\n"
      "$Runner = Join-Path $LibDir $Name $Active \".chandler\" \"run.sps\"\n"
      "if (-not (Test-Path $Runner)) { [Console]::Error.WriteLine(\"$Name: active $Active missing runner\"); exit 70 }\n"
      "switch ($env:CHANDLER_RUNTIME) {\n"
      "  'skiff' { $rt = if ($env:CHANDLER_SKIFF) { $env:CHANDLER_SKIFF } else { 'skiff' } }\n"
      "  'chez'  { $rt = if ($env:CHANDLER_SCHEME) { $env:CHANDLER_SCHEME } else { 'scheme' } }\n"
      "  ''      { foreach ($c in @('skiff','scheme','chez')) { if (Get-Command $c -ErrorAction SilentlyContinue) { $rt = $c; break } } }\n"
      "  $null   { foreach ($c in @('skiff','scheme','chez')) { if (Get-Command $c -ErrorAction SilentlyContinue) { $rt = $c; break } } }\n"
      "  default { [Console]::Error.WriteLine(\"$Name: invalid CHANDLER_RUNTIME\"); exit 64 }\n"
      "}\n"
      "if (-not $rt) { [Console]::Error.WriteLine(\"$Name: no Scheme runtime\"); exit 127 }\n"
      "& $rt -q --program $Runner @AppArgs\n"
      "exit $LASTEXITCODE\n"))

  ;; write-app-launcher! : 写 run.sps + 稳定 shim launcher
  ;; v3(D17):shim 只需 name + libdir(version 在运行时读 .registry)。
  ;; run.sps 仍需 entry/main(运行时逻辑);version 在 lock 里 —— 故本函数**不收**
  ;; 依赖表(D18 之后 run.sps 自己在启动时读 .chandler/chandler-manifest.lock)。
  (define (write-app-launcher! name version entry main libdir bindir)
    (let* ([mt (current-machine-type)]
           [win? (windows-mt? mt)]
           [runner-dir (join-paths (version-root libdir name version) ".chandler")])
      ;; runner:lock 驱动 + 动态 import
      (ensure-dir runner-dir)
      (write-text (join-paths runner-dir "run.sps")
        (run-sps-content entry main))
      ;; launcher:稳定 shim(读 .registry/ 找 active version)
      (ensure-dir bindir)
      (if win?
          (write-text (join-paths bindir (string-append name ".ps1"))
            (app-launcher-ps1 name libdir))
          (let ([f (join-paths bindir name)])
            (write-text f (app-launcher-sh name libdir))
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
           [mpath (project-manifest-path root)]
           [mf (and (file-exists? mpath) (read-manifest mpath))])
      (unless mf (error 'install "chandler-manifest.ss not found; run `chandler init` first"))
      (let ([name (or (manifest-name mf) (basename root))]
            [version (or (manifest-version mf) "0.0.0")])
        ;; 前置:deps + build 必须已完成
        (unless (file-exists? (project-lock-path root))
          (error 'install "chandler-manifest.lock not found; run `chandler deps` first"))
        ;; 1-4. 安装载荷(自身 + 依赖 + manifest/lock 快照),与 pack 同一管线
        (let ([mapp (manifest-app mf)])
          (install-project-payload! root libdir name version
                                    (and mapp (app-entry mapp))
                                    (list (cons 'register? #t)
                                          (cons 'adopt (flag? flags 'adopt))
                                          (cons 'force (flag? flags 'force))))
          ;; 5. P3:app 生成命令行入口(runner + launcher),用本机运行时
          (when mapp
            (write-app-launcher! name version (app-entry mapp) (app-main mapp)
                                 libdir (target-bindir flags))))
        (printf "installed ~a ~a + dependencies to ~a~%" name version libdir)
        0)))

  ;; v3(D13):install-project-resources! 已删除。资源靠 method B 约定,
  ;; 随源码树拷贝时自动落位到 <vroot>/src/<libpath>/resources/。

  ;; uninstall 只操作全局前缀(无本地卸载一说),故不再强制 --global —— 直接卸载。
  (define (cmd-uninstall-global root flags)
    (let ([libdir (target-libdir flags)]
          [name (flag flags 'name)]
          [ver (flag flags 'version)])
      (unless name (error 'uninstall "usage: chandler uninstall --name=<name> [--version=<ver>] [--prefix=DIR|--system]"))
      (let ([opts (list (cons 'keep-modified (flag? flags 'keep-modified)))]
            [name-sym (if (symbol? name) name (string->symbol name))])
        (if ver
            (uninstall-global name libdir opts ver)
            ;; 无 version → 删该 name 的所有版本:读 registered,逐 version 删
            (let ([reg (read-registered libdir name-sym)])
              (when reg
                (for-each (lambda (p) (uninstall-global name libdir opts (car p)))
                          (registered-versions reg))))))
      (remove-app-launcher! name (target-bindir flags))
      (printf "uninstalled ~a~%" name)
      0))

  (define (cmd-doctor root flags)
    (let* ([libdir (target-libdir flags)]
           [issues (doctor-global libdir)])
      (if (null? issues)
          (begin (printf "doctor: no issues in global library prefix ~a~%" libdir) 0)
          (begin
            (for-each (lambda (i) (eprintf "  ~a~%" i)) issues)
            (eprintf "doctor: ~a issue(s) found~%" (length issues))
            65))))

  ;; v3: chandler list — 列出全局已装包(多版本,active 标记)
  ;; row = (name-str version-str tag installer-symbol);tag = "active" 或 ""
  (define (cmd-list root flags)
    (let* ([libdir (target-libdir flags)]
           [rows (list-global libdir)])
      (if (null? rows)
          (printf "no packages installed in ~a~%" libdir)
          (begin
            (for-each (lambda (r)
                        ;; r = (name version tag installer)
                        (if (string=? "active" (caddr r))
                            (printf "~a\t~a\t[active]~%" (car r) (cadr r))
                            (printf "~a\t~a~%" (car r) (cadr r))))
                      (list-sort (lambda (a b)
                                   (or (string<? (car a) (car b))
                                       (and (string=? (car a) (car b))
                                            (string<? (cadr a) (cadr b)))))
                                 rows))))
      0))

  ;; v3(D19): chandler switch — 切换 app 的 active version
  ;;   chandler switch <name> <version>
  ;;   chandler switch <name> --latest
  ;;   chandler switch --list
  (define (cmd-switch root flags positionals)
    (cond
      ;; --list:列所有 app + active
      [(flag? flags 'list)
       (let ([rows (list-global (target-libdir flags))])
         (for-each (lambda (r)
                     (when (string=? "active" (caddr r))
                       (printf "~a\t~a~%" (car r) (cadr r))))
                   rows)
         0)]
      [else
       (let ([name (and (pair? positionals) (car positionals))]
             [ver-or-flag (and (pair? positionals) (pair? (cdr positionals)) (cadr positionals))]
             [libdir (target-libdir flags)])
         (unless name
           (error 'switch "usage: chandler switch <name> <version> | --latest | --list"))
          (let ([version
                 (cond
                   ;; --latest 是布尔旗标(parse-args 不把它放位置参数);兼容旧写法位置参数形
                   [(or (flag? flags 'latest) (equal? ver-or-flag "--latest"))
                    ;; 选该 name 的最高 version:semver 数值序(9.9.0 < 10.0.0),
                    ;; 不是字符串序;无法解析的版本串在 semver>? 内退化为字符串序
                    (let ([reg (or (read-registered libdir name)
                                   (error 'switch "name not registered" name))])
                      (let* ([versions (map car (registered-versions reg))]
                             [sorted (list-sort semver>? versions)])
                        (when (null? sorted)
                          (error 'switch "no versions installed" name))
                        (car sorted)))]
                   [(string? ver-or-flag) ver-or-flag]
                   [else (error 'switch "specify <version> or --latest")])])
           (switch-active libdir name version)
           (printf "switched ~a to ~a~%" name version)
           0))]))

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

;; ── build:编译依赖闭包 + 当前项目 ──
;; 1. 依赖:进程内排单编译 → 各 _vendor/<dep>/<srcdir>/_build/<mt>/
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

  ;; ── .env 收集(C3 + v3 .env.tests 覆盖)──
  ;; 实现已移到 (chandler cli runtime-env):.env → .env.tests(**仅 cmd-test**,四参形
  ;; tests? = #t)→ --env-file,后者覆盖前者。这里仅保留 env-with-dotenv 这层包装
  ;; (子进程 env 末位 = 覆盖式)。

  ;; .env 覆盖进程环境 —— 故在传给子进程的 env alist 里排在**最后**(env-prefix
  ;; 是 shell 变量前缀,同名后者胜)。
  (define env-with-dotenv
    (case-lambda
      [(root flags base-env) (env-with-dotenv root flags base-env #f)]
      [(root flags base-env tests?)
       (append base-env (collect-dotenv root flags tests?))]))

  ;; ── env:输出依赖环境变量(eval "$(chandler env)")──
  ;;   库搜索路径 + .env(D8:APP_ROOT 已去除,路径定位统一走 library-directories)。
  (define (cmd-env root flags)
    (let ([dirs (resolved-libdirs root)])
      (printf "export CHEZSCHEMELIBDIRS=\"~a\"~%" (libdirs->arg dirs))
      ;; .env(C3):覆盖式,故放在最后 export —— 后 export 的值在 eval 后生效。
      (for-each (lambda (kv) (printf "export ~a=~a~%" (car kv) (shell-quote (cdr kv))))
                (collect-dotenv root flags))
      0))

  ;; ── deps --list / deps --tree ──
  (define (cmd-deps-list root flags)
    (let ([rows (list-deps root)])
      (if (null? rows)
          (printf "(no locked dependencies; run `chandler deps` first)~%")
              (for-each
                (lambda (r)
                  (printf "~a  ~a  ~a~a~%"
                          (car r) (cadr r) (caddr r)
                          (if (eq? 'dev (cadddr r)) "  [dev]" "")))
                 rows))
      0))

  (define (cmd-deps-tree root flags)
    (let ([lpath (project-lock-path root)])
      (if (not (file-exists? lpath))
          (begin (printf "(no lock file)~%") 0)
          (let ([lk (read-lock lpath)])
            (printf "(root)~%")
            (for-each (lambda (d)
                        (printf "  ├─ ~a @~a~%" (locked-dep-name d)
                                (short-rev (locked-dep-rev d)))
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
      (let* ([mpath (project-manifest-path root)]
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
      (let* ([mpath (project-manifest-path root)]
             [datum (read-datum-file mpath)]
             [datum* (cons 'manifest (remove-dep (cdr datum) name))])
        (write-canonical-file mpath datum*)
        (printf "removed dependency ~a (next deps will clean vendor/)~%" name)
        0)))

  (define (remove-dep body name)
    (map (lambda (field)
           (if (or (tagged-list? field 'deps) (tagged-list? field 'dev-deps))
               (cons (car field)
                     (filter (lambda (d) (not (eq? (car d) name))) (cdr field)))
               field))
         body))

  ;; ── run:库搜索路径 + 载 native + 跑脚本(设计同 repl)──
  ;; chandler run --script <target.ss> [args...]
  (define (cmd-run root flags positionals rest)
    (let ([script (or (flag flags 'script)
                      (and (pair? positionals) (car positionals)))])
      (unless script (error 'run "usage: chandler run --script <script.ss> [args...]"))
      (let* ([dirs (resolved-libdirs root)]
             [natives (native-load-paths root dirs)]
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
                        (list (cons 'env (env-with-dotenv root flags '())))))))

  ;; ── test:跑 tests/run-tests.sps,环境装配同 run(库搜索 + native + .env + 运行时)──
  ;;   chandler test [args...]                  → runner 经 --program 直跑
  ;;                                            (有 native 时经 --script preamble 同 run)
  ;; v3 取代了 `chandler make test` 默认任务 —— 那条只走裸 scheme,没挂库搜索/native/.env。
  ;; 这里全经 resolved-libdirs / native-load-paths / collect-dotenv(.env + .env.tests 覆盖)/
  ;; choose-interp,与 cmd-run 同源同构(.env.tests 是 cmd-test 的主要新增)。
  ;; 退出码 = 子进程(run-foreground 原样返回),非 0 即失败。
  (define (cmd-test root flags positionals rest)
    (let ([runner (join-paths root "tests/run-tests.sps")])
      (unless (file-exists? runner)
        (errorf 'test
                "no tests/run-tests.sps found in ~a; create one or define a 'test task in chandler-tasks.ss"
                root))
      (let* ([dirs (resolved-libdirs root)]
             [natives (native-load-paths root dirs)]
             [interp (choose-interp root flags)]
             ;; 测试参数:`--` 之后的一切 + 位置参数(若有);多数 sps runner 不取位置参数。
             [test-args (append (or rest '()) (or positionals '()))]
             [invocation
               (if (null? natives)
                   ;; 无 native → 直跑 runner(同 tests/run-tests.sps 约定的 --program)
                   (append (list "-q" "--libdirs" (path-list dirs)
                                 "--program" runner)
                           test-args)
                   ;; 有 native → 走 preamble(同 cmd-run 的 --script 模式:
                   ;; preamble 先 load-shared-object 各 .so,再 (load runner))
                   (let ([preamble (make-preamble root natives runner)])
                     (append (list "-q" "--libdirs" (path-list dirs)
                                   "--script" preamble)
                             test-args)))])
        ;; tests? = #t:只有本命令加载 .env.tests(run/repl/exec 不吃测试配置)
        (run-foreground interp invocation
                        (list (cons 'env (env-with-dotenv root flags '() #t)))))))

  ;; ── exec:设 CHEZSCHEMELIBDIRS(+ .env)后透传任意命令 ──
  ;;   chandler exec -- <cmd> [args...]
  ;; 与 cmd-run 同一套库搜索规则(resolved-libdirs → "src::obj" 串)与 .env 叠加
  ;; (env-with-dotenv);退出码 = 子进程退出码(run-foreground 原样返回)。
  (define (cmd-exec root flags rest)
    (when (or (not rest) (null? rest))
      (error 'exec "usage: chandler exec -- <cmd> [args...]"))
    (let ([dirs (resolved-libdirs root)])
      (run-foreground (car rest) (cdr rest)
                      (list (cons 'env (env-with-dotenv root flags
                                         (list (cons "CHEZSCHEMELIBDIRS" (path-list dirs)))))))))

  ;; ── repl:交互式 shell,自动挂库搜索路径(与 run/exec 同规则)──
  ;;   项目模式(lock 存在且有依赖):lib/ + path 源目录 + 项目库根 + 全局(项目最高优先)
  ;;   全局模式(无 lock / 无依赖):用户全局 lib 目录
  (define (cmd-repl root flags)
    (let* ([project? (project-mode? root)]
           [dirs     (resolved-libdirs root)]
           [natives  (if project? (native-load-paths root dirs) '())]
           [interp   (repl-interp root flags)])
      (eprintf
               "chandler repl: ~a mode, ~a library search entries, runtime ~a~%"
               (if project? "project" "global") (length dirs) interp)
      (let ([args (append (list "--libdirs" (path-list dirs))
                          (if (null? natives) '() (list (make-preamble root natives))))])
        (run-foreground interp args
                        (list (cons 'env (env-with-dotenv root flags '())))))))

  ;; 运行时:--runtime > CHANDLER_RUNTIME > manifest 声明 skiff-only > 跟随 chandler 当前所在
  ;; repl 与 run/exec/test 同一套(interp-kind 已把"跟随当前运行时"的兜底内置进默认分支)。
  (define (repl-interp root flags) (choose-interp root flags))

  ;; native 预载 preamble 由共享的 make-preamble 统一生成(runtime-env.ss):
  ;; repl 走二参形(落 .chandler-repl.ss,装完 native 直接进 REPL),
  ;; run/test 走三参形(落 .chandler-run.ss,末尾 load 目标脚本)。
  ;;
  ;; choose-interp / interp-kind / make-preamble / collect-dotenv 自 v3 起抽到
  ;; (chandler cli runtime-env),由 cmd-run / cmd-repl / cmd-exec / cmd-test 共享。

  ;; 库搜索条目 → --libdirs / CHEZSCHEMELIBDIRS 串(pair 条目 → "src::obj",见 layout)
  (define (path-list dirs) (libdirs->arg dirs))

;; ── .gitignore / scaffold / basename(init 用)──
;; 生成物:依赖 checkout(_vendor/)、编译产物(_build/<mt>/)、各临时 recipe。
;; 注:`.chandler-approvals`(native 构建授权记录)**不**入此列——它是信任决定,
;; 提交与否属项目策略(提交=团队共享授权;不提交=各人各自授权),由用户自决。
;; `/vendor/` `/lib/` `.chandler-build.ss` `.chandler-install.ss` 是**已作废**的
;; 生成物名:C0 之后依赖 checkout 落 `_vendor/`(不再有汇总的 lib/),build 也
;; 直接在进程内排单编译、不再往依赖树里写临时 recipe。仍留在列表里 —— 老项目的
;; .gitignore 已经有这几行,删掉只会让它们变成噪声;新项目多几行无害。
;; **`/_vendor/` 与 `/dist/` 是真正生效的两条**(先前都漏掉:前者会让新项目把整棵
;; 依赖 checkout 提交进 git,后者是 `chandler pack` 的默认输出目录,见 pack/core.ss
;; 的 out 缺省值);`.chandler-run.ss` / `.chandler-repl.ss` 仍在用(run/repl 的
;; native preamble)。
  (define gitignore-entries '("/_vendor/" "/_build/" "/dist/"
                              "/vendor/" "/lib/"
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
