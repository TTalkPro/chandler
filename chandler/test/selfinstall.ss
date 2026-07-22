#!chezscheme
;;; chandler/test/selfinstall.ss --- install-self / uninstall-self(库经 bake install)

(library (chandler test selfinstall)
  (export suite)
  (import (chezscheme)
          (chandler test harness)
          (chandler test fixtures)
          (chandler proc)
          (chandler fs)
          (chandler cli selfinstall))

  (define repo-root (current-directory))

  ;; bake 是否可用(自安装委托它;不可用则跳过 roundtrip)
  (define (bake-ok?) (= 0 (run-status (bake-command) '("-V"))))

  (define (with-home dir thunk)               ; 临时改 HOME(bake user target 与 self-libdir 都据它)
    (let ([old (getenv "HOME")])
      (putenv "HOME" dir)
      (guard (e [#t (putenv "HOME" old) (raise e)])
        (let ([r (thunk)]) (putenv "HOME" old) r))))

  (define-suite suite
    ;; ── 落点解析(user 默认 / --global;前缀下含 src/mt 拆分)──
    (prefix-user
      (with-home "/tmp/fake-home"
        (lambda ()
          (assert-string= "/tmp/fake-home/.local/share/chez" (self-prefix '()))
          (assert-string= "/tmp/fake-home/.local/bin/chandler" (self-launcher '())))))

    (prefix-global
      (assert-string= "/usr/local/share/chez" (self-prefix '((global . #t))))
      (assert-string= "/usr/local/bin/chandler" (self-launcher '((global . #t)))))

    ;; ── 两启动器语义对齐(sh / ps1):同口令、同覆盖约定、同退出码 ──
    (launchers-parity
      (let ([sh (launcher-sh "/pfx")] [ps (launcher-ps1 "/pfx")])
        ;; 能力探测口令共用一份(各写一份必漂移)
        (assert-true (substr? sh self-probe-token))
        (assert-true (substr? ps self-probe-token))
        ;; 三个覆盖变量两边都认
        (for-each (lambda (v)
                    (assert-true (substr? sh v))
                    (assert-true (substr? ps v)))
                  '("CHANDLER_RUNTIME" "CHANDLER_SKIFF" "CHANDLER_SCHEME"))
        ;; 非法运行时 → 64(EX_USAGE);全无可用 → 127
        (assert-true (substr? sh "exit 64"))   (assert-true (substr? ps "exit 64"))
        (assert-true (substr? sh "exit 127"))  (assert-true (substr? ps "exit 127"))))

    ;; ── 损坏态:库 main.sps 缺失时,启动器先报有用错误再退出 70 ──
    ;; 这是 uninstall-self 自举死锁的另一面:库没了,启动器要当场说明并给修复路径,
    ;; 而不是让 Chez 抛裸的 "Exception in load-program"。
    (launcher-sh-broken-install-hint
      (let ([sh (launcher-sh "/pfx")])
        (assert-true (substr? sh "install is broken"))
        (assert-true (substr? sh "exit 70"))
        (assert-true (substr? sh "main.sps"))
        ;; 修复指引必须包含 reinstall 命令
        (assert-true (substr? sh "install.sh"))))

    (launcher-ps1-broken-install-hint
      (let ([ps (launcher-ps1 "/pfx")])
        (assert-true (substr? ps "install is broken"))
        (assert-true (substr? ps "exit 70"))
        (assert-true (substr? ps "main.sps"))
        (assert-true (substr? ps "install.ps1"))))

    ;; ── 探测程序:一次调用同时验「能跑程序」与「是不是 skiff、版本几何」──
    (probe-src-shape
      (let ([p self-probe-src])
        ;; 口令 + 冒号:输出形如 CHANDLER_RT_OK:0.1.1
        (assert-true (substr? p (string-append self-probe-token ":")))
        ;; 坑 1:必须走反射取 skiff-version —— 直接写 (skiff-version) 在 --program
        ;; 模式下是展开期未绑定标识符,会直接报错。
        (assert-true (substr? p "top-level-bound?"))
        (assert-true (substr? p "top-level-value"))
        (assert-false (substr? p "(skiff-version)"))
        ;; 坑 2:sh 侧要把程序嵌在 '…' 里,故文本中不得出现单引号
        (assert-false (substr? p "'"))
        ;; skiff 可能绑为过程或字符串,两种都认
        (assert-true (substr? p "procedure?"))))

    ;; ── ps1 特有约束(PowerShell 四坑 + 跨平台可跑)──
    (ps1-shape
      (let ([ps (launcher-ps1 "/pfx")])
        (assert-true (substr? ps "$PSNativeCommandUseErrorActionPreference"))  ; 坑 2
        (assert-true (substr? ps "$ChandlerArgs = $args"))                     ; 坑 3
        (assert-true (substr? ps "exit $LASTEXITCODE"))                        ; 坑 1
        (assert-true (substr? ps "$Prefix/src"))                               ; 坑 4:正斜杠
        ;; 分隔符取 .NET PathSeparator(非写死 ';'),故 Windows 正确、Linux 亦可实跑
        (assert-true (substr? ps "[System.IO.Path]::PathSeparator"))
        (assert-false (substr? ps "\\src"))))                                  ; 不得有反斜杠路径

    ;; ── 运行时发现顺序:skiff 优先 ──
    (runtime-order-skiff-first
      (assert-string= "skiff scheme chez chez-scheme chezscheme" self-runtimes)
      (assert-true (< (idx self-runtimes "skiff") (idx self-runtimes "scheme"))))

    ;; ── 端到端:bake 装库 → 启动器 → 卸载(需 bake)──
    (install-via-bake-roundtrip
      (if (not (bake-ok?))
          (assert-true #t)                     ; bake 不可用:跳过(生态外环境)
          (let ([home (mktmp)])
            (with-home home
              (lambda ()
                (assert-equal 0 (cmd-install-self repo-root '()))
                (let ([prefix (string-append home "/.local/share/chez")]
                      [launcher (string-append home "/.local/bin/chandler")])
                  ;; 库树经 bake install 落位(src/mt 拆分:源在 src/,umbrella + cli 程序 + bake 清单)
                  (assert-true (file-exists? (string-append prefix "/src/chandler.ss")))
                  (assert-true (file-exists? (string-append prefix "/src/chandler/cli/main.sps")))
                  (assert-true (file-exists? (string-append prefix "/.bake-install/chandler.files")))
                  ;; 启动器:运行时发现(候选含 skiff 且在最前)+ 挂 src::mt 一对
                  (let ([l (read-file launcher)])
                    (assert-true (substr? l "skiff scheme"))       ; 默认候选序,skiff 优先
                    (assert-true (substr? l "command -v"))
                    (assert-true (substr? l "--program"))
                    (assert-true (substr? l "/src::"))
                    ;; 显式指定运行时:CHANDLER_RUNTIME + 非法值报 64
                    (assert-true (substr? l "CHANDLER_RUNTIME"))
                    (assert-true (substr? l "exit 64")))
                  ;; 卸载:库文件 + 启动器 + bake 清单皆删
                  (assert-equal 0 (cmd-uninstall-self repo-root '()))
                  (assert-false (file-exists? (string-append prefix "/src/chandler.ss")))
                  (assert-false (file-exists? (string-append prefix "/.bake-install/chandler.files")))
                  (assert-false (file-exists? launcher)))))))))

  (define (idx s sub)
    (let ([ls (string-length s)] [lsub (string-length sub)])
      (let loop ([i 0])
        (cond [(> (+ i lsub) ls) -1]
              [(string=? sub (substring s i (+ i lsub))) i]
              [else (loop (+ i 1))])))))
