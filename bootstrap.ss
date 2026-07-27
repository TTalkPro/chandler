#!/usr/bin/env scheme-script
;;; bootstrap.ss — chandler 自举安装器(三段式)
;;;
;;; 自包含红线:纯 (chezscheme),零 chandler import —— chandler 库坏了也能装。
;;; 所有安装/编译/launcher 逻辑一律 spawn chandler 自己的 CLI 完成(直接复用
;;; cmd-deps / cmd-build / cmd-install / cmd-uninstall-global),本脚本只做编排。
;;;
;;; 三段式(_bootstrap 与正常 --user 安装完全同构,仅前缀不同):
;;;   stage 1  源码直载 CLI:deps → build → install --prefix=<repo>/_bootstrap
;;;            产出 _bootstrap/{chandler/<ver>/{src,<mt>},.registry,bin/chandler}
;;;   stage 2  用 _bootstrap 的 chandler 重新 build 本仓库(自托管验证)
;;;   stage 3  用 _bootstrap 的 chandler install 到最终前缀 + shim 冒烟
;;;
;;; stage 2/3 直载 _bootstrap 的 main.sps(不走 shim),保住退出码可检测;
;;; shim 链路单独冒烟验证。
;;;
;;; 用法:
;;;   scheme --script bootstrap.ss                # 装到 ~/.local(默认 --user)
;;;   skiff  --script bootstrap.ss                # 用 skiff 跑安装(默认跟随调用运行时)
;;;   scheme --script bootstrap.ss --system       # 装到 /usr/local(需 root)
;;;   scheme --script bootstrap.ss --prefix=DIR   # 装到 DIR(启动器 → DIR/bin)
;;;   scheme --script bootstrap.ss --bootstrap-only   # 只跑 stage 1(产出 _bootstrap/)
;;;   scheme --script bootstrap.ss --force        # 覆盖重装
;;;   scheme --script bootstrap.ss --uninstall    # 卸载(按同一 target;需仓库源码在)
;;;
;;; 环境变量(与 chandler 全局约定一致):
;;;   CHANDLER_RUNTIME=skiff|chez   选运行时;缺省跟随调用 bootstrap 的解释器
;;;   CHANDLER_SKIFF / CHANDLER_SCHEME   对应运行时的可执行文件(名或路径)
;;;
;;; 注意:编译是硬需求 —— petite 没有编译器,stage 1 的 build 会明确报错。

(import (chezscheme))

;; ════════════════════════════════════════════════════════════════════
;; §1 最小工具(仅编排所需;fs/安装逻辑全在 chandler 库里,不重造)
;; ════════════════════════════════════════════════════════════════════

