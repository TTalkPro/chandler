#!chezscheme
;;; chandler/cli/selfinstall.ss --- chandler install-self / uninstall-self
;;;
;;; **自安装基于 bake install**(生态闭环):库树的拷贝完全委托给 `bake install`
;;; (读本仓 recipe.ss 的 install-task,装进 Chez 库前缀并写 bake 卸载清单);
;;; chandler 只额外补一个**运行时发现启动器**(bin/chandler,skiff 优先 → Chez),
;;; 这是 bake 不管的部分。卸载据 bake 清单删库 + 删启动器,不依赖源码目录。
;;;
;;; 落点(与 bake install-task 的 target + src/mt 拆分对齐):
;;;   user(默认) → ~/.local/share/chez/{src,<mt>} + ~/.local/bin/chandler
;;;   --global    → /usr/local/share/chez/{src,<mt>} + /usr/local/bin/chandler(需 root)
;;;   启动器挂一对 <prefix>/src::<prefix>/<mt>,跑 <prefix>/src/chandler/cli/main.sps。

(library (chandler cli selfinstall)
  (export cmd-install-self cmd-uninstall-self
          self-prefix self-bindir self-launcher self-runtimes bake-command
          launcher-sh launcher-ps1 self-probe-token self-probe-src)
  (import (chezscheme)
          (chandler util)
          (chandler fs)
          (chandler proc)                     ; 调 bake / chmod
          (chandler layout)
          (chandler cli args))                ; flag?

  ;; 运行时发现顺序:skiff 优先,其次 Chez 各名
  (define self-runtimes "skiff scheme chez chez-scheme chezscheme")
  ;; 能力探测口令:两个启动器共用一份,避免 sh/ps1 各写一个而漂移
  (define self-probe-token "CHANDLER_RT_OK")

  ;; 探测程序:**一次调用同时回答三问** —— (a) 该运行时能否真跑 R6RS 程序
  ;; (早期 skiff 是只打印 banner、退出码仍 0 的 stub);(b) 它是不是 skiff;
  ;; (c) 若是,版本几何。输出形如 "CHANDLER_RT_OK:0.1.1"(非 skiff 则冒号后为空)。
  ;;
  ;; 两个必须遵守的坑:
  ;;   1. 取 skiff-version 必须走**反射**(top-level-value),不能直接写 (skiff-version):
  ;;      后者在 `--program` 模式下是**展开期未绑定标识符**,直接报错——而 chandler 的
  ;;      CLI 正是以 --program 跑的,故探测也用 --program(探的就是真实使用的模式)。
  ;;   2. 程序文本里**不得出现单引号**:sh 侧要嵌在 '…' 里。故用
  ;;      (string->symbol "skiff-version") 而非 'skiff-version。
  ;; skiff 0.1.1 起把它绑为**过程**(更早可能是字符串),两种都认(与 bake 同款探测一致)。
  (define self-probe-src
    (string-append
      "(import (chezscheme))(display \"" self-probe-token ":\")"
      "(display (let ([s (string->symbol \"skiff-version\")])"
      " (if (top-level-bound? s)"
      " (let ([v (top-level-value s)]) (if (procedure? v) (v) v))"
      " \"\")))"))
  (define (bake-command) (or (getenv* "CHANDLER_BAKE") "bake"))

  (define (win?)
    (string-suffix? "nt" (current-machine-type)))

  ;; ── 落点前缀(与 recipe 的 install-task target 对齐;下含 src/ 与 <mt>/)──
  (define (self-prefix flags)
    (if (flag? flags 'global) "/usr/local/share/chez"
        (string-append (home-dir) "/.local/share/chez")))
  (define (self-bindir flags)
    (if (flag? flags 'global) "/usr/local/bin"
        (string-append (home-dir) "/.local/bin")))
  ;; Windows 启动器用 **PowerShell**(.ps1;2026-07-22 由 .cmd 改写,与 bake 对齐):
  ;; 目标环境用 PowerShell,且 PATH 上的 .ps1 可裸名 `chandler` 调用,两平台接口一致。
  (define (self-launcher flags)
    (string-append (self-bindir flags) "/" (if (win?) "chandler.ps1" "chandler")))

  ;; 由同一份 self-runtimes 派生 ps1 数组字面量 —— 第二份手写清单必然漂移,故不写。
  (define (ps1-list names)
    (string-join (map (lambda (r) (string-append "'" r "'")) names) ","))
  (define (self-runtimes-ps1) (ps1-list (string-split self-runtimes #\space)))
  ;; 已知 Chez 各名免探测(与 sh 启动器的 case 分支同义)
  (define chez-names '("scheme" "chez" "chez-scheme" "chezscheme"))

  ;; bake 的已装清单(卸载据此删库,不依赖源码):<prefix>/.bake-install/chandler.files
  (define (bake-manifest prefix) (string-append prefix "/.bake-install/chandler.files"))

  ;; ── install-self:bake install 装库 + 写启动器 ──
  (define (cmd-install-self root flags)
    (let* ([prefix   (self-prefix flags)]
           [launcher (self-launcher flags)]
           [global?  (flag? flags 'global)])
      ;; --force:已装则先卸库(bake install 遇清单会拒)
      (when (and (flag? flags 'force) (file-exists? (bake-manifest prefix)))
        (bake-uninstall root global?))
      ;; 1. 库树 → 委托 bake install(cwd = 源码 checkout,读其 recipe.ss;落 <prefix>/{src,<mt>})
      (run-check (bake-command)
                 (list (if global? "install-global" "install"))
                 (list (cons 'cwd root)))
      ;; 2. 运行时发现启动器(bake 不管这个;挂 <prefix>/src::<prefix>/<mt>)
      (write-text launcher (if (win?) (launcher-ps1 prefix) (launcher-sh prefix)))
      (unless (win?) (run-check "chmod" (list "+x" launcher) '()))
      (printf "install ~a~%" launcher)
      (printf "self-installed chandler to ~a (libraries via bake install, src/mt split)~%" prefix)
      (path-hint (self-bindir flags))
      0))

  ;; ── uninstall-self:据 bake 清单删库 + 删启动器(不依赖源码)──
  (define (cmd-uninstall-self root flags)
    (let ([prefix (self-prefix flags)]
          [launcher (self-launcher flags)])
      (uninstall-by-manifest prefix)
      (when (file-exists? launcher)
        (delete-file launcher) (sweep-empty-parents launcher)
        (printf "rm ~a~%" launcher))
      (printf "uninstalled chandler from ~a~%" prefix)
      0))

  ;; 据 bake 清单(绝对路径,逐行)删文件 + 清空父目录 + 删清单本身
  (define (uninstall-by-manifest prefix)
    (let ([mf (bake-manifest prefix)])
      (if (file-exists? mf)
          (begin
            (for-each (lambda (f)
                        (when (file-exists? f) (delete-file f) (sweep-empty-parents f)))
                      (read-lines mf))
            (delete-file mf) (sweep-empty-parents mf))
          (fprintf (current-error-port)
                   "warning: no bake install manifest at ~a (libraries may not have been installed via bake install)~%" mf))))

  ;; 卸库(--force 复用):优先据清单删;有源码时也可 bake uninstall
  (define (bake-uninstall root global?)
    (uninstall-by-manifest (if global? "/usr/local/share/chez"
                               (string-append (home-dir) "/.local/share/chez"))))

  ;; ── 启动器模板(运行时发现:skiff → Chez;非 Chez 须过能力探测)──
  ;;   库前缀是 src/mt 拆分:挂一对 <prefix>/src::<prefix>/<mt>,程序在 <prefix>/src/。
  ;;   <mt> 于安装机固定(库为该机所编),故生成期定死;源码目录同时兜底(无编译产物则按源编)。
  ;;
  ;; **显式指定运行时**(与 run/exec/repl 同一套约定,见 (chandler runtime)):
  ;;   CHANDLER_RUNTIME=skiff|chez   选哪一种;非法值 → 退出码 64(EX_USAGE)
  ;;   CHANDLER_SKIFF / CHANDLER_SCHEME  选哪个可执行文件(名或路径)
  ;; 显式指定即**照单执行**(只查在不在,不再跑能力探测)—— 对显式覆盖再探测等于否定覆盖。
  (define (launcher-sh prefix)
    (string-append
      "#!/bin/sh\n"
      "# chandler launcher — generated by `chandler install-self`; do not edit.\n"
      "# Prefer skiff, fall back to Chez scheme. Non-Chez runtimes must pass a\n"
      "# capability probe (skips early skiff stubs that only print a demo banner).\n"
      "# CHANDLER_RUNTIME=skiff|chez forces one; CHANDLER_SKIFF/CHANDLER_SCHEME\n"
      "# name the executable. A forced runtime is used verbatim (no probe).\n"
      "CHANDLER_PREFIX=\"" prefix "\"\n"
      "CHANDLER_MT=\"" (current-machine-type) "\"\n"
      "export CHANDLER_PREFIX CHANDLER_MT\n"
      ;; 安装完整性前置检查:库文件不在时,**先于运行时探测**给出有用错误。
      ;; 否则用户看到的是 Chez 抛的「Exception in load-program」——无指引、无修复路径。
      ;; 这正是 uninstall-self 自举死锁的另一面:库没了,启动器就该当场说明,别让人
      ;; 对着裸异常猜。退出码 70 = EX_SOFTWARE(本机软件配置问题)。
      "_main=\"$CHANDLER_PREFIX/src/chandler/cli/main.sps\"\n"
      "if [ ! -f \"$_main\" ]; then\n"
      "  echo \"chandler: install is broken — $_main is missing.\" 1>&2\n"
      "  echo \"  Reinstall from source:  ./install.sh\" 1>&2\n"
      "  echo \"  Or remove this orphan launcher:  rm \\\"$0\\\"\" 1>&2\n"
      "  exit 70\n"
      "fi\n"
      ;; 非 Chez 候选(即 skiff)须**自证身份**:口令 + 一个数字打头的版本。
      ;; 比原先「只要口令」更严:不绑 skiff-version 的 demo stub 一并被挡掉。
      "_prog_ok() {\n"
      "  printf '%s' '" self-probe-src "' \\\n"
      "    | \"$1\" -q --program /dev/stdin 2>/dev/null | grep -q '" self-probe-token ":[0-9]'\n"
      "}\n"
      "case \"${CHANDLER_RUNTIME:-}\" in\n"
      "  skiff) _cands=\"${CHANDLER_SKIFF:-skiff}\"; _forced=1 ;;\n"
      "  chez)  if [ -n \"${CHANDLER_SCHEME:-}\" ]; then _cands=\"$CHANDLER_SCHEME\";\n"
      "         else _cands=\"" (string-join chez-names " ") "\"; fi; _forced=1 ;;\n"
      "  \"\")   _cands=\"" self-runtimes "\"; _forced=0 ;;\n"
      "  *) echo \"chandler: invalid CHANDLER_RUNTIME=$CHANDLER_RUNTIME (want: skiff | chez)\" 1>&2; exit 64 ;;\n"
      "esac\n"
      "for rt in $_cands; do\n"
      "  command -v \"$rt\" >/dev/null 2>&1 || continue\n"
      "  if [ \"$_forced\" -eq 0 ]; then\n"
      "    case \"$rt\" in\n"
      "      " (string-join chez-names "|") ") : ;;\n"
      "      *) _prog_ok \"$rt\" || continue ;;\n"
      "    esac\n"
      "  fi\n"
      "  exec \"$rt\" -q --libdirs \"$CHANDLER_PREFIX/src::$CHANDLER_PREFIX/$CHANDLER_MT\" \\\n"
      "    --program \"$_main\" \"$@\"\n"
      "done\n"
      "echo \"chandler: no program-capable Scheme runtime found (need skiff or Chez Scheme).\" 1>&2\n"
      "exit 127\n"))

  ;; ── Windows 启动器(PowerShell)──
  ;; 与 sh 启动器**语义对齐**:同一份运行时清单、同一套「已知 Chez 免探测、其余须过
  ;; 能力探测」规则、同样的 127 退出码。PowerShell 特有的四个坑(与 bake designs/23
  ;; §九.6 同源):
  ;;   1. PowerShell 无 `exec` —— 调用后须显式 `exit $LASTEXITCODE` 回传子进程退出码,
  ;;      否则任何失败都会以成功收场。
  ;;   2. PS 7.3+ 在 $ErrorActionPreference='Stop' 下会把**原生非零退出**升级为终止性
  ;;      错误;能力探测正是靠读退出码判断,故显式关掉——否则探到一个 stub 就整个中止,
  ;;      而不是跳到下一个候选。
  ;;   3. 函数里的 $args 是**该函数**的参数,故脚本自身参数须在顶层捕获($ChandlerArgs)
  ;;      再用 @ 展开(splat)传下去。
  ;;   4. 路径一律用**正斜杠**:Windows 上 .NET 与各 exe 都接受,且使生成的脚本能在
  ;;      Linux 的 pwsh 下原样跑通 —— 测试正是这么实跑它的。
  ;; 分隔符:本脚本按定义只在 Windows 运行,故库目录串固定用 `;`(条目间)与 `;;`
  ;; (源;;对象),即 Chez 的 $separator-character 在 Windows 上的取值(见 layout.ss)。
  ;; 执行策略:本地生成的脚本不算 "remote",RemoteSigned 可跑;Windows 客户端默认的
  ;; Restricted 会拦下所有脚本,需一次性 `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`。
  (define (launcher-ps1 prefix)
    (string-append
      "#!/usr/bin/env pwsh\n"
      "# chandler launcher — generated by `chandler install-self`; do not edit.\n"
      "# Prefer skiff, fall back to Chez scheme. Non-Chez runtimes must pass a\n"
      "# capability probe (skips early skiff stubs that only print a demo banner).\n"
      "$PSNativeCommandUseErrorActionPreference = $false\n"   ; 坑 2
      "$ErrorActionPreference = 'Continue'\n"
      "$ChandlerArgs = $args\n"                               ; 坑 3
      "$Prefix = '" prefix "'\n"
      "$Mt = '" (current-machine-type) "'\n"
      "$env:CHANDLER_PREFIX = $Prefix\n"
      "$env:CHANDLER_MT = $Mt\n"
      ;; 分隔符取 .NET 的 PathSeparator —— 与 Chez 的 $separator-character 完全同规则
      ;; (Windows ';',其余 ':'),故本脚本在 Windows 上正确、在 Linux 的 pwsh 下也能
      ;; **真跑**(测试正是这么端到端验证它的)。不用 $IsWindows:那在 PS 5.1 上未定义。
      "# Chez libdirs: PathSeparator separates entries; doubled separates source from object\n"
      "$Sep = [System.IO.Path]::PathSeparator\n"
      "$LibDirs = \"$Prefix/src$Sep$Sep$Prefix/$Mt\"\n"
      "$Program = \"$Prefix/src/chandler/cli/main.sps\"\n"
      ;; 安装完整性前置检查(同 sh 版):库不在 → 当场给有用错误,不要让 Chez 抛裸
      ;; load-program 异常。退出码 70 = EX_SOFTWARE。
      "if (-not (Test-Path -LiteralPath $Program)) {\n"
      "  [Console]::Error.WriteLine(\"chandler: install is broken — $Program is missing.\")\n"
      "  [Console]::Error.WriteLine(\"  Reinstall from source:  ./install.ps1\")\n"
      "  [Console]::Error.WriteLine(\"  Or remove this orphan launcher:  Remove-Item \\\"\\\"$PSCommandPath\\\"\\\"\")\n"
      "  exit 70\n"
      "}\n"
      "\n"
      "function Test-ChandlerRuntime([string]$Exe, [string]$Probe) {\n"
      "  if (-not $Probe) { return $true }\n"
      ;; $null | … 立即关闭子进程 stdin(sh 版 `< /dev/null` 的等价物):
      ;; REPL 型运行时不得在探测期坐等输入。
      "  $out = $null | & $Exe -q --program $Probe 2>$null\n"
      "  if ($LASTEXITCODE -ne 0) { return $false }\n"
      ;; 同 sh:口令 + 数字打头的版本(自证是 skiff,而非只是「能出点东西」)
      "  return (($out -join ' ') -match '" self-probe-token ":\\d')\n"
      "}\n"
      "\n"
      ;; 显式指定运行时(同 sh:照单执行,不再探测)
      "$Forced = $false\n"
      "switch ($env:CHANDLER_RUNTIME) {\n"
      "  'skiff' { $Cands = @($(if ($env:CHANDLER_SKIFF) { $env:CHANDLER_SKIFF } else { 'skiff' })); $Forced = $true }\n"
      "  'chez'  { $Cands = $(if ($env:CHANDLER_SCHEME) { @($env:CHANDLER_SCHEME) } else { @(" (ps1-list chez-names) ") }); $Forced = $true }\n"
      "  ''      { $Cands = @(" (self-runtimes-ps1) ") }\n"
      "  $null   { $Cands = @(" (self-runtimes-ps1) ") }\n"
      "  default {\n"
      "    [Console]::Error.WriteLine(\"chandler: invalid CHANDLER_RUNTIME=$($env:CHANDLER_RUNTIME) (want: skiff | chez)\")\n"
      "    exit 64\n"
      "  }\n"
      "}\n"
      "\n"
      "$probe = Join-Path ([System.IO.Path]::GetTempPath()) \"chandler-probe-$PID.ss\"\n"
      "try { Set-Content -LiteralPath $probe -Value '" self-probe-src "' -Encoding ascii }\n"
      "catch { $probe = $null }\n"
      "try {\n"
      "  foreach ($rt in $Cands) {\n"
      ;; 候选可以是 PATH 上的名字,也可以是显式路径(CHANDLER_SKIFF/CHANDLER_SCHEME)
      "    $exe = $null\n"
      "    $c = Get-Command $rt -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1\n"
      "    if ($c) { $exe = $c.Source }\n"
      "    elseif (Test-Path -LiteralPath $rt) { $exe = (Resolve-Path -LiteralPath $rt).Path }\n"
      "    if (-not $exe) { continue }\n"
      "    if (-not $Forced -and ($rt -notin @(" (ps1-list chez-names) "))) {\n"
      "      if (-not (Test-ChandlerRuntime $exe $probe)) { continue }\n"
      "    }\n"
      "    & $exe -q --libdirs $LibDirs --program $Program @ChandlerArgs\n"
      "    exit $LASTEXITCODE\n"                              ; 坑 1
      "  }\n"
      "} finally {\n"
      "  if ($probe -and (Test-Path -LiteralPath $probe)) {\n"
      "    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue\n"
      "  }\n"
      "}\n"
      "[Console]::Error.WriteLine(\"chandler: no program-capable Scheme runtime found (need skiff or Chez Scheme).\")\n"
      "exit 127\n"))

  (define (path-hint bindir)
    (let ([p (or (getenv "PATH") "")])
      (unless (string-contains? p bindir)
        (printf "  hint: add ~a to PATH: export PATH=\"~a:$PATH\"~%" bindir bindir)))))
