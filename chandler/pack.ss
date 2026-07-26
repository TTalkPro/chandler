#!chezscheme
;;; chandler/pack.ss --- `chandler pack`:无源码、可重定位、自包含的分发包(designs/05)
;;;
;;; 打包是「依赖闭包 + 部署」,lock 精确知道闭包与每个依赖的 native。**pack 只组装,
;;; 不编译** —— 编译由 chandler build 进程内完成,pack 仅消费已编对象与 source;
;;; native 无法在消费方现编,必须先在本机 build 完毕(designs/05 §10)。
;;;
;;; 包布局(FHS 式,dist/<name>-<version>-<mt>/;仿 ~/.local/{share/chez,bin,lib}):
;;;
;;;   myapp-1.0-ta6le/
;;;     bin/myapp[.ps1]            启动器 —— 唯一平台中立入口
;;;     bin/skiff|scheme[.exe]     bundled runtime 可执行文件
;;;     lib/chez/*.boot            boot 文件(ABI 绑定)
;;;     share/chez/                载荷根 = install 的 libdir(I2 by construction)
;;;       myapp/1.0/{src,ta6le}/   应用源码+资源(method B)与编译产物+native
;;;       myapp/1.0/.chandler/     manifest/lock 快照 + run.sps(pack 模式)
;;;       <dep>/<pin>/{src,ta6le}/ 依赖闭包(版本目录名 = lock 的 pin val)
;;;       chandler/<version>/      chandler runtime 子集(运行时门)
;;;     pack.manifest              目标三元组 + native 清单 + files+sha256
;;;
;;; 布局与**全局安装前缀** `~/.local/share/chez/` 逐层同构:pack 解开就是一个自带
;;; 运行时的安装前缀,消费方(应用代码、native loader、chandler 自己)各态用同一套
;;; 路径规则,不需要「pack 专用」的第二套。<mt> 已在包名里,bin/boot 下不再嵌 <mt> 层。

(library (chandler pack)
  (export pack verify-pack run-sps-content)
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

  ;; FHS 式包内布局(designs/05):载荷走 install 同一管线 → share/chez/;
  ;; envelope(运行时 exe / boot / 启动器)在 bin/ 与 lib/chez/。
  ;; <mt> 已在包名里(<name>-<ver>-<mt>),bin/boot 下不再嵌 <mt> 层。
  (define (pack-libdir root) (join-paths root "share" "chez"))
  (define (pack-bin-dir  root) (join-paths root "bin"))
  (define (pack-boot-dir root) (join-paths root "lib" "chez"))

  (define (windows-target?) (string-suffix? "nt" (current-machine-type)))

  ;; 可执行文件在 Windows 上必须带 .exe —— .ps1 启动器按全名调用,无扩展名跑不起来
  (define (exe-name base) (if (windows-target?) (string-append base ".exe") base))

  ;; ═══════════════════════════════════════════════════════════════════
  ;; §3 清单快照 + 依赖路径
  ;; ═══════════════════════════════════════════════════════════════════

  (define (datum->str d)
    (let ([op (open-output-string)]) (write d op) (get-output-string op)))

  ;; .chandler/chandler-manifest.ss —— 应用清单快照,落在
  ;; <libdir>/<name>/<version>/.chandler/chandler-manifest.ss,与 install 字节级统一。
  ;; 项目有 chandler-manifest.ss 时 install-project-payload! 已拷过(幂等);
  ;; 没有(--name/--entry 临时打包)则合成一份最小清单。
  (define (write-app-manifest! project libdir app version entry main-proc)
    (let* ([vr (version-root libdir app version)]
           [dir (join-paths vr ".chandler")]
           [dst (join-paths dir "chandler-manifest.ss")]
           [src (project-manifest-path project)])
      (ensure-dir dir)
      (if (file-exists? src)
          (copy-file src dst)
          (write-text dst
            (string-append
              ";; generated by chandler pack -- no chandler-manifest.ss in the source project\n"
              "(manifest (format 1) (name \"" app "\") (version \"" version "\")\n"
              "  (app (entry " (datum->str entry) ") (main " (symbol->string main-proc) ")))\n")))))

  ;; 一个依赖在 _vendor 里的源码根(= 它的库搜索根,也是 `chandler build` 的 cwd)
  (define (dep-src-root project d)
    (vendor-dir project (locked-dep-name d)))

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
  ;;   **不设任何路径 env**(D8:APP_ROOT 已去除)—— 库搜索走 `--libdirs`
  ;;   挂上的 <mt>/ 对象根,native 与资源都由生成的 loader / resource-path
  ;;   扫 (library-directories) 定位。
  ;; ═══════════════════════════════════════════════════════════════════

  (define (sh-head)
    (string-append
      "#!/bin/sh\n"
      "# generated by chandler pack -- do not edit\n"
      "HERE=$(CDPATH= cd -- \"$(dirname -- \"$0\")/..\" && pwd)\n"))

  (define (ps1-head)
    ;; PowerShell 无 exec,故每个启动器都以重抛 $LASTEXITCODE 收尾;$args 在函数内是
    ;; 该函数的参数,故顶层先捕获再 splat;PS 7.3+ 原生命令非零退出会抛,显式关掉。
    (string-append
      "#!/usr/bin/env pwsh\n"
      "# generated by chandler pack -- do not edit\n"
      "$PSNativeCommandUseErrorActionPreference = $false\n"
      "$PackArgs = $args\n"
      "$Here = Split-Path -Parent $PSScriptRoot\n"))

;; skiff 启动器 = pack 规范的薄 shim:指好 boot,直接 `exec skiff --program run.sps`
;; (与 stock 启动器同构 —— 各自指好 runtime + boot,通过 --program 跑 run.sps;
;; skiff pack 不再走 `skiff --app`)。SKIFF_BOOT_DIR 是必须的:skiff 按 exe 相对找
;; boot(<exedir>/../lib/skiff/boot),包内 bin/ + lib/chez/ 对不上它;而 boot 必须在
;; 进程有堆之前注册,远早于 --program 被解析,env 是唯一可用的交接方式。
  (define (launcher-sh-skiff name version)
    (let ([runner (string-append "share/chez/" name "/" version "/.chandler/run.sps")])
      (string-append
        (sh-head)
        "export SKIFF_BOOT_DIR=\"$HERE/lib/chez\"\n"
        "exec \"$HERE/bin/skiff\" -q --program \"$HERE/" runner "\" \"$@\"\n")))

  (define (launcher-ps1-skiff name version)
    (let ([runner (string-append "share/chez/" name "/" version "/.chandler/run.sps")])
      (string-append
        (ps1-head)
        "$env:SKIFF_BOOT_DIR = \"$Here/lib/chez\"\n"
        "& \"$Here/bin/skiff.exe\" -q --program \"$Here/" runner "\" @PackArgs\n"
        "exit $LASTEXITCODE\n")))

  ;; stock Chez:绝对 -b 链(bake designs/22 机制 C —— 最稳,exe 名任意,相对 -b 不可用)。
  ;; petite.boot 恒随;scheme.boot 只在 runtime=scheme 时随(部署态只 fasl 载入预编译
  ;; .so,petite 单独即可,包更小)。
  (define (boots-flags runtime prefix)
    (let ([p (string-append prefix "/lib/chez/")])
      (string-append "-b \"" p "petite.boot\""
                     (if (eq? runtime 'scheme) (string-append " -b \"" p "scheme.boot\"") ""))))

  (define (launcher-sh-stock runtime name version)
    (let ([runner (string-append "share/chez/" name "/" version "/.chandler/run.sps")])
      (string-append
        (sh-head)
        "exec \"$HERE/bin/scheme\" "
        (boots-flags runtime "$HERE")
        " -q --program \"$HERE/" runner "\" \"$@\"\n")))

  (define (launcher-ps1-stock runtime name version)
    (let ([runner (string-append "share/chez/" name "/" version "/.chandler/run.sps")])
      (string-append
        (ps1-head)
        "& \"$Here/bin/scheme.exe\" "
        (boots-flags runtime "$Here")
        " -q --program \"$Here/" runner "\" @PackArgs\n"
        "exit $LASTEXITCODE\n")))

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
;; §6 pack 模式 run.sps 的内联段(runtime-aware verifier)
;;   pack 模式的 run.sps 在 install 模式之上追加:
;;     stderr-diag + runtime-detect + version-match + manifest-read
;;     + verify-format + full-target-check + native-walk
;;   都在 stock Chez 与 Skiff 上跑**同一份** —— 先读 pack.manifest,校验 (format N)
;;   与 target 三元组(按当前 runtime 分派,矩阵见 designs/05 §verify-pack),
;;   全部通过才碰 library-directories / native / import。校验失败一律显式
;;   (exit N)(sysexits:65/70/78)+ 单行 s-expr 诊断,不走 Chez error。
;;   不再单独生成 bootstrap.ss —— verifier 直接内联进 run.sps。
;; ═══════════════════════════════════════════════════════════════════

;; 包根推导:run.sps 恒在 <libdir>/<name>/<version>/.chandler/run.sps → 4× path-parent
;; = %root(install 模式 = libdir;pack 模式 = share/chez)。pack.manifest 在包根,
;; 即 %root 再上两层(见 manifest-read-src 的 %pack-root)。

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
      ;; %root = share/chez(库前缀);pack.manifest 在包根 = 再上两层。
      "(define %pack-root (path-parent (path-parent %root)))\n"
      "(define %manifest-path (string-append %pack-root \"/pack.manifest\"))\n"
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

  ;; run-sps-content:生成统一 run.sps,install/pack 模式共用。
  ;;
  ;; v3(D18):lock 驱动 —— 不再 scan-libdirs 全扫,而是读 chandler-manifest.lock
  ;; 拿精确 deps,只挂 lock 声明的版本。这样多版本 lib 共存时,app A 用 1.0.0、
  ;; app B 用 2.0.0,互不干扰(Chez 不会看到不相关的版本)。
  ;;
  ;; 根推导:run.sps 恒在 <root>/<name>/<version>/.chandler/run.sps → 4× path-parent → <root>
  ;;   install 模式:<root> = libdir
  ;;   pack 模式:<root> = pack-root
  ;;
  ;; pack 模式追加:pack.manifest 校验 + native 加载。
  (define (run-sps-content entry main . mode)
    (let ([entry-str (string-join (map symbol->string entry) " ")]
          [main-str (symbol->string main)]
          [pack? (and (pair? mode) (eq? (car mode) 'pack))])
      (string-append
        "(import (chezscheme))\n"
        ";; runner generated by chandler v3 (lock-driven) -- do not edit\n"
        ;; ── 根推导 ──
        "(define %runner (car (command-line)))\n"
        "(define %dot-chandler (path-parent %runner))\n"
        "(define %version-dir (path-parent %dot-chandler))\n"
        "(define %name-dir (path-parent %version-dir))\n"
        "(define %root (path-parent %name-dir))\n"
        "(define %mt (symbol->string (machine-type)))\n"
        ;; ── lock 驱动:读 chandler-manifest.lock,挂精确 dep 版本 ──
        ;; 零依赖项目没有 lock 文件(deps 从未需要写)→ 视为空闭包,不算错误。
        "(define %lock-path (string-append %dot-chandler \"/chandler-manifest.lock\"))\n"
        "(define %lock-datum (and (file-exists? %lock-path)\n"
        "                         (call-with-input-file %lock-path read)))\n"
        ;; lock datum = (lock (format 1) (manifest-sha256 ...) (chandler ...)
        ;;               (resolved (dep1 ...) (dep2 ...) ...) [(files ...)])
        ;; 我们要 (resolved ...) 各项的 (name (pin (kind "val")) ...)
        "(define (lock-resolved body)\n"
        "  (let loop ([xs body])\n"
        "    (cond\n"
        "      [(null? xs) '()]\n"
        "      [(and (pair? (car xs)) (eq? 'resolved (caar xs))) (cdr (car xs))]\n"
        "      [else (loop (cdr xs))])))\n"
        "(define (dep-name+version entry)\n"
        "  ;; entry: (name (source ...) (pin (kind \"val\")) (rev ...) ...)\n"
        "  ;; 版本目录名 = pin 的 val(与 locked-dep-pin-val / install 布局一致),\n"
        "  ;; 不是顶层的 (rev \"hash\") —— 那是内容寻址,不是目录名。\n"
        "  (let* ([name (car entry)]\n"
        "         [pin-field (let loop ([xs (cdr entry)])\n"
        "                      (cond\n"
        "                        [(null? xs) #f]\n"
        "                        [(and (pair? (car xs)) (eq? (caar xs) 'pin))\n"
        "                         (car xs)]\n"
        "                        [else (loop (cdr xs))]))]\n"
        "         [inner (and pin-field (pair? (cdr pin-field)) (cadr pin-field))]\n"
        "         [pin-val (and inner (pair? inner) (pair? (cdr inner)) (cadr inner))])\n"
        "    (cons name pin-val)))\n"
        "(define %lock-body (if %lock-datum (cdr %lock-datum) '()))\n"
        "(define %resolved (lock-resolved %lock-body))\n"
        "(define %dep-pairs\n"
        "  (map (lambda (e)\n"
        "         (let* ([nv (dep-name+version e)]\n"
        "                [n (symbol->string (car nv))]\n"
        "                [v (cdr nv)])\n"
        "           (and v\n"
        "                (let* ([vroot (string-append %root \"/\" n \"/\" v)]\n"
        "                       [src (string-append vroot \"/src\")]\n"
        "                       [obj (string-append vroot \"/\" %mt)])\n"
        "                  (if (file-directory? src) (cons src obj) #f)))))\n"
        "       %resolved))\n"
        ;; 自己的 vroot 对(src . obj)
        "(define %self-pair\n"
        "  (cons (string-append %version-dir \"/src\")\n"
        "        (string-append %version-dir \"/\" %mt)))\n"
        "(library-directories\n"
        "  (cons %self-pair\n"
        "        (filter (lambda (x) x) %dep-pairs)))\n"
        ;; ── pack 额外段:校验 + native ──
        (if pack? stderr-diag-src "")
        (if pack? runtime-detect-src "")
        (if pack? version-match-src "")
        (if pack? manifest-read-src "")
        (if pack? verify-format-src "")
        (if pack? full-target-check-src "")
        (if pack? "(compile-imported-libraries #f)\n" "")
        (if pack? native-walk-src "")
        (if pack? "(%load-natives %root)\n" "")
        ;; ── 入口(共享) ──
        ;; args 必须 quote:(list 'main args) 会把实参表当 form 求值
        ;; (变成把 "--version" 当过程 apply)。契约:main 接收整个 argv 表。
        ;; 传退出码:main 契约是 argv → exit-code;不 exit 则启动器包住的 app
        ;; 恒退 0,失败无法被调用方(如 bootstrap 编排)检测。
        ;; env 必须含 (chezscheme):否则 quote/let 等核心语法在 eval 环境里未绑定。
        "(let ([args (cdr (command-line))]\n"
        "      [env (environment '(chezscheme) '(" entry-str "))])\n"
        "  (let ([rc (eval (list '" main-str " (list 'quote args)) env)])\n"
        "    (exit (if (fixnum? rc) rc 0))))\n")))

  ;; ═══════════════════════════════════════════════════════════════════
  ;; §7 pack.manifest
  ;; ═══════════════════════════════════════════════════════════════════

  (define (manifest-head app version runtime entry main-proc ver mt skiff-ver)
    (let ([bootp "lib/chez/"]
          [binp  "bin/"])
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
  ;; 对象根不止一个 —— app 与每个 dep 各有 <libdir>/<name>/<version>/<mt>/,
  ;; 故逐 version-root 扫描;<rel> 相对包根(带 share/chez/ 前缀)。
  (define (manifest-native-lines root)
    (let ([mt (current-machine-type)]
          [libdir (pack-libdir root)]
          [out '()])
      (for-each
        (lambda (name-dir)
          (let ([nd (join-paths libdir name-dir)])
            (when (file-directory? nd)
              (for-each
                (lambda (ver-dir)
                  (let ([obj (join-paths nd ver-dir mt)])
                    (when (file-directory? obj)
                      (for-each
                        (lambda (segs)
                          (let* ([rel (string-join segs "/")]
                                 [ndir (join-paths obj rel "native")]
                                 [pre (string-append "share/chez/" name-dir "/" ver-dir "/" mt "/"
                                                     rel "/native/")])
                            (for-each
                              (lambda (f)
                                (set! out (cons (string-append "    (" (strip-ext f)
                                                               " \"" pre f "\")\n")
                                                out)))
                              (native-files-in ndir))))
                        (native-libs-under obj)))))
                (list-sort string<? (dir-entries nd))))))
        (if (file-directory? libdir) (list-sort string<? (dir-entries libdir)) '()))
      (let ([entries (reverse out)])
        (if (null? entries) "" (string-append "  (native\n" (apply string-append entries) "    )\n")))))

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
                      (error 'pack "cannot determine app name (no chandler-manifest.ss; pass --name)"))]
           [version (or (alist-ref opts 'version) (and mf (manifest-version mf)) "0.0.0")]
           [mapp  (and mf (manifest-app mf))]
           [entry (or (alist-ref opts 'entry) (and mapp (app-entry mapp)))]
           [mainp (or (alist-ref opts 'main) (and mapp (app-main mapp)) 'main)]
           [rt    (or (alist-ref opts 'runtime) (default-runtime mf))]
           [out   (or (alist-ref opts 'out) "dist")]
           [lib?  (alist-ref opts 'lib)]
           [mt    (current-machine-type)])
      ;; pack 服务于**应用**:必须有显式入口。库(manifest 没声明 (app …))不该被打成
      ;; 可执行分发包 —— 它的天然分发形态是 git,消费方 `chandler add` 即可。允许用
      ;; `--entry` 显式覆盖,以便临时打包或 lib→app 演化期;但缺省情况(manifest 没声明
      ;; 且命令行也没传)就直接拒绝,而不是**猜**一个顶层 umbrella。
      ;;
      ;; 这取代了早先的 infer-entry:它把"包名"和"入口库名"混为一谈(skiff-demo 的包名
      ;; 是 skiff-demo、入口库却是 (mdserver)),让 lib 也能被悄无声息地打成 app 包 ——
      ;; 产出一堆无意义的 bin/boot/runtime。
      (unless (or entry lib?)
        (error 'pack
               (string-append
                 "no entry library declared; this looks like a library, not an application.\n"
                 "  `chandler pack` ships runnable applications. For a library, push to git\n"
                 "  and let consumers `chandler add <name> <url>` instead.\n"
                 "  If this is actually an app, declare it in chandler-manifest.ss:\n"
                 "    (app (entry (<lib>)) (main main))\n"
                 "  or pass --entry '(<lib>)' on the command line.")))
      (unless (memq rt '(skiff scheme petite))
        (error 'pack (format "runtime ~s not supported (skiff | scheme | petite)" rt)))
      (let* ([locked (project-locked-deps project)]
             [root (if (and (> (string-length out) 0) (char=? (string-ref out 0) #\/))
                       (join-paths out (pack-dir-name name version))
                       (join-paths project out (pack-dir-name name version)))]
             ;; temp sibling + rename(2026-07-26):全程在 <out>.tmp.<pid>/ 兄弟目录
             ;; 里组装(与 <out> 同文件系统,rename 才原子),完工才换到 <out>/。
             ;; 中途崩溃/失败只留 temp,最终位置绝不留半截包;pid 后缀防并发撞名。
             [tmp-root (string-append root ".tmp." (number->string (get-process-id)))]
             [libdir (pack-libdir tmp-root)])
        (preflight project mt locked)
        (guard (e [#t (rm-rf tmp-root) (raise e)])
        (printf "pack ~a~%" root)
        ;; ── 阶段 1:载荷(与 install 同一管线,I2 by construction)──
        ;; app 自身 + 各 dep 装到 share/chez/<name>/<version>/{src,<mt>}/,
        ;; + manifest/lock 快照;register?=#f → 无 .registry/(可再分发包不带
        ;; 安装机私有状态),无 staging(目录全新),不写 install shim。
        (install-project-payload! project libdir name version entry
                                  (list (cons 'register? #f)))
        ;; chandler 的 runtime 子集:它不是 lock 里的依赖(是运行时门,designs/12 §5),
        ;; 独立在 share/chez/chandler/<version>/。从 `_vendor/chandler/_build/<mt>/` 取
        ;; (deps 期 build-chandler-runtime! 已就地编译;与 build 同源 → 实例一致)。
        (when (and mf (manifest-chandler mf))
          (copy-chandler-into-pack! project libdir (manifest-chandler mf)))
        ;; 清单快照(无源清单时合成最小清单)
        (write-app-manifest! project libdir name version entry mainp)
        ;; 入口库必须真的在包里 —— 否则打出的包一路正常,到启动 import 才报
        ;; "library (x) not found"。这一步把那个失败提前到打包期。
        ;; lib pack 跳过 entry 检查(无 entry);失败由外层 guard 清掉 temp。
        (unless lib?
          (let ([e (join-paths (version-root libdir name version) mt (entry-so-rel entry))])
            (unless (file-exists? e)
              (error 'pack
                     (format "entry library ~a has no compiled object at ~a~%  (pass --entry '(<lib>)', or run `chandler build` if it is simply not built)"
                             entry e)))))
        ;; ── 阶段 2:envelope(仅 app pack;lib pack 到阶段 1 为止)──
        (unless lib?
          ;; pack 模式 run.sps:目标三元组校验 + native 加载在 install 模式之上
          (let ([runner-dir (join-paths (version-root libdir name version) ".chandler")])
            (ensure-dir runner-dir)
            (write-text (join-paths runner-dir "run.sps")
              (run-sps-content entry mainp 'pack)))
          ;; 运行时 exe → bin/,boot → lib/chez/,启动器 → bin/<app>
          (if (eq? rt 'skiff)
            (let* ([exe (skiff-exe-path)]
                   [bd  (skiff-boot-dir exe)]
                   [sv  (probe-skiff-version exe)])
              (copy-exe! exe (join-paths (pack-bin-dir tmp-root) (exe-name "skiff")))
              (for-each (lambda (b) (copy-file (join-paths bd b) (join-paths (pack-boot-dir tmp-root) b)))
                        '("petite.boot" "scheme.boot" "skiff.boot"))
              (write-launcher! tmp-root name (launcher-sh-skiff name version) (launcher-ps1-skiff name version))
              (write-pack-manifest! tmp-root name version rt entry mainp
                                    (probe-chez-version exe) mt sv))
            (let* ([exe (chez-exe-path)]
                   [ver (probe-chez-version exe)]
                   [csv (chez-csv-dir exe ver)])
              (copy-exe! exe (join-paths (pack-bin-dir tmp-root) (exe-name "scheme")))
              (copy-file (join-paths csv "petite.boot") (join-paths (pack-boot-dir tmp-root) "petite.boot"))
              (when (eq? rt 'scheme)
                (copy-file (join-paths csv "scheme.boot") (join-paths (pack-boot-dir tmp-root) "scheme.boot")))
              (write-launcher! tmp-root name (launcher-sh-stock rt name version) (launcher-ps1-stock rt name version))
              (write-pack-manifest! tmp-root name version rt entry mainp ver mt #f)))
            ) ;; close unless lib?
          ;; ── 阶段 3:原子替换 —— temp 完工,换到最终位置 ──
          (commit-pack-output! tmp-root root))
        (printf "packed ~a ~a -> ~a~%" name version root)
        0)))

  ;; 原子替换:tmp-root → root。root 已存在则先 rename 到 <root>.old.<pid> 再删
  ;; (同文件系统内 rename 原子:消费者要么看到旧包要么看到新包,没有半截)。
  ;; Windows 兼容:rename 目标已存在会失败,故 old 先清(带 guard)。
  ;; 回滚:tmp→root 失败则把 old 挪回 root(旧包保住);temp 留给外层 guard 清。
  (define (commit-pack-output! tmp-root root)
    (let ([old (string-append root ".old." (number->string (get-process-id)))])
      (guard (e [#t (void)]) (rm-rf old))
      (if (or (file-exists? root) (file-directory? root))
          (begin
            (rename-file root old)
            (guard (e [#t
                       (guard (e2 [#t (void)]) (rename-file old root))
                       (raise e)])
              (rename-file tmp-root root))
            (rm-rf old))
          (rename-file tmp-root root))))

  ;; _vendor/chandler/_build/<mt>/chandler/<sub>.so → <libdir>/chandler/<version>/<mt>/chandler/<sub>.so。
  ;; **来源 = _vendor/chandler/_build/<mt>/**(BUG-1,2026-07-24):与 build-chandler-runtime!
  ;; 编译产物同源(就地编译 vendored chandler 源码),不再读全局前缀 —— 故 app 链到的
  ;; 实例与包内交付的实例是同一个物理对象文件。版本门用进程内常量,不再读快照。
  (define (copy-chandler-into-pack! project libdir range)
    (unless (version-match? range chandler-version)
      (error 'pack
             (format "manifest requires chandler ~s, but the running chandler is ~a"
                     range chandler-version)))
    (let* ([chandler-vr (version-root libdir 'chandler chandler-version)]
           [obj-dest (join-paths chandler-vr (current-machine-type) "chandler")]
           [src-dest (join-paths chandler-vr "src" "chandler")]
           [from (join-paths project "_vendor" "chandler" "_build"
                             (current-machine-type) "chandler")])
      (unless (file-directory? from)
        (error 'pack
               (format "chandler runtime not vendored at ~a~%  (run `chandler deps` — the (chandler …) gate copies it there)"
                       from)))
      (ensure-dir obj-dest)
      (ensure-dir src-dest)
      (let ([n 0])
        (for-each
          (lambda (e)
            (let ([p (join-paths from e)])
              (when (and (not (file-directory? p)) (string-suffix? ".so" e))
                (let ([dst (join-paths obj-dest e)])
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
  ;;   完整性(2026-07-26 严格化):顶层必须 (pack …)(expect-tag,受控错);
  ;;   (files …) 缺失/为空即 65 —— 没有文件清单的包无法证明完整性(旧行为把
  ;;   缺失当空表 → 所有文件 EXTRA 却不计 bad → 对任何包开绿灯)。每个 entry 必须
  ;;   ("<rel>" (sha256 "<hex>") (size <n>)),缺 hash/size 即 fatal(旧行为是
  ;;   (and want-h …) 条件检查:没声明 hash 的 entry 只要文件在就过)。
  ;;   MISSING/CHANGED/INVALID/EXTRA 全部计入 bad —— EXTRA 曾只报告,但不在
  ;;   清单里的文件可能是注入载荷,必须致命。
  ;;   L1 加两块(designs/10 §7):
  ;;     verify-format!       (format N) > pack-format-supported(=1)→ 70;
  ;;     --target             对当前 runtime 跑 designs/10 §4 全矩阵 → 78。
  ;;   退出码(sysexits):0 全过;65 完整性/schema 错(EX_DATAERR,对齐 skiff/app.ss);
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

  ;; entry schema:必须 ("<rel>" (sha256 "<hex>") (size <n>))。返回 #f(合法)
  ;; 或缺失原因 symbol。缺任一项 → 该 entry 计 bad(严格化:不再「文件在就过」)。
  (define (verify-entry-schema e)
    (cond
      [(not (and (pair? e) (string? (car e)))) 'malformed-entry]
      [(not (string? (attr 'sha256 e))) 'missing-sha256]
      ;; integer? 是全类型安全谓词(#f/"x" → #f),exact? 不是(非 number 即抛)
      [(let ([s (attr 'size e)]) (not (and (integer? s) (exact? s)))) 'missing-size]
      [else #f]))

  ;; 完整性:MISSING/CHANGED/INVALID(schema)/EXTRA 全部记 bad(致命)。返回 bad 计数。
  (define (verify-pack-integrity! root files)
    (let ([declared '()] [ok 0] [bad 0] [extra 0])
      (for-each
        (lambda (e)
          ;; rel 可辨即先登记:schema 不合格的 entry 不该再让同名文件被二次计 EXTRA
          (when (and (pair? e) (string? (car e)))
            (set! declared (cons (car e) declared)))
          (let ([schema-bad (verify-entry-schema e)])
            (if schema-bad
                (begin
                  (set! bad (+ bad 1))
                  (fprintf (current-error-port) "  INVALID ~s (~a)~%" e schema-bad))
                (let* ([rel (car e)]
                       [want-h (attr 'sha256 e)]
                       [want-s (attr 'size e)]
                       [abs (join-paths root rel)])
                  (cond
                    [(not (file-exists? abs))
                     (set! bad (+ bad 1)) (fprintf (current-error-port) "  MISSING ~a~%" rel)]
                    [(not (string=? want-h (sha256-file abs)))
                     (set! bad (+ bad 1)) (fprintf (current-error-port) "  CHANGED ~a (sha256 mismatch)~%" rel)]
                    [(not (= want-s (file-size abs)))
                     (set! bad (+ bad 1)) (fprintf (current-error-port) "  CHANGED ~a (size mismatch)~%" rel)]
                    [else (set! ok (+ ok 1))])))))
        files)
      ;; pack.manifest 自己从不被声明(最后写),排除掉;其余未声明文件 = EXTRA,致命
      (for-each
        (lambda (abs)
          (let ([rel (strip-prefix abs (string-append root "/"))])
            (unless (or (string=? rel "pack.manifest") (member rel declared))
              (set! extra (+ extra 1))
              (set! bad (+ bad 1))
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

  ;; (files …) 缺失/为空/非列表 → 65 EX_DATAERR:没有文件清单的包无法证明完整性。
  ;; 旧行为把缺失当空表 → 所有文件成 EXTRA 却不计 bad → 对任何包都开绿灯。
  (define (verify-pack-files-field! files)
    (and (or (not files) (null? files) (not (list? files)))
         (begin
           (%pack-err "manifest missing or empty (files ...)")
           (%pack-err-sexp '(chandler-pack-error (manifest-invalid (files-missing))))
           65)))

  ;; verify-pack path [target?] → 退出码。顺序:format → files 清单在否 → 完整性 →
  ;; --target(format 太新时清单结构不可信,先于一切;没有 (files …) 则完整性无从
  ;; 谈起;--target 是「这包能不能在本机跑」的附加检查,只在完整性过关后有意义)。
  ;; 顶层 datum 经 expect-tag:不是 (pack …) → 受控错(不再是低级 cdr 错)。
  (define (verify-pack path . maybe-target?)
    (let ([target? (and (pair? maybe-target?) (car maybe-target?))])
      (let* ([is-mf (string-suffix? "pack.manifest" path)]
             [root  (if is-mf (parent-dir path) path)]
             [mf    (if is-mf path (join-paths path "pack.manifest"))])
        (unless (file-exists? mf)
          (error 'verify-pack (format "pack.manifest not found at ~a" mf)))
        (let* ([form   (read-datum-file mf)]
               [fields (expect-tag form 'pack 'verify-pack)]
               [files  (let ([c (assq 'files fields)]) (and c (cdr c)))])
          (or (verify-pack-format! fields)
              (verify-pack-files-field! files)
              (let ([bad (verify-pack-integrity! root files)])
                (cond
                  [(> bad 0) 65]
                  [target? (or (verify-pack-target! fields) 0)]
                  [else 0])))))))

  ;; (cdr e) 里找 (key val);项缺 val(如 (sha256) 裸项)→ #f,不崩
  (define (attr key e)
    (let ([c (assq key (cdr e))]) (and c (pair? (cdr c)) (cadr c)))))
