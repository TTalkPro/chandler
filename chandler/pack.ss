#!chezscheme
;;; chandler/pack.ss --- `chandler pack`:无源码、可重定位、自包含的分发包(designs/09)
;;;
;;; 自 bake 移交(bake 职责收敛为 build + install)。打包是「依赖闭包 + 部署」,那是
;;; chandler 的领域:lock 精确知道闭包与每个依赖的 native,lib/{src,<mt>} 是它自己铺的,
;;; 运行时选择本就由 manifest 的运行时门决定。**pack 只组装,不编译** —— 编译动作永远
;;; 是 bake 的(designs/07 §1),native 尤其无法在此现编。
;;;
;;; 包布局(designs/09;每一样平台绑定物都在 <mt> 层下):
;;;
;;;   myapp-1.0-<mt>/
;;;     bin/myapp[.ps1]              启动器 —— 唯一平台中立入口
;;;     bin/<mt>/skiff|scheme        运行时可执行文件
;;;     boot/<mt>/*.boot             boot
;;;     <mt>/                        对象根 = 应用 _build/<mt>/ + 依赖 lib/<mt>/
;;;     src/resources/<app>/         应用数据,原样(目录名约定死,不可配置)
;;;     src/resources/<dep-libpath>/ 依赖库资源(designs/11 §5;落点见 C4)
;;;     .chandler/<app>/manifest.ss  应用清单快照(与全局 install 同构)
;;;     pack.manifest
;;;
;;; 布局与**全局安装前缀** `~/.local/share/chez/` 逐层同构(P1/C4):`<mt>/` 对象根、
;;; `src/resources/<name>/` 资源、`.chandler/<name>/manifest.ss` 清单 —— 一个包解开
;;; 就是一个自带运行时的安装前缀,消费方(应用代码、native loader、chandler 自己)
;;; 四态用同一套路径规则,不需要「pack 专用」的第二套。
;;;
;;; 对象根同构同样成立:_build/<mt>(build)、<prefix>/<mt>(install)、lib/<mt>
;;; (项目)、<mt>(pack)结构完全一致 —— 包里的 <mt>/ 就是一个普通对象根,
;;; chandler 铺好的依赖树整棵拷进去即可;运行时也不再与库名空间混住。

(library (chandler pack)
  (export pack verify-pack pack-dir-name
          skiff-exe-path skiff-boot-dir chez-exe-path chez-csv-dir)
  (import (chezscheme)
          (chandler util)
          (chandler fs)
          (chandler proc)
          (chandler layout)
          (chandler sexp)
          (chandler manifest)
          (chandler lock)
          (chandler install)
          (chandler runtime-detector)
          (chandler version)
          (chandler hash))

  ;; ═══════════════════════════════════════════════════════════════════
  ;; §1 运行时定位(捆进包里的那一份)
  ;; ═══════════════════════════════════════════════════════════════════

  (define (which prog)
    (let ([r (run-capture "sh" (list "-c" (string-append "command -v " (shell-quote prog))))])
      (and (= 0 (proc-result-code r))
           (let ([s (string-trim (proc-result-out r))])
             (and (> (string-length s) 0) s)))))

  ;; 解引用符号链接 —— 包里要的是真身,不是指向系统某处的链接
  (define (real-path p)
    (let ([r (run-capture "sh" (list "-c" (string-append "readlink -f " (shell-quote p))))])
      (if (= 0 (proc-result-code r)) (string-trim (proc-result-out r)) p)))

  (define (skiff-exe-path)
    (let ([e (which "skiff")])
      (unless e (error 'pack "runtime skiff: no `skiff` on PATH (install skiff first)"))
      (real-path e)))

  (define (chez-exe-path)
    (let ([e (which "scheme")])
      (unless e (error 'pack "runtime scheme: no `scheme` on PATH"))
      (real-path e)))

  ;; skiff 自己的 boot 发现顺序(src/shell/main.cpp):$SKIFF_BOOT_DIR →
  ;; <exedir>/../lib/skiff/boot(安装布局)→ <exedir>/../boot(构建树)。
  (define (skiff-boot-dir exe)
    (define (ok? d) (and d (file-exists? (join-paths d "skiff.boot")) d))
    (let ([up (parent-dir (parent-dir exe))])
      (or (ok? (getenv* "SKIFF_BOOT_DIR"))
          (ok? (join-paths up "lib/skiff/boot"))
          (ok? (join-paths up "boot"))
          (error 'pack
                 (format "runtime skiff: cannot locate skiff.boot near ~a (set SKIFF_BOOT_DIR)" exe)))))

  ;; <root>/lib/csv<ver>/<mt>/ —— 装着 petite.boot / scheme.boot 的目录。
  ;; 由 PATH 上的 `scheme` 推导;mise 式布局把二进制直接放在 csv 目录里,故回退到
  ;; 解引用后的真身所在目录。CHEZ_BOOT_DIR 覆盖。
  (define (chez-csv-dir exe ver)
    (define (ok? d) (and d (file-exists? (join-paths d "petite.boot")) d))
    (let* ([bin  (parent-dir exe)]
           [root (parent-dir bin)]
           [std  (join-paths root (string-append "lib/csv" ver) (current-machine-type))])
      (or (ok? (getenv* "CHEZ_BOOT_DIR"))
          (ok? std)
          (ok? (parent-dir (real-path exe)))
          (error 'pack
                 (format "cannot locate petite.boot (looked near ~a; set CHEZ_BOOT_DIR)" std)))))

  ;; ── 版本探测:清单的 target 三元组必须描述**被捆的那一份**,不是跑 chandler 的这一份 ──

  ;; 保留版本串开头那段合法字符,丢掉后面的 banner/提示符残渣。第二道保险:这类失败
  ;; 是「静默产出坏 manifest、到部署期才被 verify-target! 拒」型,值得留验证。
  (define (version-token s)
    (let* ([s (string-trim s)] [n (string-length s)])
      (let loop ([i 0])
        (if (and (< i n)
                 (let ([c (string-ref s i)])
                   (or (char-numeric? c) (char-alphabetic? c) (memv c '(#\. #\- #\+ #\_)))))
            (loop (+ i 1))
            (substring s 0 i)))))

  (define (has-digit? s)
    (let ([n (string-length s)])
      (let loop ([i 0]) (and (< i n) (or (char-numeric? (string-ref s i)) (loop (+ i 1)))))))

  ;; 探测被捆 skiff 的版本。两条硬约束(bake 踩过,原样继承):
  ;;   ① 必须走 `skiff --script <probe>` —— 裸 `skiff <file>` 是 load + REPL(skiff 刻意
  ;;      对齐 stock scheme 的 CLI 语义,不该改),提示符 `>` 会漏进 stdout 被吃进版本串
  ;;      (曾使 manifest 记成 "0.1.1>");--script 另有出错即非零退出的好处。
  ;;   ② 取值走 skiff boot 在顶层绑定的 skiff-version(procedure 或 string 两形都认),
  ;;      无需 (import (skiff app))。不解析 --version banner:verify-target! 比的是
  ;;      --app 时 (skiff-version) 的返回值,只有探同一个值才不会与 banner 排版漂移。
  (define skiff-probe-src
    "(display (let ((v (top-level-value 'skiff-version))) (if (procedure? v) (v) v)))")

  (define (probe-skiff-version exe)
    (let* ([dir (join-paths (or (getenv* "TMPDIR") "/tmp")
                            (string-append "chandler-pack-" (number->string (get-process-id))))]
           [probe (join-paths dir "probe.ss")])
      (ensure-dir dir)
      (write-text probe skiff-probe-src)
      (let* ([r (run-capture "sh"
                             (list "-c"
                                   (string-append "SKIFF_QUIET=1 " (shell-quote exe)
                                                  " --script " (shell-quote probe)
                                                  " < /dev/null")))]
             [v (version-token (proc-result-out r))])
        (rm-rf dir)
        (unless (has-digit? v)
          (error 'pack
                 (format "runtime skiff: version probe failed for ~a (got ~s; too old to bind skiff-version at top level?)"
                         exe v)))
        v)))

  ;; 被捆 Chez 的版本号(不是跑 chandler 的那一份 —— chandler 可能跑在 skiff 上,
  ;; 而 PATH 上的 `scheme` 未必同版本)。`scheme --version` 把版本印到 stderr。
  (define (probe-chez-version exe)
    (let* ([r (run-capture "sh"
                           (list "-c" (string-append (shell-quote exe) " --version 2>&1 < /dev/null")))]
           [v (version-token (proc-result-out r))])
      (if (has-digit? v) v (chez-version-string))))

  ;; ═══════════════════════════════════════════════════════════════════
  ;; §2 包路径
  ;; ═══════════════════════════════════════════════════════════════════

  (define (pack-dir-name name version)
    (string-append name "-" version "-" (current-machine-type)))

  (define (pack-bin-dir  root) (join-paths root "bin" (current-machine-type)))
  (define (pack-boot-dir root) (join-paths root "boot" (current-machine-type)))
  (define (pack-lib-dir  root) (join-paths root (current-machine-type)))

  (define (windows-target?) (string-suffix? "nt" (current-machine-type)))

  ;; 可执行文件在 Windows 上必须带 .exe —— .ps1 启动器按全名调用,无扩展名跑不起来
  (define (exe-name base) (if (windows-target?) (string-append base ".exe") base))

  ;; ═══════════════════════════════════════════════════════════════════
  ;; §3 对象树搬运
  ;; ═══════════════════════════════════════════════════════════════════

  ;; 构建内部物不进包,与 `chandler build` 的 sync-obj-tree / bake install 同一份排除项:
  ;; .bake-manifest 是路径相关的指纹缓存,*.wpo 只在构建树内被链接期消费。
  (define (deliverable? rel)
    (and (not (string=? (base-name rel) ".bake-manifest"))
         (not (string-suffix? ".wpo" rel))))

  ;; 拷一棵对象树进包(剥源码:只带 Chez 编译产物 .so 与 native 的 OS 扩展名)
  (define (copy-obj-tree! from to)
    (let ([nx (string-append "." (so-ext))])
      (for-each
        (lambda (abs)
          (let ([rel (strip-prefix abs (string-append from "/"))])
            (when (and (deliverable? rel)
                       (or (string-suffix? ".so" rel) (string-suffix? nx rel)))
              (let ([dst (join-paths to rel)])
                (ensure-parent dst)
                (copy-file abs dst)))))
        (files-under from))))

  ;; 只搬 lock 里**声明过的**依赖命名空间 —— 不整棵拷 lib/<mt>/。
  ;;
  ;; 整棵拷会把该目录里的**陈旧残留**一并带走:`chandler build` 曾把整个
  ;; _build/<mt>/ 同步进来,其中包含应用自己那一轮的产物;下一次应用改了代码只跑
  ;; `bake build`,lib/<mt>/ 里那份就过期了,而它会覆盖掉刚编好的新产物 —— 包能跑,
  ;; 跑的却是旧代码(实测:改过的 docs-root 没生效,应用仍去找旧路径)。
  ;;
  ;; 按 lock 精确挑正是 chandler 相对 bake 的优势:bake 只能从构建图推断、遇预构建
  ;; 库不下探,故只能整棵命名空间搬;chandler 手里就有精确闭包。
  ;; N6: chandler 只有 runtime 子集能进包(designs/12 §6.3)。子集定义与判据都在
  ;; (chandler install) —— deps 阶段从全局前缀取的是同一份,两处共用免漂移。
  (define (copy-dep-trees! obj to locked)
    (let ([nx (string-append "." (so-ext))])
      (for-each
        (lambda (d)
          (let* ([ns (symbol->string (locked-dep-name d))]
                 [um (join-paths obj (string-append ns ".so"))]
                 [dir (join-paths obj ns)]
                 [chandler? (string=? ns "chandler")])
            ;; chandler.so 是 dev umbrella(export activate 等)——不进 pack;
            ;; pack 的入口是 chandler/base.so(runtime umbrella)
            (when (and (file-exists? um) (not chandler?))
              (let ([dst (join-paths to (string-append ns ".so"))])
                (ensure-parent dst) (copy-file um dst)))
            (when (file-directory? dir)
              (for-each
                (lambda (abs)
                  (let ([rel (strip-prefix abs (string-append obj "/"))])
                    (when (and (deliverable? rel)
                               (or (string-suffix? ".so" rel) (string-suffix? nx rel))
                               (not (and chandler? (chandler-dev-only-rel? rel))))
                      (let ([dst (join-paths to rel)])
                        (ensure-parent dst) (copy-file abs dst)))))
                (files-under dir)))))
        locked)))

  ;; 应用资源:源码态的 <project>/resources/ 原样搬进 <pack>/src/resources/<app>/。
  ;; 源目录名**约定死**,不设子句 —— 数据不带 ABI,故落点在 src/ 层(同一份被该应用的
  ;; 所有平台包共用;放进 <mt>/ 会随 ABI 重复,且那是对象根)。
  ;;
  ;; 落点带 <app> 一层:与依赖资源 src/resources/<dep-libpath>/ 同构,也与全局安装
  ;; 前缀同构 —— 前缀是**共享**的,一个扁平 resources/ 会让两个应用撞车。
  ;; 消费侧 (chandler runtime-paths) 的 app-resource-path 按同一约定解析。
  ;;
  ;; 注:无源码分发包因此也带一个 `src/` 目录,里面**只有资源、没有 .ss** ——
  ;; 那正是三态同构的代价与收益:APP_ROOT 下只有一种拼法,loader 与资源 API 都不分支。
  (define (copy-resources! project root app)
    (let ([src (join-paths project "resources")])
      (and (file-directory? src)
           (let ([n 0])
             (for-each
               (lambda (abs)
                 (let ([dst (join-paths (prefix-resource-dir root app)
                                        (strip-prefix abs (string-append src "/")))])
                   (ensure-parent dst)
                   (copy-file abs dst)
                   (set! n (+ n 1))))
               (files-under src))
             (> n 0)))))

  ;; .chandler/<app>/manifest.ss —— 应用清单快照,与全局 install 的落点同构(designs/05)。
  ;; 两个用途:① 部署态可回答「这包是什么、什么版本、入口是谁」而不必解析 pack.manifest;
  ;; ② app-resource-path 由此认出应用名(包里恰好一个条目),故不必再加第二个 env。
  ;; 项目有 manifest.ss 就原样拷;没有(--name/--entry 临时打包)则合成一份最小清单。
  (define (write-app-manifest! project root app version entry main-proc)
    (let* ([dir (join-paths root ".chandler" app)]
           [dst (join-paths dir "manifest.ss")]
           [src (project-manifest-path project)])
      (ensure-dir dir)
      (if (file-exists? src)
          (copy-file src dst)
          (write-text dst
            (string-append
              ";; generated by chandler pack -- no manifest.ss in the source project\n"
              "(manifest (format 1) (name \"" app "\") (version \"" version "\")\n"
              "  (app (entry " (datum->str entry) ") (main " (symbol->string main-proc) ")))\n")))))

  ;; M2: 依赖库的资源(ABI-independent,designs/11 §5;落点 C4;来源 C0)
  ;; 从各依赖**自己的源码树** _vendor/<dep>/<srcdir>/resources/<libpath>/ 复制到
  ;; <pack>/src/resources/<libpath>/ —— 源码树里的相对位置与前缀里的**完全同形**,
  ;; 故这一步是原样搬,不做路径映射。不套 .so filter。
  (define (copy-share! project root locked)
    (for-each
      (lambda (d)
        (let* ([src-root (dep-src-root project d)]
               [res (join-paths src-root resources-dirname)])
          (when (file-directory? res)
            (for-each
              (lambda (abs)
                (let ([dst (join-paths root "src" resources-dirname
                                       (strip-prefix abs (string-append res "/")))])
                  (ensure-parent dst)
                  (copy-file abs dst)))
              (files-under res)))))
      locked))

  ;; 一个依赖在 _vendor 里的源码根(= 它的库搜索根,也是 `chandler build` 的 cwd)
  (define (dep-src-root project d)
    (srcdir-join (vendor-dir project (locked-dep-name d))
                 (or (locked-dep-srcdir d) ".")))

  ;; 该依赖的编译产物树:它自己的 _build/<mt>/
  (define (dep-obj-dir project d)
    (join-paths (dep-src-root project d) "_build" (current-machine-type)))

  ;; ═══════════════════════════════════════════════════════════════════
  ;; §4 native 清点
  ;;   lock 给**期望集**(精确,缺项能指出是哪个依赖);组装后的树给**实际集**(完整,
  ;;   连应用自己经 bake native-task 产出的那些也在内)。前者用于前置校验,后者用于
  ;;   写清单 —— 两者各司其职,不能相互替代。
  ;; ═══════════════════════════════════════════════════════════════════

  ;; 对象树里每个带 native/ 的库,返回其名字段列表(("mylib") / ("chez" "async"))。
  ;; **递归** —— 多段库名的 native 落在 lib/<mt>/chez/async/native/,一层扫描会漏掉。
  (define (native-libs-under base)
    (let ([out '()])
      (let walk ([rel '()])
        (let ([dir (fold-left join-paths base (reverse rel))])
          (when (file-directory? dir)
            (for-each
              (lambda (e)
                (let ([p (join-paths dir e)])
                  (when (file-directory? p)
                    (if (string=? e "native")
                        (unless (null? rel) (set! out (cons (reverse rel) out)))
                        (walk (cons e rel))))))
              (list-sort string<? (dir-entries dir))))))
      (reverse out)))

  (define (native-files-in dir)
    (list-sort string<?
      (filter (lambda (f) (not (file-directory? (join-paths dir f)))) (dir-entries dir))))

  ;; lock 声明的 native 是否都在 lib/<mt>/ 里(前置校验)
  (define (missing-dep-natives obj-dir locked)
    (let ([miss '()])
      (for-each
        (lambda (d)
          (let ([name (symbol->string (locked-dep-name d))])
            (for-each
              (lambda (n)
                (let* ([soname (if (pair? n) (symbol->string (car n)) (symbol->string n))]
                       [p (lib-native-path obj-dir name soname)])
                  (unless (file-exists? p)
                    (set! miss (cons (string-append name ": " p) miss)))))
              (locked-dep-natives d))))
        locked)
      (reverse miss)))

  ;; ═══════════════════════════════════════════════════════════════════
  ;; §5 启动器
  ;;   启动器住在 bin/<app>,比 <mt> 层高一级,故包根仍是它的父目录。
  ;;
  ;;   **只设一个 env:APP_ROOT** —— 部署根。包内其余一切都在它下面的约定路径上:
  ;;     $APP_ROOT/<mt>/<libpath>/native/       native(库搜索根即对象根)
  ;;     $APP_ROOT/src/resources/<app>/         应用数据(目录名约定死)
  ;;   故不存在 per-library 的 native 变量(旧 BAKE_NATIVE_<LIB> 那族按库名大写造
  ;;   变量名),也不存在单独的 resources 变量 —— 布局钉死之后,唯一无法推导的信息
  ;;   就只剩「这个包被解到哪儿了」。
  ;;
  ;;   注:bake 生成的 native-loader 候选 1 仍写 `$APP_ROOT/lib/<mt>/…`(bake
  ;;   native.ss),P1 去掉 lib/ 前缀后那一条恒 miss —— 但候选 2 扫
  ;;   (library-directories) 的对象侧,而 bootstrap 挂的正是 <mt>/,故 native 照常
  ;;   自加载。boot 模式(唯一没有 library-directories 可依赖的场景)已作废
  ;;   (designs/09 K4),故不阻塞;bake 侧候选 1 宜择机跟进为 `$APP_ROOT/<mt>/…`。
  ;;
  ;;   它仍然是**必需**的,理由是 designs/24 §约束 3 实验钉死的:boot 里 loader 在库
  ;;   invoke 期执行,早于一切 stub 代码,运行期 library-directories 不可依赖;env 在
  ;;   exec 前设好,时序天然正确。而应用库(编译成 .so)本身也没有别的办法知道包根 ——
  ;;   bootstrap.ss 能从自身路径推,`skiff --app` 能从 manifest 路径推,库不能。
  ;; ═══════════════════════════════════════════════════════════════════

  (define (sh-head)
    (string-append
      "#!/bin/sh\n"
      "# generated by chandler pack -- do not edit\n"
      "HERE=$(CDPATH= cd -- \"$(dirname -- \"$0\")/..\" && pwd)\n"
      "export APP_ROOT=\"$HERE\"\n"))

  (define (ps1-head)
    ;; PowerShell 无 exec,故每个启动器都以重抛 $LASTEXITCODE 收尾;$args 在函数内是
    ;; 该函数的参数,故顶层先捕获再 splat;PS 7.3+ 原生命令非零退出会抛,显式关掉。
    (string-append
      "#!/usr/bin/env pwsh\n"
      "# generated by chandler pack -- do not edit\n"
      "$PSNativeCommandUseErrorActionPreference = $false\n"
      "$PackArgs = $args\n"
      "$Here = Split-Path -Parent $PSScriptRoot\n"
      "$env:APP_ROOT = $Here\n"))

  ;; skiff 启动器 = pack 规范 §8 的薄 shim:指好 boot、交给 `skiff --script bootstrap.ss`
  ;; (designs/10 §6:与 stock 对称;L0 之后 bootstrap.ss 是统一 runtime-aware verifier,
  ;; skiff pack 不再走 `skiff --app`)。SKIFF_BOOT_DIR 是必须的:skiff 按 exe 相对找
  ;; boot(<exedir>/../lib/skiff/boot),bin/<mt> + boot/<mt> 对不上它;而 boot 必须在
  ;; 进程有堆之前注册,远早于 --script 被解析,env 是唯一可用的交接方式。
  (define (launcher-sh-skiff)
    (let ([mt (current-machine-type)])
      (string-append
        (sh-head)
        "export SKIFF_BOOT_DIR=\"$HERE/boot/" mt "\"\n"
        "exec \"$HERE/bin/" mt "/skiff\" --script \"$HERE/bootstrap.ss\" \"$@\"\n")))

  (define (launcher-ps1-skiff)
    (let ([mt (current-machine-type)])
      (string-append
        (ps1-head)
        "$env:SKIFF_BOOT_DIR = \"$Here/boot/" mt "\"\n"
        "& \"$Here/bin/" mt "/skiff.exe\" --script \"$Here/bootstrap.ss\" @PackArgs\n"
        "exit $LASTEXITCODE\n")))

  ;; stock Chez:绝对 -b 链(bake designs/22 机制 C —— 最稳,exe 名任意,相对 -b 不可用)。
  ;; petite.boot 恒随;scheme.boot 只在 runtime=scheme 时随(部署态只 fasl 载入预编译
  ;; .so,petite 单独即可,包更小)。
  (define (boots-flags runtime prefix)
    (let ([p (string-append prefix "/boot/" (current-machine-type) "/")])
      (string-append "-b \"" p "petite.boot\""
                     (if (eq? runtime 'scheme) (string-append " -b \"" p "scheme.boot\"") ""))))

  (define (launcher-sh-stock runtime)
    (string-append
      (sh-head)
      "exec \"$HERE/bin/" (current-machine-type) "/scheme\" "
      (boots-flags runtime "$HERE")
      " --script \"$HERE/bootstrap.ss\" \"$@\"\n"))

  (define (launcher-ps1-stock runtime)
    (string-append
      (ps1-head)
      "& \"$Here/bin/" (current-machine-type) "/scheme.exe\" "
      (boots-flags runtime "$Here")
      " --script \"$Here/bootstrap.ss\" @PackArgs\n"
      "exit $LASTEXITCODE\n"))

  ;; 按 machine-type 选 sh / .ps1。ta6nt 包只能在 Windows 上产,故 .ps1 这条在 Linux
  ;; 上不被 `chandler pack` 走到;生成器本身另由 PowerShell 验收渲染后实跑。
  (define (write-launcher! root app sh ps1)
    (let ([bindir (join-paths root "bin")])
      (ensure-dir bindir)
      (if (windows-target?)
          (write-text (join-paths bindir (string-append app ".ps1")) ps1)
          (let ([f (join-paths bindir app)])
            (write-text f sh)
            (run-status "chmod" (list "+x" f))))))

  ;; ═══════════════════════════════════════════════════════════════════
  ;; §6 bootstrap.ss(runtime-aware verifier,designs/10 §3-5)
  ;;   生成的 bootstrap 在 stock Chez 与 Skiff 上跑**同一份**:先读 pack.manifest,
  ;;   校验 (format N) 与 target 三元组(按当前 runtime 分派,矩阵见 designs/10 §4),
  ;;   全部通过才碰 library-directories / native / import。校验失败一律显式
  ;;   (exit N)(sysexits:65/70/78)+ 单行 s-expr 诊断,不走 Chez error。
  ;; ═══════════════════════════════════════════════════════════════════

  ;; 包根从**自身路径**推导 —— bootstrap 由 `--script` 跑,(car (command-line)) 就是
  ;; 它自己,dirname 即包根,故 bootstrap 自身无需任何 env(启动器另设 APP_ROOT 是
  ;; 给**应用代码**与 native loader 用的 —— 它们没有 argv0 这条线索)。
  (define bootstrap-root-src
    (string-append
      "(define %root\n"
      "  (let* ((self (car (command-line)))\n"
      "         (d (let loop ((i (- (string-length self) 1)))\n"
      "              (cond ((< i 0) \".\")\n"
      "                    ((char=? #\\/ (string-ref self i)) (substring self 0 i))\n"
      "                    (else (loop (- i 1)))))))\n"
      "    (if (string=? d \"\") \".\" d)))\n"))

  ;; stderr 诊断:人类可读行 + 单行 s-expr(orchestrator 用 read 收,故 s-expr
  ;; 恒单行、无换行;designs/10 §5)。
  (define stderr-diag-src
    (string-append
      "(define (%err msg)\n"
      "  (fprintf (current-error-port) \"chandler-pack: ~a~n\" msg)\n"
      "  (flush-output-port (current-error-port)))\n"
      "(define (%err-sexp s)\n"
      "  (fprintf (current-error-port) \"~s~n\" s)\n"
      "  (flush-output-port (current-error-port)))\n"))

  ;; runtime 探测:一字不改照搬 (chandler runtime) skiff-version-string 的守卫
  ;; (designs/06 §4):skiff-version 可能绑字符串、也可能绑返回字符串的过程
  ;; (skiff 0.1.1 起为过程),两形都认;取不到即 stock Chez。
  (define runtime-detect-src
    (string-append
      "(define %rt\n"
      "  (if (and (top-level-bound? 'skiff-version)\n"
      "           (guard (e [#t #f])\n"
      "             (let ([v (top-level-value 'skiff-version)])\n"
      "               (or (string? v) (procedure? v)))))\n"
      "      'skiff 'chez))\n"
      "(define (%skiff-ver)\n"
      "  (guard (e [#t #f])\n"
      "    (let ([v (top-level-value 'skiff-version)])\n"
      "      (cond\n"
      "        [(string? v) v]\n"
      "        [(procedure? v) (let ([r (v)]) (and (string? r) r))]\n"
      "        [else #f]))))\n"))

  ;; 内联 (chandler version) 的区间匹配:部署态没有 chandler 可 import,bootstrap
  ;; 必须自含。支持精确 / "*" / >= <= > < = 操作符与空格合取,与 skiff/app.ss 的
  ;; version-in-range? 同语义。解析容错(非法分量当 0)+ 整体 guard 兜成 #f:
  ;; 部署侧宁可按「不匹配」走 78,也不能让畸形版本串把进程抛进 debugger。
  (define version-match-src
    (string-append
      "(define (%ssplit s delims)\n"
      "  (let loop ([i 0] [start 0] [acc '()])\n"
      "    (cond\n"
      "      [(= i (string-length s))\n"
      "       (reverse (if (> i start) (cons (substring s start i) acc) acc))]\n"
      "      [(memv (string-ref s i) delims)\n"
      "       (loop (+ i 1) (+ i 1) (if (> i start) (cons (substring s start i) acc) acc))]\n"
      "      [else (loop (+ i 1) start acc)])))\n"
      "(define (%sprefix? p s)\n"
      "  (let ([n (string-length p)])\n"
      "    (and (>= (string-length s) n) (string=? p (substring s 0 n)))))\n"
      "(define (%sdrop s n) (substring s n (string-length s)))\n"
      "(define (%parse-version s0)\n"
      "  (let* ([s (if (and (> (string-length s0) 0)\n"
      "                     (memv (string-ref s0 0) '(#\\v #\\V)))\n"
      "                (substring s0 1 (string-length s0))\n"
      "                s0)]\n"
      "         [core (car (%ssplit s '(#\\- #\\+)))])\n"
      "    (map (lambda (p)\n"
      "           (let ([n (string->number p)])\n"
      "             (if (and n (integer? n) (exact? n) (>= n 0)) n 0)))\n"
      "         (%ssplit core '(#\\.)))))\n"
      "(define (%pad-to a b)\n"
      "  (let ([la (length a)] [lb (length b)])\n"
      "    (if (>= la lb) a (append a (make-list (- lb la) 0)))))\n"
      "(define (%version-compare a b)\n"
      "  (let loop ([a (%pad-to a b)] [b (%pad-to b a)])\n"
      "    (cond\n"
      "      [(and (null? a) (null? b)) 0]\n"
      "      [(< (car a) (car b)) -1]\n"
      "      [(> (car a) (car b)) 1]\n"
      "      [else (loop (cdr a) (cdr b))])))\n"
      "(define (%match-one tok v)\n"
      "  (cond\n"
      "    [(string=? tok \"*\") #t]\n"
      "    [(%sprefix? \">=\" tok) (>= (%version-compare v (%parse-version (%sdrop tok 2))) 0)]\n"
      "    [(%sprefix? \"<=\" tok) (<= (%version-compare v (%parse-version (%sdrop tok 2))) 0)]\n"
      "    [(%sprefix? \">\" tok)  (>  (%version-compare v (%parse-version (%sdrop tok 1))) 0)]\n"
      "    [(%sprefix? \"<\" tok)  (<  (%version-compare v (%parse-version (%sdrop tok 1))) 0)]\n"
      "    [(%sprefix? \"=\" tok)  (=  (%version-compare v (%parse-version (%sdrop tok 1))) 0)]\n"
      "    [else (= (%version-compare v (%parse-version tok)) 0)]))\n"
      "(define (%version-match? constraint ver)\n"
      "  (guard (e [#t #f])\n"
      "    (let ([v (%parse-version ver)])\n"
      "      (for-all (lambda (tok) (%match-one tok v))\n"
      "               (%ssplit constraint '(#\\space #\\tab))))))\n"))

  ;; 读 pack.manifest:不可读 / 不是 (pack ...) → 65 EX_DATAERR(对齐
  ;; skiff/app.ss read-manifest)。只定义 %fields / %field1;(target …) 的缺失
  ;; 由 full-target-check-src 判(先让 (format N) 检查跑,顺序与 skiff --app 一致)。
  (define manifest-read-src
    (string-append
      "(define %manifest-path (string-append %root \"/pack.manifest\"))\n"
      "(define %manifest\n"
      "  (guard (e [#t #f])\n"
      "    (call-with-input-file %manifest-path read)))\n"
      "(unless (and %manifest (pair? %manifest) (eq? (car %manifest) 'pack))\n"
      "  (%err (string-append \"manifest missing or invalid: \" %manifest-path))\n"
      "  (%err-sexp '(chandler-pack-error (manifest-invalid)))\n"
      "  (exit 65))\n"
      "(define %fields (cdr %manifest))\n"
      "(define (%field1 key)\n"
      "  (let ([c (assq key %fields)])\n"
      "    (and c (pair? (cdr c)) (cadr c))))\n"))

  ;; (format N) 前向兼容:N > pack-format-supported(=1)→ 70 EX_SOFTWARE;
  ;; 字段缺省视为 0(对齐 skiff/app.ss verify-format! 的 (or (field1 m 'format) 0))。
  (define verify-format-src
    (string-append
      "(define pack-format-supported 1)\n"
      "(let ([fmt (or (%field1 'format) 0)])\n"
      "  (when (and (number? fmt) (> fmt pack-format-supported))\n"
      "    (%err (format \"pack format ~a is newer than supported (~a)\"\n"
      "                  fmt pack-format-supported))\n"
      "    (%err-sexp (list 'chandler-pack-error\n"
      "                     (list 'format-too-new\n"
      "                           (list 'pack fmt)\n"
      "                           (list 'supported pack-format-supported))))\n"
      "    (exit 70)))\n"))

  ;; runtime-aware verify-target!(designs/10 §4 矩阵全 13 行):
  ;;   - machine-type / chez-version 永不放宽,不符即 78 EX_CONFIG;
  ;;   - (skiff-version "X") 精确:runtime 是 skiff 则值比对;是 stock 则必 78
  ;;     (pack requires skiff, current runtime is stock Chez);
  ;;   - (skiff-compat "<range>"):runtime 是 skiff 则 %version-match?;是 stock
  ;;     则必 78;唯独全开 \">=0.0.0\"(stock 包默认)在两种 runtime 上都通过;
  ;;   - 两者都不声明:不查 skiff;
  ;;   - SKIFF_ALLOW_VERSION_SKEW=1 只放宽 skiff 维(WARNING + 通过),
  ;;     machine-type / chez-version 不动;
  ;;   - 缺 (target …) → 65 EX_DATAERR。
  ;; 失败先出人读诊断、再出单行 s-expr,显式 (exit N),绝不走 Chez error。
  (define full-target-check-src
    (string-append
      "(define %target\n"
      "  (or (assq 'target %fields)\n"
      "      (begin\n"
      "        (%err \"manifest missing (target ...)\")\n"
      "        (%err-sexp '(chandler-pack-error (manifest-invalid (target-missing))))\n"
      "        (exit 65))))\n"
      "(define (%tfield1 key)\n"
      "  (let ([c (assq key (cdr %target))])\n"
      "    (and c (pair? (cdr c)) (cadr c))))\n"
      "(define %want-mt (%tfield1 'machine-type))\n"
      "(define %want-chez (%tfield1 'chez-version))\n"
      "(define %want-skiff (%tfield1 'skiff-version))\n"
      "(define %want-compat (%tfield1 'skiff-compat))\n"
      "(define %actual-mt (machine-type))\n"
      "(define %actual-chez\n"
      "  (let* ([s (scheme-version)] [n (string-length s)])\n"
      "    (let loop ([i (- n 1)])\n"
      "      (cond\n"
      "        [(< i 0) s]\n"
      "        [(char-whitespace? (string-ref s i)) (substring s (+ i 1) n)]\n"
      "        [else (loop (- i 1))]))))\n"
      "(define %skew-ok? (equal? (getenv \"SKIFF_ALLOW_VERSION_SKEW\") \"1\"))\n"
      "(define %bad '())\n"
      "(define (%mismatch! what expected actual advice)\n"
      "  (set! %bad (cons (list what expected actual advice) %bad)))\n"
      "(unless (eq? %want-mt %actual-mt)\n"
      "  (%mismatch! 'machine-type %want-mt %actual-mt\n"
      "              \"wrong platform pack; fetch the build for this machine-type\"))\n"
      "(unless (equal? %want-chez %actual-chez)\n"
      "  (%mismatch! 'chez-version %want-chez %actual-chez\n"
      "              \"install the matching runtime or re-pack the app\"))\n"
      "(cond\n"
      "  [(and %want-skiff (string? %want-skiff))\n"
      "   (if (eq? %rt 'skiff)\n"
      "       (let ([actual (%skiff-ver)])\n"
      "         (unless (equal? actual %want-skiff)\n"
      "           (if %skew-ok?\n"
      "               (%err (format \"WARNING: skiff-version skew allowed by SKIFF_ALLOW_VERSION_SKEW=1 (pack ~a, runtime ~a)\" %want-skiff actual))\n"
      "               (%mismatch! 'skiff-version %want-skiff actual\n"
      "                           \"install the matching skiff runtime or re-pack the app\"))))\n"
      "       (%mismatch! 'skiff-version %want-skiff 'stock-chez\n"
      "                   \"pack requires skiff, current runtime is stock Chez\"))]\n"
      "  [(and %want-compat (string? %want-compat)\n"
      "        (not (string=? %want-compat \">=0.0.0\")))\n"
      "   (if (eq? %rt 'skiff)\n"
      "       (let ([actual (%skiff-ver)])\n"
      "         (unless (and actual (%version-match? %want-compat actual))\n"
      "           (if %skew-ok?\n"
      "               (%err (format \"WARNING: skiff-version skew allowed by SKIFF_ALLOW_VERSION_SKEW=1 (pack compat ~a, runtime ~a)\" %want-compat actual))\n"
      "               (%mismatch! 'skiff-version (string-append \"compat \" %want-compat) actual\n"
      "                           \"install the matching skiff runtime or re-pack the app\"))))\n"
      "       (%mismatch! 'skiff-version (string-append \"compat \" %want-compat) 'stock-chez\n"
      "                   \"pack requires skiff, current runtime is stock Chez\"))]\n"
      "  [else #t])\n"
      "(unless (null? %bad)\n"
      "  (%err \"pack target mismatch; refusing to load\")\n"
      "  (for-each\n"
      "    (lambda (b)\n"
      "      (%err (format \"  ~a: expected ~s, actual ~s~n    -> ~a\"\n"
      "                    (car b) (cadr b) (caddr b) (cadddr b))))\n"
      "    (reverse %bad))\n"
      "  (%err-sexp (cons 'chandler-pack-error\n"
      "                   (list (cons 'target-mismatch\n"
      "                               (map (lambda (b)\n"
      "                                      (list (car b)\n"
      "                                            (list 'expected (cadr b))\n"
      "                                            (list 'actual (caddr b))))\n"
      "                                    (reverse %bad))))))\n"
      "  (exit 78))\n"))

  ;; 统一加载 native:**递归**走整棵对象树。这是兜底 —— 生成的 loader 正常先到 ——
  ;; 但一个会静默漏掉一半库的兜底不算兜底(一层扫描找不到 (chez async) 那类)。
  (define native-walk-src
    (string-append
      "(define (%load-natives dir)\n"
      "  (when (file-exists? dir)\n"
      "    (for-each\n"
      "      (lambda (e)\n"
      "        (let ((p (string-append dir \"/\" e)))\n"
      "          (when (file-directory? p)\n"
      "            (if (string=? e \"native\")\n"
      "                (for-each (lambda (f)\n"
      "                            (let ((q (string-append p \"/\" f)))\n"
      "                              (unless (file-directory? q) (load-shared-object q))))\n"
      "                          (directory-list p))\n"
      "                (%load-natives p)))))\n"
      "      (directory-list dir))))\n"))

  ;; 校验全部落在任何状态变更之前(library-directories / %load-natives / import):
  ;; 失败进程必须是「零副作用 + 明确退出码」的,不留半截加载的堆。
  ;; ver 形参仅为签名兼容保留:target 三元组现在由 bootstrap 自己从 pack.manifest
  ;; 读,不再在生成期内联(同一份 bootstrap 服务 stock 与 skiff 两种 runtime)。
  (define (bootstrap-source entry main-proc ver mt)
    (string-append
      ";; generated by chandler pack -- do not edit\n"
      bootstrap-root-src
      stderr-diag-src
      runtime-detect-src
      version-match-src
      manifest-read-src
      verify-format-src
      full-target-check-src
      "(define %lib (string-append %root \"/" mt "\"))\n"
      "(define %src (string-append %root \"/src\"))\n"
      "(compile-imported-libraries #f)\n"       ; 部署态只载入,永不重编
      ;; 挂**一对** (src . obj):包是源码-less 的,`src/` 里只有资源没有 .ss,
      ;; 但资源定位靠扫 library-directories 的两侧(2026-07-24),故 src 侧必须在表上。
      ;; Chez 在 src 侧找不到任何 .ss,解析照旧落到 obj 侧,行为不变。
      "(library-directories (list (cons %src %lib)))\n"
      native-walk-src
      "(%load-natives %lib)\n"
      "(import " (datum->str entry) ")\n"
      "(" (symbol->string main-proc) " (cdr (command-line)))\n"
      "(exit 0)\n"))

  (define (datum->str d)
    (let ([op (open-output-string)]) (write d op) (get-output-string op)))

  ;; ═══════════════════════════════════════════════════════════════════
  ;; §7 pack.manifest
  ;; ═══════════════════════════════════════════════════════════════════

  (define (manifest-head app version runtime entry main-proc ver mt skiff-ver)
    (let ([bootp (string-append "boot/" mt "/")]
          [binp  (string-append "bin/" mt "/")])
      (string-append
        ";; generated by chandler pack (designs/09)\n"
        "(pack\n"
        "  (format 1)\n"
        "  (app \"" app "\") (version \"" version "\")\n"
        "  (target (chez-version \"" ver "\") (machine-type " mt ")"
        ;; skiff 的 verify-target! 精确匹配 skiff-version,故只有捆了 skiff 的包才钉它;
        ;; stock 包不带任何 skiff API 依赖,声明一个全开区间 → 同一个 stock 包在
        ;; bin/<mt>/scheme 与任意 `skiff --app` 下通吃。
        (if skiff-ver
            (string-append " (skiff-version \"" skiff-ver "\")")
            " (skiff-compat \">=0.0.0\")")
        ")\n"
        (if (eq? runtime 'skiff)
            (string-append
              "  (runtime (kind skiff) (exe \"" binp "skiff\")\n"
              "           (boots \"" bootp "petite.boot\" \"" bootp "scheme.boot\""
              " \"" bootp "skiff.boot\"))\n")
            (string-append
              "  (runtime (kind " (symbol->string runtime) ") (exe \"" binp "scheme\")\n"
              "           (boots \"" bootp "petite.boot\""
              (if (eq? runtime 'scheme) (string-append " \"" bootp "scheme.boot\"") "")
              "))\n"))
        "  (lib-dirs \"" mt "\")\n"
        "  (entry (library " (datum->str entry) ") (main " (symbol->string main-proc) "))\n")))

  ;; (native <soname> "<rel>") —— `skiff --app`(与 stock 的 bootstrap)在 import 入口库
  ;; 之前统一 load-shared-object 这些(pack 规范 §4:infra 载 native,库只写
  ;; foreign-procedure)。按组装后的树实扫,故应用自己的 native 也在内。空则省略。
  (define (manifest-native-lines root)
    (let* ([mt  (current-machine-type)]
           [obj (pack-lib-dir root)]
           [entries
            (apply append
              (map (lambda (segs)
                     (let* ([rel (string-join segs "/")]
                            [nd  (join-paths obj rel "native")])
                       (map (lambda (f)
                              (string-append "    (" (strip-ext f)
                                             " \"" mt "/" rel "/native/" f "\")\n"))
                            (native-files-in nd))))
                   (native-libs-under obj)))])
      (if (null? entries) "" (string-append "  (native\n" (apply string-append entries) "    )\n"))))

  (define (strip-ext f)
    (let loop ([i (- (string-length f) 1)])
      (cond
        [(< i 0) f]
        [(char=? #\. (string-ref f i)) (substring f 0 i)]
        [else (loop (- i 1))])))

  ;; (files …):每个文件的 sha256 + 字节数。**按需**校验(chandler verify-pack / 补丁前),
  ;; 不在每次启动跑 —— 启动只做廉价的目标三元组比对。pack.manifest 最后写,故不自哈。
  (define (manifest-files-lines root)
    (apply string-append
      (map (lambda (abs)
             (let ([rel (strip-prefix abs (string-append root "/"))])
               (string-append "    (\"" rel "\" (sha256 \"" (sha256-file abs)
                              "\") (size " (number->string (file-size abs)) "))\n")))
           (list-sort string<? (files-under root)))))

  (define (file-size f)
    (call-with-port (open-file-input-port f) (lambda (p) (port-length p))))

  (define (write-pack-manifest! root app version runtime entry main-proc ver mt skiff-ver)
    (write-text (join-paths root "pack.manifest")
      (string-append
        (manifest-head app version runtime entry main-proc ver mt skiff-ver)
        (manifest-native-lines root)
        "  (files\n"
        (manifest-files-lines root)
        "    ))\n")))

  ;; ═══════════════════════════════════════════════════════════════════
  ;; §8 主入口
  ;; ═══════════════════════════════════════════════════════════════════

  ;; 库名 (a b c) → 对象树里的相对路径 "a/b/c.so"
  (define (entry-so-rel entry)
    (string-append (string-join (map symbol->string entry) "/") ".so"))

  ;; opts: (runtime . skiff|scheme|petite) (out . dir)
  ;;       (name . s) (version . s) (entry . lib-ref) (main . sym)
  (define (pack project opts)
    (let* ([mpath (project-manifest-path project)]
           [mf    (and (file-exists? mpath) (read-manifest mpath))]
           [name  (or (alist-ref opts 'name) (and mf (manifest-name mf))
                      (error 'pack "cannot determine app name (no manifest.ss; pass --name)"))]
           [version (or (alist-ref opts 'version) (and mf (manifest-version mf)) "0.0.0")]
           [mapp  (and mf (manifest-app mf))]
           [entry (or (alist-ref opts 'entry) (and mapp (app-entry mapp)))]
           [mainp (or (alist-ref opts 'main) (and mapp (app-main mapp)) 'main)]
           [rt    (or (alist-ref opts 'runtime) (default-runtime mf))]
           [out   (or (alist-ref opts 'out) "dist")]
           [mt    (current-machine-type)])
      ;; pack 服务于**应用**:必须有显式入口。库(manifest 没声明 (app …))不该被打成
      ;; 可执行分发包 —— 它的天然分发形态是 git,消费方 `chandler add` 即可。允许用
      ;; `--entry` 显式覆盖,以便临时打包或 lib→app 演化期;但缺省情况(manifest 没声明
      ;; 且命令行也没传)就直接拒绝,而不是**猜**一个顶层 umbrella。
      ;;
      ;; 这取代了早先的 infer-entry:它把"包名"和"入口库名"混为一谈(skiff-demo 的包名
      ;; 是 skiff-demo、入口库却是 (mdserver)),让 lib 也能被悄无声息地打成 app 包 ——
      ;; 产出一堆无意义的 bin/boot/runtime。
      (unless entry
        (error 'pack
               (string-append
                 "no entry library declared; this looks like a library, not an application.\n"
                 "  `chandler pack` ships runnable applications. For a library, push to git\n"
                 "  and let consumers `chandler add <name> <url>` instead.\n"
                 "  If this is actually an app, declare it in manifest.ss:\n"
                 "    (app (entry (<lib>)) (main main))\n"
                 "  or pass --entry '(<lib>)' on the command line.")))
      (unless (memq rt '(skiff scheme petite))
        (error 'pack (format "runtime ~s not supported (skiff | scheme | petite)" rt)))
      (let* ([locked (project-locked-deps project)]
             [root (join-paths project out (pack-dir-name name version))]
             [objdir (pack-lib-dir root)])
        (preflight project mt locked)
        (rm-rf root)
        (ensure-dir objdir)
        (printf "pack ~a~%" root)
        ;; 1) 对象根 = lock 声明的依赖闭包 + 应用自己的编译树。
        ;;    应用**后拷**:它永远赢 —— lib/<mt>/ 里可能留着上一轮 `chandler build`
        ;;    同步进去的、同名的旧应用产物。
        ;; C0:每个依赖的对象在**它自己的** _vendor/<dep>/<srcdir>/_build/<mt>/,
        ;; 不再有汇总的 lib/<mt>/。逐依赖拷,顺带天然避开了「别的依赖的同名文件」。
        (for-each
          (lambda (d)
            (let ([o (dep-obj-dir project d)])
              (when (file-directory? o) (copy-dep-trees! o objdir (list d)))))
          locked)
        (copy-obj-tree! (join-paths project "_build" mt) objdir)
        ;; 入口库必须真的在包里 —— 否则打出的包一路正常,到启动 import 才报
        ;; "library (x) not found"。这一步把那个失败提前到打包期。
        (let ([e (join-paths objdir (entry-so-rel entry))])
          (unless (file-exists? e)
            (rm-rf root)
            (error 'pack
                   (format "entry library ~a has no compiled object at ~a~%  (pass --entry '(<lib>)', or run `bake build` if it is simply not built)"
                           entry e))))
        ;; chandler 的 runtime 子集:它不是 lock 里的依赖(是运行时门,designs/12 §5),
        ;; 故从**全局前缀**取那一份编译好的进包 —— 包必须自包含,不能指望目标机装了
        ;; chandler。取的与 deps 阶段铺进 lib/ 的是同一个子集、同一个判据。
        (when (and mf (manifest-chandler mf))
          (copy-chandler-into-pack! objdir (manifest-chandler mf)))
        ;; 2) src/resources/<app>/(应用数据)+ src/resources/<dep>/(依赖库资源,M2)
        ;;    + .chandler/<app>/manifest.ss(清单快照)—— 三者都与全局安装前缀同构
        (copy-resources! project root name)
        (copy-share! project root locked)
        (write-app-manifest! project root name version entry mainp)
        ;; bootstrap 在 runtime 定位之前落盘:内容只依赖 entry/mt(target 三元组由它
        ;; 自己从 pack.manifest 读),与捆哪份运行时无关;stock 与 skiff 包同一份
        ;; (designs/10 §3:不再分叉;skiff 启动器在 L2 才换 --script,文件先备好)。
        (write-text (join-paths root "bootstrap.ss") (bootstrap-source entry mainp #f mt))
        ;; 3) 运行时 + boot + 启动器 + 清单
        (if (eq? rt 'skiff)
            (let* ([exe (skiff-exe-path)]
                   [bd  (skiff-boot-dir exe)]
                   [sv  (probe-skiff-version exe)])
              (copy-exe! exe (join-paths (pack-bin-dir root) (exe-name "skiff")))
              (for-each (lambda (b) (copy-file (join-paths bd b) (join-paths (pack-boot-dir root) b)))
                        '("petite.boot" "scheme.boot" "skiff.boot"))
              (write-launcher! root name (launcher-sh-skiff) (launcher-ps1-skiff))
              (write-pack-manifest! root name version rt entry mainp
                                    (probe-chez-version exe) mt sv))
            (let* ([exe (chez-exe-path)]
                   [ver (probe-chez-version exe)]
                   [csv (chez-csv-dir exe ver)])
              (copy-exe! exe (join-paths (pack-bin-dir root) (exe-name "scheme")))
              (copy-file (join-paths csv "petite.boot") (join-paths (pack-boot-dir root) "petite.boot"))
              (when (eq? rt 'scheme)
                (copy-file (join-paths csv "scheme.boot") (join-paths (pack-boot-dir root) "scheme.boot")))
              (write-launcher! root name (launcher-sh-stock rt) (launcher-ps1-stock rt))
              (write-pack-manifest! root name version rt entry mainp ver mt #f)))
        (printf "packed ~a ~a -> ~a~%" name version root)
        0)))

  ;; <prefix>/<mt>/chandler/<sub>.so → <pack>/<mt>/chandler/<sub>.so(只 runtime 子集;
  ;; umbrella chandler.so 是 dev facade,不进)。前缀里没有或版本不合区间即当场停:
  ;; 这类缺失到启动才暴露的话,报的是 `library (chandler runtime-paths) not found`。
  (define (copy-chandler-into-pack! objdir range)
    (let* ([prefix (global-prefix)]
           [have (installed-chandler-version prefix)]
           [from (join-paths prefix (current-machine-type) "chandler")])
      (unless have
        (error 'pack (format "manifest requires chandler ~s but none is installed at ~a" range prefix)))
      (unless (version-match? range have)
        (error 'pack (format "manifest requires chandler ~s, but ~a has ~a" range prefix have)))
      (unless (file-directory? from)
        (error 'pack
               (format "~a has no compiled chandler objects (reinstall chandler so <prefix>/~a/chandler/ exists)"
                       prefix (current-machine-type))))
      (let ([n 0])
        (for-each
          (lambda (e)
            (let ([p (join-paths from e)])
              (when (and (not (file-directory? p))
                         (string-suffix? ".so" e)
                         (not (chandler-dev-only-rel? (string-append "chandler/" e))))
                (let ([dst (join-paths objdir "chandler" e)])
                  (ensure-parent dst) (copy-file p dst) (set! n (+ n 1))))))
          (dir-entries from))
        (when (= n 0)
          (error 'pack (format "no chandler runtime objects found in ~a" from))))))

  (define (copy-exe! src dst)
    (ensure-parent dst)
    (copy-file src dst)
    (run-status "chmod" (list "+x" dst)))

  ;; manifest 声明了 (skiff …) 门 → 捆 skiff;否则 stock petite(部署态只 fasl 载入
  ;; 预编译 .so,不需要编译器,包更小)。--runtime 覆盖。
  (define (default-runtime mf)
    (if (and mf (manifest-skiff mf)) 'skiff 'petite))

  (define (project-locked-deps project)
    (let ([lpath (project-lock-path project)])
      (if (file-exists? lpath) (lock-deps (read-lock lpath)) '())))

  ;; ── 前置校验:pack 只组装。缺什么就说清楚该跑哪个命令补 ──
  ;; C0:每个依赖各有自己的对象树(_vendor/<dep>/<srcdir>/_build/<mt>/),故逐依赖查,
  ;; 报错也能指名道姓「是哪个依赖没编」——比先前一句笼统的「lib/<mt> 不在」可操作。
  (define (preflight project mt locked)
    (let ([bdir (join-paths project "_build" mt)])
      (unless (file-directory? bdir)
        (error 'pack
               (format "~a not found; the application itself is not compiled -- run `chandler build` first" bdir)))
      (for-each
        (lambda (d)
          (let* ([n   (symbol->string (locked-dep-name d))]
                 [obj (dep-obj-dir project d)])
            (unless (file-directory? obj)
              (error 'pack
                     (format "~a not compiled (~a not found) -- run `chandler build` first" n obj)))
            (unless (or (file-exists? (join-paths obj (string-append n ".so")))
                        (file-directory? (join-paths obj n)))
              (error 'pack
                     (format "dependency ~a has no compiled objects in ~a -- run `chandler build`" n obj)))
            ;; native 无法在消费方现编,故缺了必须当场停 —— 否则打出的包会一路正常,
            ;; 直到第一次 foreign call 才炸。
            (let ([miss (missing-dep-natives obj (list d))])
              (unless (null? miss)
                (error 'pack
                       (format "declared native libraries are missing -- run `chandler build --allow-build`:~%  ~a"
                               (string-join miss "\n  ")))))))
        locked)))

  ;; ═══════════════════════════════════════════════════════════════════
  ;; §9 verify-pack:完整性 + (可选)format/target 校验(designs/09 §9, 10 §7)
  ;;   完整性:重算清单里每个文件的 sha256 + size 并比对;MISSING/CHANGED 致命,
  ;;   EXTRA 只报告。L1 加两块(designs/10 §7):
  ;;     verify-format!       (format N) > pack-format-supported(=1)→ 70;
  ;;     --target             对当前 runtime 跑 designs/10 §4 全矩阵 → 78。
  ;;   退出码(sysexits):0 全过;65 完整性错(EX_DATAERR,对齐 skiff/app.ss);
  ;;   70 format 超出(EX_SOFTWARE);78 --target 不符(EX_CONFIG)。
  ;;   与 bootstrap 共用措辞与单行 s-expr 诊断(那边是自含生成码,这边直调
  ;;   (chandler runtime)/(chandler version);决策表是同一份)。
  ;; ═══════════════════════════════════════════════════════════════════

  (define pack-format-supported 1)

  (define (%pack-err msg)
    (fprintf (current-error-port) "chandler-pack: ~a~%" msg)
    (flush-output-port (current-error-port)))

  (define (%pack-err-sexp s)
    (fprintf (current-error-port) "~s~%" s)
    (flush-output-port (current-error-port)))

  (define (pack-field1 fields key)
    (let ([c (assq key fields)])
      (and c (pair? (cdr c)) (cadr c))))

  ;; (format N) 前向兼容:N > pack-format-supported(=1)→ 70 EX_SOFTWARE;
  ;; 字段缺省视为 0(对齐 bootstrap 的 verify-format-src)。返回 #f(通过)或 70。
  (define (verify-pack-format! fields)
    (let ([fmt (or (pack-field1 fields 'format) 0)])
      (and (number? fmt) (> fmt pack-format-supported)
           (begin
             (%pack-err (format "pack format ~a is newer than supported (~a)"
                                fmt pack-format-supported))
             (%pack-err-sexp (list 'chandler-pack-error
                                   (list 'format-too-new
                                         (list 'pack fmt)
                                         (list 'supported pack-format-supported))))
             70))))

  ;; 完整性:MISSING/CHANGED 记 bad,EXTRA 只报告。返回 bad 计数。
  (define (verify-pack-integrity! root files)
    (let ([declared '()] [ok 0] [bad 0] [extra 0])
      (for-each
        (lambda (e)
          (let* ([rel (car e)]
                 [want-h (attr 'sha256 e)]
                 [want-s (attr 'size e)]
                 [abs (join-paths root rel)])
            (set! declared (cons rel declared))
            (cond
              [(not (file-exists? abs))
               (set! bad (+ bad 1)) (fprintf (current-error-port) "  MISSING ~a~%" rel)]
              [(and want-h (not (string=? want-h (sha256-file abs))))
               (set! bad (+ bad 1)) (fprintf (current-error-port) "  CHANGED ~a (sha256 mismatch)~%" rel)]
              [(and want-s (not (= want-s (file-size abs))))
               (set! bad (+ bad 1)) (fprintf (current-error-port) "  CHANGED ~a (size mismatch)~%" rel)]
              [else (set! ok (+ ok 1))])))
        files)
      ;; pack.manifest 自己从不被声明(最后写),排除掉
      (for-each
        (lambda (abs)
          (let ([rel (strip-prefix abs (string-append root "/"))])
            (unless (or (string=? rel "pack.manifest") (member rel declared))
              (set! extra (+ extra 1))
              (fprintf (current-error-port) "  EXTRA ~a (not in manifest)~%" rel))))
        (files-under root))
      (printf "verify ~a: ~a ok, ~a bad, ~a extra~%" root ok bad extra)
      bad))

  ;; runtime-aware verify-target!(designs/10 §4 矩阵,与 bootstrap 的
  ;; full-target-check-src 同决策、同措辞):
  ;;   - machine-type / chez-version 永不放宽,不符即 78 EX_CONFIG;
  ;;   - (skiff-version "X") 精确:runtime 是 skiff 则值比对;是 stock 则必 78;
  ;;   - (skiff-compat "<range>") 非全开:runtime 是 skiff 则 version-match?;
  ;;     是 stock 则必 78;全开 ">=0.0.0"(stock 包默认)在两种 runtime 上都过;
  ;;   - 两者都不声明:不查 skiff;
  ;;   - SKIFF_ALLOW_VERSION_SKEW=1 只放宽 skiff 维(WARNING + 通过);
  ;;   - 缺 (target …) → 65 EX_DATAERR。
  ;; 全部不符项收集后一次性出人读诊断 + 单行 s-expr。返回 #f(通过)或退出码。
  (define (verify-pack-target! fields)
    (let ([target (assq 'target fields)])
      (cond
        [(not target)
         (%pack-err "manifest missing (target ...)")
         (%pack-err-sexp '(chandler-pack-error (manifest-invalid (target-missing))))
         65]
        [else
         (let* ([tfields (cdr target)]
                [want-mt (pack-field1 tfields 'machine-type)]
                [want-chez (pack-field1 tfields 'chez-version)]
                [want-skiff (pack-field1 tfields 'skiff-version)]
                [want-compat (pack-field1 tfields 'skiff-compat)]
                [rt (current-runtime)]
                [actual-mt (machine-type)]
                [actual-chez (chez-version-string)]
                [skew-ok? (equal? (getenv "SKIFF_ALLOW_VERSION_SKEW") "1")]
                [bad '()]
                [mismatch! (lambda (what expected actual advice)
                             (set! bad (cons (list what expected actual advice) bad)))])
           (unless (eq? want-mt actual-mt)
             (mismatch! 'machine-type want-mt actual-mt
                        "wrong platform pack; fetch the build for this machine-type"))
           (unless (equal? want-chez actual-chez)
             (mismatch! 'chez-version want-chez actual-chez
                        "install the matching runtime or re-pack the app"))
           (cond
             [(and want-skiff (string? want-skiff))
              (if (eq? rt 'skiff)
                  (let ([actual (runtime-version)])
                    (unless (equal? actual want-skiff)
                      (if skew-ok?
                          (%pack-err (format "WARNING: skiff-version skew allowed by SKIFF_ALLOW_VERSION_SKEW=1 (pack ~a, runtime ~a)"
                                             want-skiff actual))
                          (mismatch! 'skiff-version want-skiff actual
                                     "install the matching skiff runtime or re-pack the app"))))
                  (mismatch! 'skiff-version want-skiff 'stock-chez
                             "pack requires skiff, current runtime is stock Chez"))]
             [(and want-compat (string? want-compat)
                   (not (string=? want-compat ">=0.0.0")))
              (if (eq? rt 'skiff)
                  (let ([actual (runtime-version)])
                    (unless (and actual (version-match? want-compat actual))
                      (if skew-ok?
                          (%pack-err (format "WARNING: skiff-version skew allowed by SKIFF_ALLOW_VERSION_SKEW=1 (pack compat ~a, runtime ~a)"
                                             want-compat actual))
                          (mismatch! 'skiff-version (string-append "compat " want-compat) actual
                                     "install the matching skiff runtime or re-pack the app"))))
                  (mismatch! 'skiff-version (string-append "compat " want-compat) 'stock-chez
                             "pack requires skiff, current runtime is stock Chez"))]
             [else #t])
           (if (null? bad)
               #f
               (begin
                 (%pack-err "pack target mismatch; refusing to load")
                 (for-each
                   (lambda (b)
                     (%pack-err (format "  ~a: expected ~s, actual ~s~%    -> ~a"
                                        (car b) (cadr b) (caddr b) (cadddr b))))
                   (reverse bad))
                 (%pack-err-sexp
                   (cons 'chandler-pack-error
                         (list (cons 'target-mismatch
                                     (map (lambda (b)
                                            (list (car b)
                                                  (list 'expected (cadr b))
                                                  (list 'actual (caddr b))))
                                          (reverse bad))))))
                 78)))])))

  ;; verify-pack path [target?] → 退出码。顺序:format → 完整性 → --target
  ;; (format 太新时清单结构不可信,先于一切;--target 是「这包能不能在本机跑」
  ;; 的附加检查,只在完整性过关后有意义)。
  (define (verify-pack path . maybe-target?)
    (let ([target? (and (pair? maybe-target?) (car maybe-target?))])
      (let* ([is-mf (string-suffix? "pack.manifest" path)]
             [root  (if is-mf (parent-dir path) path)]
             [mf    (if is-mf path (join-paths path "pack.manifest"))])
        (unless (file-exists? mf)
          (error 'verify-pack (format "pack.manifest not found at ~a" mf)))
        (let* ([form  (call-with-input-file mf read)]
               [fields (cdr form)]
               [files (let ([c (assq 'files fields)]) (if c (cdr c) '()))])
          (or (verify-pack-format! fields)
              (let ([bad (verify-pack-integrity! root files)])
                (cond
                  [(> bad 0) 65]
                  [target? (or (verify-pack-target! fields) 0)]
                  [else 0])))))))

  (define (attr key e)
    (let ([c (assq key (cdr e))]) (and c (cadr c)))))