(define (dirname path)
  (let loop ([i (- (string-length path) 1)])
    (cond [(< i 0) "."]
          [(char=? #\/ (string-ref path i)) (substring path 0 i)]
          [else (loop (- i 1))])))

(define (join-paths . parts)
  (fold-left (lambda (acc p)
               (cond [(or (string=? acc "") (string=? acc ".")) p]
                     [(char=? #\/ (string-ref acc (- (string-length acc) 1))) (string-append acc p)]
                     [else (string-append acc "/" p)]))
             ""
             parts))

(define (ensure-dir path)
  (unless (file-exists? path)
    (ensure-dir (dirname path))
    (mkdir path)))

(define (rm-rf path)
  (when (file-exists? path)
    (if (file-directory? path)
        (begin
          (for-each (lambda (e)
                      (unless (or (string=? e ".") (string=? e ".."))
                        (rm-rf (join-paths path e))))
                    (directory-list path))
          (delete-directory path))
        (delete-file path))))

(define (string-contains? s sub)
  (let ([ls (string-length s)] [lsub (string-length sub)])
    (and (> lsub 0)
         (let loop ([i 0])
           (cond [(> (+ i lsub) ls) #f]
                 [(string=? sub (substring s i (+ i lsub))) #t]
                 [else (loop (+ i 1))])))))

(define (mt-string) (symbol->string (machine-type)))
(define (win?) (let ([m (mt-string)])
                 (and (>= (string-length m) 2)
                      (string=? (substring m (- (string-length m) 2) (string-length m)) "nt"))))

;; getenv 但空串视为未设 —— 与 (chandler util) 的 getenv* 同语义。
;; Chez 的 putenv 删不掉变量,还原时只能置 "",故空串必须当作「没设」;
;; 否则 CHANDLER_SKIFF="" 会让下面的 (or …) 拿到 "" 去 exec 一个空命令名。
(define (getenv* name)
  (let ([v (getenv name)])
    (and v (> (string-length v) 0) v)))

;; 参数引用。与 (chandler proc) 的 shell-quote 同语义,**按平台分派**
;; (自包含红线要求这里另写一份;两份不许分叉,由 bootstrap-parity 测试逐条钉住)。
;;
;; POSIX:单引号包裹,' → '\''。**不能**用双引号 —— 双引号内 $ ` \ " 对 sh 仍然
;; 特殊,而这里引的全是真实路径(仓库根、前缀、解释器、libdirs),检出在含 $ 的
;; 目录下就会静默拼错。
;;
;; Windows(cmd.exe):双引号包裹 + MSVCRT 反斜杠规则(`"` 前与**结尾**的连续
;; 反斜杠加倍)。全包在引号里,cmd 的 `& | < > ^ ( )` 那层也就自动安全了。
(define (q s)
  (if (win?) (q-cmd s) (q-sh s)))

(define (q-sh s)
  (let ([op (open-output-string)])
    (display #\' op)
    (string-for-each
      (lambda (c) (if (char=? c #\') (display "'\\''" op) (display c op)))
      s)
    (display #\' op)
    (get-output-string op)))

(define (q-cmd s)
  ;; 字面 `"` / 换行在 cmd 下无法安全传递(cmd 不认反斜杠转义,引号配对会错位,
  ;; 后续的 & | > ^ 就落到引号外变成控制字符)—— 当场硬错,别悄悄传错。
  (string-for-each
    (lambda (c)
      (when (or (char=? c #\") (char=? c #\newline) (char=? c #\return))
        (die 64 "cannot pass this path through cmd.exe safely: ~s" s)))
    s)
  (let ([op (open-output-string)] [n (string-length s)])
    (display #\" op)
    (let loop ([i 0] [pending 0])
      (if (= i n)
          (do ([k 0 (+ k 1)]) ((= k (* 2 pending))) (display #\\ op))
          (let ([c (string-ref s i)])
            (if (char=? c #\\)
                (loop (+ i 1) (+ pending 1))
                (begin
                  (do ([k 0 (+ k 1)]) ((= k pending)) (display #\\ op))
                  (display c op)
                  (loop (+ i 1) 0))))))
    (display #\" op)
    (get-output-string op)))

(define (die code fmt . args)
  (fprintf (current-error-port) (apply format (string-append "bootstrap: " fmt "~%") args))
  (exit code))

(define (path-absolute? p)
  (or (and (> (string-length p) 0) (char=? #\/ (string-ref p 0)))
      ;; Windows:X:\ 或 X:/
      (and (> (string-length p) 2) (char=? (string-ref p 1) #\:))))

(define (absolutize p)
  (if (path-absolute? p) p (join-paths (current-directory) p)))

;; ════════════════════════════════════════════════════════════════════
;; §2 参数解析
;;   target = (user) | (system) | (prefix . DIR);缺省 (user)
;; ════════════════════════════════════════════════════════════════════

(define (parse-bootstrap-args argv)
  (let loop ([xs argv] [target #f] [force? #f] [uninstall? #f] [help? #f] [boot-only? #f])
    (define (set-target t xs)
      (if target
          (die 64 "--user / --system / --prefix are mutually exclusive")
          (loop xs t force? uninstall? help? boot-only?)))
    (if (null? xs)
        (list (or target '(user)) force? uninstall? help? boot-only?)
        (let ([a (car xs)])
          (cond
            [(string=? a "--help")           (loop (cdr xs) target force? uninstall? #t boot-only?)]
            [(string=? a "--force")          (loop (cdr xs) target #t uninstall? help? boot-only?)]
            [(string=? a "--uninstall")      (loop (cdr xs) target force? #t help? boot-only?)]
            [(string=? a "--bootstrap-only") (loop (cdr xs) target force? uninstall? help? #t)]
            [(string=? a "--user")           (set-target '(user) (cdr xs))]
            [(string=? a "--system")         (set-target '(system) (cdr xs))]
            [(and (> (string-length a) 9)
                  (string=? (substring a 0 9) "--prefix="))
             (let ([dir (substring a 9 (string-length a))])
               (when (string=? dir "") (die 64 "--prefix=DIR needs a non-empty directory"))
               (set-target (cons 'prefix (absolutize dir)) (cdr xs)))]
            [else (die 64 "unknown option: ~a (try --help)" a)])))))

;; ════════════════════════════════════════════════════════════════════
;; §3 路径计算(仓库 / _bootstrap / 最终前缀)
;; ════════════════════════════════════════════════════════════════════

(define here (dirname (car (command-line))))
(define here-abs (absolutize here))
(define mt (mt-string))
(define bdir (join-paths here-abs "_build" mt))
(define home (or (getenv "HOME") (getenv "USERPROFILE") "."))

;; _bootstrap = stage 1 的本地产出前缀,布局与 --user 安装同构:
;;   _bootstrap/chandler/<ver>/{src,<mt>}/.chandler/   库 + 对象 + manifest/lock/run.sps
;;   _bootstrap/.registry/chandler.ss                  中心注册表(kind app, active)
;;   _bootstrap/bin/chandler                           稳定 shim 启动器
(define boot-prefix (join-paths here-abs "_bootstrap"))
(define boot-bindir (join-paths boot-prefix "bin"))

(define chandler-ver
  ;; 唯一事实源:chandler-manifest.ss 的 (version "...")
  (let ([mpath (join-paths here-abs "chandler-manifest.ss")])
    (if (file-exists? mpath)
        (let* ([datum (call-with-input-file mpath read)]
               [ver-field (assoc 'version (cdr datum))])
          (if ver-field (cadr ver-field) "0.0.0"))
        "0.0.0")))

(define boot-vroot (join-paths boot-prefix "chandler" chandler-ver))

;; 与 (chandler registry) default-*-libdir/bindir 保持一致(此处无法 import,镜像之)。
;; **这不是靠人记住的**:tests/chandler/bootstrap-parity.ss 把本文件当数据读进来、
;; 抽出下面两个定义 eval 进干净环境,再与 registry 那份逐条比对。§4 的运行时
;; 选择同理(对 cli/runtime-env.ss 的 choose-interp)。改一处漏一处会当场红。
(define (target-libdir target)
  (case (car target)
    [(user)   (if (win?)
                  (join-paths (or (getenv* "LOCALAPPDATA") home) "chez")
                  (string-append home "/.local/share/chez"))]
    [(system) (if (win?)
                  (join-paths (or (getenv* "ProgramData") "C:/ProgramData") "chez")
                  "/usr/local/chez")]
    [(prefix) (cdr target)]))

(define (target-bindir target)
  (case (car target)
    [(user)   (if (win?)
                  (join-paths (target-libdir target) "bin")
                  (string-append home "/.local/bin"))]
    [(system) (if (win?)
                  (join-paths (target-libdir target) "bin")
                  "/usr/local/bin")]
    [(prefix) (join-paths (cdr target) "bin")]))

(define (target-flag target)
  (case (car target)
    [(user)   "--user"]
    [(system) "--system"]
    [(prefix) (string-append "--prefix=" (q (cdr target)))]))

;; ════════════════════════════════════════════════════════════════════
;; §4 运行时选择(跟随调用 bootstrap 的解释器;env 显式覆盖)
;; ════════════════════════════════════════════════════════════════════

(define (skiff-exe) (or (getenv* "CHANDLER_SKIFF") "skiff"))
(define (chez-exe)  (or (getenv* "CHANDLER_SCHEME") "scheme"))

(define (running-skiff?)
  ;; skiff 自 0.1.1 起内置 (skiff-version) 自证
  (top-level-bound? (string->symbol "skiff-version")))

(define interp
  (let ([rt (getenv* "CHANDLER_RUNTIME")])
    (cond
      [rt (cond [(string=? rt "skiff") (skiff-exe)]
                [(string=? rt "chez")  (chez-exe)]
                [else (die 64 "invalid CHANDLER_RUNTIME=~a (want: skiff|chez)" rt)])]
      [(running-skiff?) (skiff-exe)]
      [else (chez-exe)])))

;; ════════════════════════════════════════════════════════════════════
;; §5 spawn 原语(唯一的外部调用点)
;; ════════════════════════════════════════════════════════════════════

;; --libdirs 的源::对象对分隔符:POSIX "::",Windows ";;"
(define pair-sep (if (win?) ";;" "::"))
(define (pair src obj) (string-append src pair-sep obj))

(define src-main-sps (join-paths here-abs "chandler" "cli" "main.sps"))

;; 源码直载 CLI:chandler 未安装时也能跑(库从源码即时编译加载)
(define (source-cli-cmd libdirs args)
  (string-append (q interp) " -q --libdirs " (q libdirs)
                 " --program " (q src-main-sps)
                 " -C " (q here-abs) " " args))

;; _bootstrap 直载 CLI:用 stage 1 装好的编译对象跑,与最终安装态同一布局。
;; CHANDLER_HOME 指向 _bootstrap,让自举实例的运行时门/全局兜底都落在自己身上。
(define (boot-cli-cmd args)
  (let ([main-sps (join-paths boot-vroot "src" "chandler" "cli" "main.sps")]
        [libdirs (pair (join-paths boot-vroot "src") (join-paths boot-vroot mt))]
        ;; 环境注入前缀,与 (chandler proc) 的 env-prefix 同形:
        ;;   POSIX `K='v' cmd` / cmd `set "K=v" && cmd`
        ;; **值要经 q-cmd 引用**,不能像先前那样把 boot-prefix 裸贴进引号里 ——
        ;; 前缀含 `"` 或结尾反斜杠时那样会拼出一条错的命令。
        [env (if (win?)
                 (string-append "set " (q-cmd (string-append "CHANDLER_HOME=" boot-prefix))
                                " && ")
                 (string-append "CHANDLER_HOME=" (q-sh boot-prefix) " "))])
    (string-append env (q interp) " -q --libdirs " (q libdirs)
                   " --program " (q main-sps)
                   " -C " (q here-abs) " " args)))

(define (run-or-die cmd what)
  (printf "bootstrap: ~a...~%" what)
  (let ([rc (system cmd)])
    (unless (and (fixnum? rc) (= rc 0))
      (die 70 "~a failed (exit ~a)" what rc))))

;; ════════════════════════════════════════════════════════════════════
;; §6 三个阶段 + 冒烟
;; ════════════════════════════════════════════════════════════════════

;; stage 1:源码直载 CLI,产出与 --user 安装同构的 _bootstrap/
(define (stage1-build-bootstrap! force?)
  (printf "bootstrap: stage 1/3: build a usable chandler into ~a~%" boot-prefix)
  (rm-rf boot-prefix)   ; 幂等:每次重产,force 语义由 rm-rf 兜住
  (run-or-die (source-cli-cmd here-abs "deps")
              "stage1: chandler deps")
  (run-or-die (source-cli-cmd here-abs "build")
              "stage1: chandler build")
  (run-or-die (source-cli-cmd (pair here-abs bdir)
                              (string-append "install --prefix=" (q boot-prefix)
                                             (if force? " --force" "")))
              "stage1: chandler install (bootstrap prefix)")
  (unless (file-exists? (join-paths boot-vroot "src" "chandler" "cli" "main.sps"))
    (die 70 "stage1 produced no usable chandler at ~a" boot-vroot)))

;; stage 2:用 _bootstrap 的 chandler 重新 build 本仓库(自托管验证)
(define (stage2-self-build!)
  (printf "bootstrap: stage 2/3: self-host build (using _bootstrap chandler)~%")
  (run-or-die (boot-cli-cmd "build") "stage2: self-host build"))

;; stage 3:用 _bootstrap 的 chandler 装到最终前缀(--user/--system/--prefix)
(define (stage3-install-final! target force?)
  (printf "bootstrap: stage 3/3: install to ~a~%" (target-libdir target))
  (run-or-die (boot-cli-cmd (string-append "install " (target-flag target)
                                           (if force? " --force" "")))
              "stage3: chandler install")
  (smoke! (target-bindir target)))

;; shim 链路冒烟:启动器 → .registry active → run.sps → 运行时发现
;;
;; **两个平台都跑**(D34)。先前 Windows 上跳过,是因为启动器是 `.ps1` ——
;; 没法直接 `system` 起来。改成 `.cmd` 后它就是个能直接执行的命令,
;; 于是自举的最后一环在 Windows 上也真的被验证过,而不是印一行提示了事。
(define (smoke! bindir)
  (run-or-die (q (join-paths bindir (if (win?) "chandler.cmd" "chandler")))
              "smoke: chandler --version"))

;; ════════════════════════════════════════════════════════════════════
;; §7 卸载(registry 驱动;源码直载 CLI,不依赖任何已装实例)
;; ════════════════════════════════════════════════════════════════════

(define (do-uninstall! target)
  (let ([libdir (target-libdir target)])
    (if (not (file-exists? (join-paths libdir ".registry" "chandler.ss")))
        (printf "bootstrap: chandler is not installed at ~a (nothing to do)~%" libdir)
        (run-or-die (source-cli-cmd here-abs
                                    (string-append "uninstall --name=chandler " (target-flag target)))
                    "chandler uninstall"))
    (when (file-directory? boot-prefix)
      (rm-rf boot-prefix)
      (printf "bootstrap: removed ~a~%" boot-prefix))
    (printf "chandler uninstalled from ~a~%" libdir)))

;; ════════════════════════════════════════════════════════════════════
;; §8 帮助 / 入口
;; ════════════════════════════════════════════════════════════════════

(define (path-hint target)
  (unless (win?)
    (let ([bindir (target-bindir target)]
          [p (or (getenv "PATH") "")])
      (unless (string-contains? p bindir)
        (printf "  hint: add ~a to PATH: export PATH=\"~a:$PATH\"~%" bindir bindir)))))

(define (print-help)
  (display "chandler bootstrap — self-contained three-stage installer\n\n")
  (display "Usage: scheme --script bootstrap.ss [options]\n")
  (display "       skiff  --script bootstrap.ss [options]\n\n")
  (display "Stages (a _bootstrap install mirrors a normal --user install exactly):\n")
  (display "  1. source-loaded CLI: deps → build → install --prefix=<repo>/_bootstrap\n")
  (display "  2. _bootstrap chandler rebuilds this repo (self-host check)\n")
  (display "  3. _bootstrap chandler installs to the final prefix + launcher smoke test\n\n")
  (display "Options:\n")
  (display "  (none)            Install to ~/.local/share/chez + launcher to ~/.local/bin\n")
  (display "  --user            Same as (none) (explicit)\n")
  (display "  --system          Install to /usr/local/chez + /usr/local/bin (needs root)\n")
  (display "  --prefix=DIR      Install to DIR + DIR/bin\n")
  (display "  --bootstrap-only  Run stage 1 only (produce _bootstrap/, nothing installed)\n")
  (display "  --force           Reinstall over existing\n")
  (display "  --uninstall       Remove chandler from the target prefix (registry-driven;\n")
  (display "                    needs this repo's sources to load the CLI)\n")
  (display "  --help            Show this help and exit\n\n")
  (display "Runtime selection (same variables as chandler itself):\n")
  (display "  CHANDLER_RUNTIME=skiff|chez   force a runtime; default follows the\n")
  (display "                                interpreter running this script\n")
  (display "  CHANDLER_SKIFF / CHANDLER_SCHEME   executable for that runtime\n\n")
  (display "Note: compilation is required — petite has no compiler; use scheme or skiff.\n")
  (display "Files installed (v3 layout):\n")
  (display "  <libdir>/chandler/<ver>/{src,<mt>}/   sources + compiled objects\n")
  (display "  <libdir>/.registry/chandler.ss        central registry (kind app, active)\n")
  (display "  <bindir>/chandler[.ps1]               stable-shim launcher\n"))

(define (main)
  (let ([parsed (parse-bootstrap-args (cdr (command-line)))])
    (let ([target (car parsed)]
          [force? (cadr parsed)]
          [uninstall? (caddr parsed)]
          [help? (cadddr parsed)]
          [boot-only? (car (cddddr parsed))])
      (cond
        [help? (print-help) (exit 0)]
        [uninstall? (do-uninstall! target) (exit 0)]
        [else
         (stage1-build-bootstrap! force?)
         (if boot-only?
             (printf "bootstrap: --bootstrap-only done; try: ~a --version~%"
                     (join-paths boot-bindir "chandler"))
             (begin
               (stage2-self-build!)
               (stage3-install-final! target force?)
               (printf "chandler ~a installed to ~a~%" chandler-ver (target-libdir target))
               (path-hint target)))
         (exit 0)]))))

(main)
