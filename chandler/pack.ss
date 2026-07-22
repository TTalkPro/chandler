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
;;;     lib/<mt>/                    对象根 = 应用 _build/<mt>/ + 依赖 lib/<mt>/
;;;     resources/                   应用数据,原样(名字约定死,不可配置)
;;;     pack.manifest
;;;
;;; 四态同构是这个布局的全部理由:_build/<mt>(build)、<prefix>/<mt>(install)、
;;; lib/<mt>(chandler)、lib/<mt>(pack)结构完全一致 —— 包里的 lib/<mt>/ 就是一个普通
;;; 对象根,chandler 铺好的依赖树整棵拷进去即可;运行时也不再与库名空间混住。

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
          (chandler runtime)
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
  (define (pack-lib-dir  root) (join-paths root "lib" (current-machine-type)))

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
  (define (copy-dep-trees! obj to locked)
    (let ([nx (string-append "." (so-ext))])
      (for-each
        (lambda (d)
          (let* ([ns (symbol->string (locked-dep-name d))]
                 [um (join-paths obj (string-append ns ".so"))]
                 [dir (join-paths obj ns)])
            (when (file-exists? um)
              (let ([dst (join-paths to (string-append ns ".so"))])
                (ensure-parent dst) (copy-file um dst)))
            (when (file-directory? dir)
              (for-each
                (lambda (abs)
                  (let ([rel (strip-prefix abs (string-append obj "/"))])
                    (when (and (deliverable? rel)
                               (or (string-suffix? ".so" rel) (string-suffix? nx rel)))
                      (let ([dst (join-paths to rel)])
                        (ensure-parent dst) (copy-file abs dst)))))
                (files-under dir)))))
        locked)))

  ;; resources/:应用数据,原样。名字**约定死**,不设子句 —— 数据不带 ABI,故在 <mt> 层
  ;; 之上(同一份被该应用的所有平台包共用;放进 lib/<mt>/ 反而会进库搜索根)。
  (define (copy-resources! project root)
    (let ([src (join-paths project "resources")])
      (and (file-directory? src)
           (let ([n 0])
             (for-each
               (lambda (abs)
                 (let ([dst (join-paths root "resources" (strip-prefix abs (string-append src "/")))])
                   (ensure-parent dst)
                   (copy-file abs dst)
                   (set! n (+ n 1))))
               (files-under src))
             (> n 0)))))

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
  ;;     $APP_ROOT/lib/<mt>/<libpath>/native/   生成的 loader 自己拼(designs/24)
  ;;     $APP_ROOT/resources/                    应用数据(名字约定死)
  ;;   故不存在 per-library 的 native 变量(旧 BAKE_NATIVE_<LIB> 那族按库名大写造
  ;;   变量名),也不存在单独的 resources 变量 —— 布局钉死之后,唯一无法推导的信息
  ;;   就只剩「这个包被解到哪儿了」。
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

  ;; skiff 启动器 = pack 规范 §8 的薄 shim:指好 boot、交给 `skiff --app`。
  ;; SKIFF_BOOT_DIR 是必须的:skiff 按 exe 相对找 boot(<exedir>/../lib/skiff/boot),
  ;; bin/<mt> + boot/<mt> 对不上它;而 boot 必须在进程有堆之前注册,远早于 --app 被
  ;; 解析,env 是唯一可用的交接方式。
  (define (launcher-sh-skiff)
    (let ([mt (current-machine-type)])
      (string-append
        (sh-head)
        "export SKIFF_BOOT_DIR=\"$HERE/boot/" mt "\"\n"
        "exec \"$HERE/bin/" mt "/skiff\" --app \"$HERE/pack.manifest\" \"$@\"\n")))

  (define (launcher-ps1-skiff)
    (let ([mt (current-machine-type)])
      (string-append
        (ps1-head)
        "$env:SKIFF_BOOT_DIR = \"$Here/boot/" mt "\"\n"
        "& \"$Here/bin/" mt "/skiff.exe\" --app \"$Here/pack.manifest\" @PackArgs\n"
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
  ;; §6 bootstrap.ss(仅 stock 运行时;skiff 的加载全在 `skiff --app` 里)
  ;; ═══════════════════════════════════════════════════════════════════

  ;; 包根从**自身路径**推导 —— bootstrap 由 `--script` 跑,(car (command-line)) 就是
  ;; 它自己,dirname 即包根。这正是 chandler-setup.ss 用的同一招,故无需任何 env。
  (define bootstrap-root-src
    (string-append
      "(define %root\n"
      "  (let* ((self (car (command-line)))\n"
      "         (d (let loop ((i (- (string-length self) 1)))\n"
      "              (cond ((< i 0) \".\")\n"
      "                    ((char=? #\\/ (string-ref self i)) (substring self 0 i))\n"
      "                    (else (loop (- i 1)))))))\n"
      "    (if (string=? d \"\") \".\" d)))\n"))

  ;; 启动即比对目标三元组。运行时是捆进来的,正常永远成立;它抓的是「换掉了
  ;; bin/<mt>/scheme」或「补丁进了异 ABI 产物」—— 给出清晰错误而非莫名的 fasl 失败。
  (define (target-check-src ver mt)
    (string-append
      "(let* ((s (scheme-version)) (n (string-length s))\n"
      "       (v (let loop ((i (- n 1)))\n"
      "            (cond ((< i 0) s)\n"
      "                  ((char-whitespace? (string-ref s i)) (substring s (+ i 1) n))\n"
      "                  (else (loop (- i 1)))))))\n"
      "  (unless (string=? v \"" ver "\")\n"
      "    (error 'chandler-pack (string-append \"chez version mismatch: pack built for "
      ver ", runtime is \" v)))\n"
      "  (unless (eq? (machine-type) '" mt ")\n"
      "    (error 'chandler-pack \"machine-type mismatch: pack built for " mt "\")))\n"))

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

  (define (bootstrap-source entry main-proc ver mt)
    (string-append
      ";; generated by chandler pack -- do not edit\n"
      bootstrap-root-src
      (target-check-src ver mt)
      "(define %lib (string-append %root \"/lib/" mt "\"))\n"
      "(compile-imported-libraries #f)\n"       ; 部署态只载入,永不重编
      "(library-directories (list (cons %lib %lib)))\n"
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
        "  (mode modules)\n"
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
        "  (lib-dirs \"lib/" mt "\")\n"
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
                                             " \"lib/" mt "/" rel "/native/" f "\")\n"))
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

  ;; opts: (mode . modules|boot) (runtime . skiff|scheme|petite) (out . dir)
  ;;       (name . s) (version . s) (entry . lib-ref) (main . sym)
  (define (pack project opts)
    (let* ([mpath (project-manifest-path project)]
           [mf    (and (file-exists? mpath) (read-manifest mpath))]
           [name  (or (alist-ref opts 'name) (and mf (manifest-name mf))
                      (error 'pack "cannot determine app name (no manifest.ss; pass --name)"))]
           [version (or (alist-ref opts 'version) (and mf (manifest-version mf)) "0.0.0")]
           [entry (or (alist-ref opts 'entry) (list (string->symbol name)))]
           [mainp (or (alist-ref opts 'main) 'main)]
           [mode  (or (alist-ref opts 'mode) 'modules)]
           [rt    (or (alist-ref opts 'runtime) (default-runtime mf))]
           [out   (or (alist-ref opts 'out) "dist")]
           [mt    (current-machine-type)])
      (unless (memq rt '(skiff scheme petite))
        (error 'pack (format "runtime ~s not supported (skiff | scheme | petite)" rt)))
      (unless (eq? mode 'modules)
        ;; K4:boot 模式要「生成入口 stub → compile-file → 拓扑排序 → make-boot-file」,
        ;; 编译动作归 bake(designs/07 §1),故走「生成 recipe 跑 bake boot-task」,同
        ;; `chandler build`。尚未实现 —— 配置期就报,别让人跑完才发现。
        (error 'pack (format "mode ~s not implemented yet (only `modules`; see designs/09 K4)" mode)))
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
        (let ([deps (project-obj-dir project)])
          (when (file-directory? deps) (copy-dep-trees! deps objdir locked)))
        (copy-obj-tree! (join-paths project "_build" mt) objdir)
        ;; 2) resources/(约定名)
        (copy-resources! project root)
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
              (write-text (join-paths root "bootstrap.ss") (bootstrap-source entry mainp ver mt))
              (write-launcher! root name (launcher-sh-stock rt) (launcher-ps1-stock rt))
              (write-pack-manifest! root name version rt entry mainp ver mt #f)))
        (printf "packed ~a ~a -> ~a~%" name version root)
        0)))

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
  (define (preflight project mt locked)
    (let ([bdir  (join-paths project "_build" mt)]
          [obj   (project-obj-dir project)])
      (unless (file-directory? bdir)
        (error 'pack
               (format "~a not found; the application itself is not compiled -- run `bake build` first" bdir)))
      (begin
        (begin
          (unless (null? locked)
            (unless (file-directory? obj)
              (error 'pack
                     (format "~a not found; dependencies are not compiled -- run `chandler build` first" obj)))
            (let ([missing (filter (lambda (d)
                                     (let ([n (symbol->string (locked-dep-name d))])
                                       (not (or (file-exists? (join-paths obj (string-append n ".so")))
                                                (file-directory? (join-paths obj n))))))
                                   locked)])
              (unless (null? missing)
                (error 'pack
                       (format "these dependencies have no compiled objects in ~a -- run `chandler build`: ~a"
                               obj
                               (string-join (map (lambda (d) (symbol->string (locked-dep-name d))) missing)
                                            ", ")))))
            ;; native 无法在消费方现编,故缺了必须当场停 —— 否则打出的包会一路正常,
            ;; 直到第一次 foreign call 才炸。
            (let ([miss (missing-dep-natives obj locked)])
              (unless (null? miss)
                (error 'pack
                       (format "declared native libraries are missing -- run `chandler build --allow-build`:~%  ~a"
                               (string-join miss "\n  "))))))))))

  ;; ═══════════════════════════════════════════════════════════════════
  ;; §9 verify-pack:按需完整性校验
  ;;   重算清单里每个文件的 sha256 + size 并比对。MISSING/CHANGED 致命,EXTRA 只报告。
  ;; ═══════════════════════════════════════════════════════════════════

  (define (verify-pack path)
    (let* ([is-mf (string-suffix? "pack.manifest" path)]
           [root  (if is-mf (parent-dir path) path)]
           [mf    (if is-mf path (join-paths path "pack.manifest"))])
      (unless (file-exists? mf)
        (error 'verify-pack (format "pack.manifest not found at ~a" mf)))
      (let* ([form  (call-with-input-file mf read)]
             [files (let ([c (assq 'files (cdr form))]) (if c (cdr c) '()))]
             [declared '()]
             [ok 0] [bad 0] [extra 0])
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
        (if (= bad 0) 0 70))))

  (define (attr key e)
    (let ([c (assq key (cdr e))]) (and c (cadr c)))))
