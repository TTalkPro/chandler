# 14 — Windows 可移植性

> 状态: **代码侧已完成,尚未在 Windows 上验证**。本文是 Windows 支持的权威设计。
> D33–D39 **全部落地**(TASK.md 的 C1–C10),测试套件也已去掉 shell 依赖(§12.1);
> 只剩 **Windows CI 跑绿**这一步 —— workflow 已写(`.github/workflows/windows.yml`),
> 但没有在 GitHub Actions 上执行过。
>
> **在 CI 跑绿前,Windows 支持一律标注「未验证」。** 已落地的部分由平台参数化
> 测试在 Linux 上逐字断言(cmd 引用规则另与 MSVCRT 参考实现交叉验证过),
> 但**没有一行在真 Windows 上跑过**。少数条目连断言都做不到 ——
> 比如「Windows 的 rename 不覆盖既有目标」,POSIX 上把补丁去掉测试照样绿,
> 那条只能等 CI。这类地方在测试注释里逐条写明了,没有假装已经验证。
> 来源:2026-07-27 全库平台相关代码走查(`proc` / `fs` / `layout` / `compile` /
> `native-build` / `pack` / `registry` / `bootstrap` / 启动器)。

## 1. 一句话目标

让 chandler 在 Windows 上**开发得动、装得上、发得出**,且分发出去的包
**只依赖 Windows 必然存在的东西**(cmd.exe),不依赖 PowerShell、不依赖 MSYS/Cygwin。

三条边界,优先级从高到低:

| 层 | 依赖底线 | 理由 |
|----|---------|------|
| **pack 分发态**(终端用户) | 只能依赖 `cmd.exe` | 用户机器什么都没装,pwsh 从不预装,ExecutionPolicy 可能拒跑脚本 |
| **install 态**(装了 chandler 的用户) | 只能依赖 `cmd.exe` + PATH 上的 Scheme runtime | 同上;`chandler install` 生成的启动器要能被任意父进程调起 |
| **开发态**(chandler 自身 / `-j` 并行构建) | 可以依赖 pwsh(`mise use powershell`) | 只影响开发者,不进产品路径 |

## 2. 现状盘点

### 2.1 已经做对的部分(不要动)

- `layout.ss` `path-sep` —— `$separator-character` 随平台(Windows `;`),
  且条目内 `src;;obj` 双分隔符表 (源 . 对象) 对。有依据、有测试。
- `layout.ss` `windows-mt?` / `so-ext` —— `ta6nt` 后缀判别 + `.dll`。
- `registry.ss` `default-*-libdir/bindir` —— `%LOCALAPPDATA%` / `%ProgramData%` 分支。
- `sexp.ss` `write-canonical-file`、`pack/core.ss` `commit-pack-output!`、
  `registry/staging.ss` `promote-staging!` —— 都处理了「Windows 的 rename 不覆盖」。
- `pack/paths.ss` `exe-name` —— 捆绑可执行文件带 `.exe`。
- `fs.ss` `home-dir` —— 认 `USERPROFILE`。

**问题不在这些策略层,而在它们脚下的两块地基:子进程层和路径层。**

### 2.2 硬阻塞(P0)

| # | 位置 | 问题 |
|---|------|------|
| P0-1 ✅ | `proc.ss` 全文 | 整层假设 `/bin/sh`。`shell-quote` 是 POSIX 单引号、`env-prefix` 生成 `K=v cmd` 前缀、`cd d && `、`which` 用 `command -v`、`real-path` 用 `readlink -f`。**git / native / pack / run / exec 全线经此**。`bootstrap.ss:91` 的 `q` 是同一份实现的副本 |
| P0-2 ✅ | `fs.ss` `system-temp-dir` | 两半都已修:①`make-temp-dir` 的**死循环**(C5);②`system-temp-dir` 现在依次认 `TMPDIR` → `TEMP` → `TMP` → 平台默认,空串视为未设(C7) |
| P0-3 ✅ | `cli/commands.ss:325` | `Join-Path $LibDir $Name $Active …` 是 PowerShell 6+ 语法;Windows 预装的是 **5.1**,该行直接报错 → 现有 `.ps1` 启动器在裸机上必挂 |
| P0-4 ✅ | 启动器格式 | `.PS1` 不在默认 `PATHEXT` 里 → cmd 中敲 `chandler` 找不到,被别的程序 spawn 也找不到;叠加 ExecutionPolicy |
| P0-5 ✅ | `bin/chandler` | 只有 sh 版,Windows 上没有开发期入口 |

### 2.3 静默出错(P1)

| # | 位置 | 问题 |
|---|------|------|
| P1-1 ✅ | `fs.ss:32` `last-slash` 及其下游 | 只扫 `#\/`。Chez 在 Windows 上返回反斜杠路径,一旦混入 `\`:`base-name` 返回整串;`path-has-segment?`(:166)认不出 `_build`/`.git` 段 → **install 清单与 `chandler verify` 会把生成物和 `.git` 当受管文件**;`relativize`(:180)纯前缀匹配失败 |
| P1-2 ✅ | `runtime-paths.ss:25` | `validate-resource-segment` 只拒含 `/` 的 segment。Windows 上 `\` 同样是分隔符 → `(resource-path '(app) "..\\..\\secret")` **绕过全部四条校验**。安全相关 |
| P1-3 ✅ | `lock.ss:134` / `install.ss:109` | `sha256-file` 读原始字节;Windows 上 git 默认 `core.autocrlf=true` → Linux 生成的 lock 在 Windows 上 hash 必然失配,`lock-fresh?` 恒判 stale、`verify` 恒报文件被改 |
| P1-4 ✅ | `fs.ss:88` `rm-rf` | 每步 `ignore-errors`。Windows 上 ① git 的 `.git/objects/**` 只读 → 删不掉;② 已 `load-shared-object` 的 DLL / 运行中的 exe 不能删也不能改名。**失败被吞,调用方以为清干净了** |
| P1-5 ✅ | `pack/core.ss:183` | `copy-exe!` 无条件 `chmod +x`,没有 win 分支(`launchers.ss:90` 与 `commands.ss:359` 有) |
| P1-6 ✅ | `fs.ss:110` `move-file` | 唯一没做「rename 不覆盖」处理的搬运函数;调用点 `compile.ss:295` `touch-file!` 套了 `ignore-errors` → **Windows 上 touch 静默失效**,mtime 不更新 |
| P1-7 ✅ | `compile.ss:588` `run-chunk` | `-j N` 并行编译生成 `cmd & pN=$!` / `wait $pN` 的 sh 脚本再 `system "sh …"` |

### 2.4 边角(P2)

- `fs.ss:45` `absolute-path?` 过宽:只要第二字符是 `:` 就算绝对路径,POSIX 上 `a:b` 会被误判。
- NTFS 大小写不敏感:registry 里 `Foo` 与 `foo` 撞同一目录;库名叫 `aux`/`con`/`nul`/`prn` 造不出文件。
- `fetch.ss:24` `default-cache-root` 落到 `%USERPROFILE%\.cache`,不合 Windows 惯例(`registry.ss` 已区分,cache 没有)。
- Windows 环境变量大小写不敏感,`.env` 的键与 `getenv` 查找可能对不上。
- ✅ 测试套件自身用 `sh -c` / `/tmp`(`tests/chandler/proc.ss`、`cli.ss:367`、`sexp.ss:10` 等)—— 即使核心修好,**Windows 上也无回归防线**。已清理,见 §12.1。

## 3. 关键约束(实测)

### 3.1 Chez 没有「不经 shell 的 spawn」

在 Chez 10.4.1 上实测:

```scheme
(open-process-ports "echo a && echo b" (buffer-mode block) (native-transcoder))
;; → 依次读出 "a" "b"
```

`open-process-ports` 与 `system` 一样,**收的是一条 shell 命令串**,`&&` 被 shell 解释了。
即:stock Chez 不提供 argv 数组式的进程创建。

**推论**:Windows 支持不能靠「绕开 shell」实现,只能靠**把 shell 的引用规则做对**。
(FFI 直调 `CreateProcessW` / `_wspawnvp` 是理论选项,但要手搓 `STARTUPINFO` 或
`char**`,且把 chandler 从「纯 Scheme + 系统 git」拖进 FFI 依赖 —— 不做,见 §11。)

### 3.2 Windows 上的 shell 是 cmd.exe,不是 PowerShell

Chez 的 `system` 走 `%COMSPEC%`,即 `cmd.exe`。所以:

- 开发机装了 PowerShell **不会让 `proc.ss` 的任何一行变得能跑**。
- 若显式拼 `pwsh -Command "…"`,等于在 cmd 的引用规则之上再叠一层 PowerShell 的
  引用规则,**两层引用嵌套**,比直接面对 cmd 更难写对、更难测。

**决策**:产品路径一律面向 cmd.exe;PowerShell 只在开发态可选使用(§8.4)。

> 待核实(C9 在真 Windows 上确认):Chez 的 `system` 是否严格走 `%COMSPEC%`、
> 是否对命令串做额外包裹。
>
> **换行那一问已经不必答了**(§9 落地时消解):先前担心的是「Chez 的文本端口在
> Windows 上是否把 `\n` 写成 `\r\n`」——`(make-transcoder codec)` 取
> `(native-eol-style)`,那确实是平台相关的。现在 `fs.ss` **显式**用
> `(eol-style none)`,答案是什么都不影响结果。**不去依赖一个答案,好过去猜它。**

### 3.3 cmd.exe 的引用规则

两层,必须分开想:

1. **目标程序的 argv 解析**(MSVCRT 规则):参数用 `"` 包;`"` 前的连续反斜杠加倍;
   `"` 本身写成 `\"`。
2. **cmd.exe 自己的命令行解析**:`& | < > ^ ( )` 在**引号外**特殊,需 `^` 转义;
   在引号内不特殊。

一处**无解**的角落:`%` 在双引号内也会被 cmd 做变量展开,且没有可靠转义。
含 `%` 的值必须改走环境变量传递,或接受失真。npm / yarn / mise 的 Windows shim
同样活在这个限制下。

## 4. 设计决策

| # | 决策 | 理由 |
|---|------|------|
| **D33** | `proc.ss` 改为**平台派发的引用/环境层**,不追求 shell-free | §3.1 —— stock Chez 没有 argv spawn,绕不开;做对引用是唯一的路 |
| **D34** | 启动器改用 **`.cmd`**,`.ps1` 下线 | 只依赖 cmd.exe;`.CMD` 在默认 PATHEXT 里;无 ExecutionPolicy;现有 `.ps1` 在预装的 PS 5.1 上本来就是坏的(P0-3) |
| **D35** | 新增 **`.registry/<name>.active` 纯文本 sidecar** | 启动器复杂度的**唯一来源**是「要解析 s-expr 找 active version」(sh 用 awk、ps1 用正则,两份实现两份 bug 面)。派生一个单行文本文件后,两边都变成一行读取,且切断了「shim 需要理解 registry 格式」这条耦合 |
| **D36** | 路径原语同时认 `/` 与 `\`,单一出处 | P1-1 是**静默**错误(清单内容悄悄变错),比崩溃更危险 |
| **D37** | `-j` 并行编译在 Windows 上**退化为串行 + 明确提示** | `run-chunk` 的 sh 脚本是在补 Chez 缺失的「等多个子进程」原语;cmd 没有等价物。`-j` 是开发者便利,不值得为它引入 pwsh 依赖(可选增强见 §8.4) |
| **D38** | 跨平台字节一致性靠 `.gitattributes` + 二进制写,而非 hash 时归一化 | 归一化会让 hash 不再是「文件真实内容的指纹」,verify 的语义就废了。源头钉死换行才是对的 |
| **D39** | native 的 `(script …)` 收**多个**脚本,按扩展名挑本平台能跑的 | 脚本是用别的语言写的,解释器两个平台不一样(sh / cmd)。要两边都能建就得两边各带一份 —— 这是事实,不是我们造出来的复杂度。挑不出来即 config 错(§12.2) |

## 5. 子进程层(D33)—— ✅ 已实现

`proc.ss` 内部按平台分派,**导出面不变**(`run-capture` / `run-check` / `run-status` /
`run-foreground` / `shell-quote` / `env-prefix` / `which` / `real-path`)。

| 需求 | POSIX | Windows(cmd) |
|------|-------|--------------|
| 参数引用 | `'…'`,`'` → `'\''`(现状) | `"…"` + MSVCRT 反斜杠规则 + 引号外元字符 `^` 转义(§3.3) |
| 环境注入 | `K='v' cmd`(现状) | `set "K=v" && cmd` —— `bootstrap.ss:239` 已是此写法,抄过去 |
| cwd | `cd 'd' && ` | `cd /d "d" && ` —— **`/d` 不能少**,跨盘符会静默失败 |
| 重定向 | `>f 2>e` | 同左,cmd 支持 |
| `which` | `sh -c "command -v …"` | `where.exe <prog>`(Win7+ 自带),取首行 |
| `real-path` | `readlink -f` | 直接返回原路径 —— 三个调用点(`pack/runtime.ss:22,27,50`)只是为找宿主 skiff/scheme,Windows 上无符号链接需求 |

**`make-temp-dir` 一并修**(P0-2):区分「目录已存在」(重试)与「其它错误」(抛),
不再对任何失败都无限 loop。

**验证方式**:`shell-quote` / `env-prefix` / `cd` 前缀三者做**平台参数化的单元测试**
—— 把平台判别抽成一个可 `parameterize` 的参数,于是 Linux 上也能测 Windows 分支的
**生成结果**(字符串比对),Windows 上再做端到端穿 cmd 的实跑。这与
`bootstrap-parity` / `pack-verifier-parity` 已有的「把代码当数据测」路子一致。

## 6. 路径层(D36)—— ✅ 已实现

`fs.ss` 加一个**单一出处**的分隔符谓词,下游全部改走它:

```scheme
(define (path-sep-char? c) (or (char=? c #\/) (char=? c #\\)))
```

受影响函数:`last-slash`(:32)→ `parent-dir` / `base-name`;`path-join*`(:26);
`path-has-segment?`(:166);`relativize`(:180);`rel-files-under`。

`relativize` 另需处理**分隔符不一致**的前缀匹配(root 用 `/`、abs 用 `\` 的混合情形)
—— 比较前按段拆分,不做裸字符串前缀比较。

`absolute-path?`(:45)顺带收紧(P2):`[A-Za-z]` + `:` + 后跟分隔符,才算 Windows 绝对路径。

**`runtime-paths.ss:25` 的 `\` 穿越校验独立于本节优先修**(P1-2)—— 一行的事,
且是安全边界,不该等整个 Windows 计划落地。

## 7. 环境与临时目录 —— ✅ 已实现

- `system-temp-dir`(`fs.ss:188`):`TMPDIR` → `TEMP` → `TMP` → 平台默认。
- `fetch.ss:24` `default-cache-root`:Windows 上走 `%LOCALAPPDATA%\chandler\cache`,
  与 `registry.ss` 的 `default-user-libdir` 同一套判别。
- `.env` 键大小写(P2):记录已知差异,不做归一化 —— 归一化会让 `.env` 的行为
  在两个平台上不同,而显式声明的键本就该原样使用。

## 8. 启动器(D34 + D35)

### 8.1 `.registry/<name>.active` sidecar(D35)—— ✅ 已实现

`install` / `switch` 在写 `.registry/<name>.ss`(**权威**)的同时,派生一个单行文本
`.registry/<name>.active`,内容就是版本号 + **结尾换行**(POSIX `read` 需要它才返回成功;
cmd 的 `set /p` 两种都吃)。

- 唯一写入点是 `(chandler registry io)` 的 `write-registered!` / `remove-registered!`
  —— 三个业务入口(install / uninstall / switch)都经它们,故 sidecar 不可能漏更新,
  且天然落在 **D21 per-prefix 进程锁**内;写入走 **D20 式原子写**
  (`fs.ss` 的 `write-text-atomic`,与 `write-canonical-file` 同一份实现)。
- 顺序:**先写权威 `.ss`,再写 sidecar**。两者之间崩溃 → sidecar 陈旧,由 doctor 报出;
  权威文件始终完整。反过来会出现「registry 说 v1、启动器跑 v2」且无人知晓。
- 与 `.ss` 的关系:**派生,不是真相**。`doctor` 新增 issue
  `active-sidecar-drift`(缺失、陈旧、或 lib 上有多余 sidecar 三种形态)。
- lib 不写 sidecar(无 active、无启动器);`uninstall` 一并删除。

**这是让 `.cmd` 可行的前提** —— 没有它,批处理要解析 s-expr,那才是真正「复杂的 shell 脚本」。

**迁移**:D35 之前装的包没有 sidecar,启动器会退 70 并提示
`not installed, or installed by an older chandler; run: chandler install`。
`doctor` 会把它报成 `active-sidecar-drift`;重装或 `chandler switch` 一次即修复。
不做读路径上的自愈 —— `read-registered` 在 `run`/`build`/`repl` 的热路径上,
且不在锁内,让它写文件是错的。

### 8.2 POSIX shim(简化后)—— ✅ 已实现

awk 下线:

```sh
REGFILE="$LIBDIR/.registry/$NAME.active"
[ -f "$REGFILE" ] || { echo "$NAME: not registered (run chandler install)" 1>&2; exit 70; }
IFS= read -r ACTIVE < "$REGFILE"
[ -n "$ACTIVE" ] || { echo "$NAME: no active version (run chandler switch)" 1>&2; exit 70; }
```

其余(runner 检查、runtime 发现、`exec`)与 [08 §2](08-launchers.md) 现状一致。

### 8.3 Windows shim(install 模式)—— ✅ 已实现

全直线代码 + 底部错误标签,无内嵌块、无延迟展开、无正则:

```bat
@echo off
setlocal
set "NAME=<name>"
set "LIBDIR=<libdir>"
set "REG=%LIBDIR%\.registry\%NAME%.active"

if not exist "%REG%" goto :e_notreg
set "ACTIVE="
set /p ACTIVE=<"%REG%"
if not defined ACTIVE goto :e_noactive

set "RUNNER=%LIBDIR%\%NAME%\%ACTIVE%\.chandler\run.sps"
if not exist "%RUNNER%" goto :e_norunner

if /i "%CHANDLER_RUNTIME%"=="skiff" goto :rt_skiff
if /i "%CHANDLER_RUNTIME%"=="chez"  goto :rt_chez
if defined CHANDLER_RUNTIME goto :e_badrt

where skiff  >nul 2>nul && set "RT=skiff"  && goto :run
where scheme >nul 2>nul && set "RT=scheme" && goto :run
where chez   >nul 2>nul && set "RT=chez"   && goto :run
goto :e_nort

:rt_skiff
set "RT=%CHANDLER_SKIFF%"
if not defined RT set "RT=skiff"
goto :run

:rt_chez
set "RT=%CHANDLER_SCHEME%"
if not defined RT set "RT=scheme"
goto :run

:run
"%RT%" -q --program "%RUNNER%" %*
exit /b %errorlevel%

:e_notreg
>&2 echo %NAME%: not registered ^(run chandler install^)
exit /b 70
:e_noactive
>&2 echo %NAME%: no active version ^(run chandler switch^)
exit /b 70
:e_norunner
>&2 echo %NAME%: active %ACTIVE% missing runner ^(reinstall^)
exit /b 70
:e_badrt
>&2 echo %NAME%: invalid CHANDLER_RUNTIME ^(want: skiff ^| chez^)
exit /b 64
:e_nort
>&2 echo %NAME%: no Scheme runtime found ^(install skiff or Chez Scheme^)
exit /b 127
```

退出码与 POSIX 侧逐条对齐(70 / 64 / 127)。
`CHANDLER_RUNTIME=""` 在 cmd 中等价于未定义,`if defined` 判否 → 走 PATH 搜索,
与 sh 的 `""` 分支同语义。

### 8.4 Windows shim(pack 模式)—— ✅ 已实现

pack 启动器本来就没有任何发现逻辑(全是固定相对路径),翻译是平凡的:

```bat
@echo off
setlocal
set "HERE=%~dp0.."
set "SKIFF_BOOT_DIR=%HERE%\lib\chez"
"%HERE%\bin\skiff.exe" -q --program "%HERE%\share\chez\<name>\<version>\.chandler\run.sps" %*
exit /b %errorlevel%
```

stock Chez 版同构。`boots-flags`(`pack/launchers.ss:70`)**原样共用** —— Chez 在
Windows 上也接受 `/`,把 prefix 传 `%HERE%` 即可,不必为 `.cmd` 再写一份。

`.cmd` 不需要 `chmod`,`launchers.ss:90` 的 win 分支直接消失。

### 8.5 `.cmd` 的固有代价(必须知道)

| 项 | 说明 | 处理 |
|----|------|------|
| **换行符** | `write-text` 写 LF;cmd 对 LF-only 大体容忍,但**标签 / `goto` / 多行块**可能出错,而 §8.3 正好用了标签 | 生成 `.cmd` **必须写 CRLF**。加 `write-text-crlf`,或在 launcher writer 里统一转换。**最容易漏的一条** |
| **没有 `exec`** | cmd.exe 作为父进程常驻,进程树多一层 | 退出码用 `exit /b %errorlevel%` 显式转发。Ctrl+C 会弹 `Terminate batch job (Y/N)?` —— npm/yarn shim 同款顽疾,无干净解法(真要解需 `.exe` shim,见 §11) |
| **`%*` 参数保真** | 传原始命令行尾部,已是最优;但含 `%` 的参数会被展开,未加引号的 `& \| < > ^` 会破 | 对 `chandler exec -- …` 这类要求 argv 精确透传的场景是硬限制,写进文档 |
| **UNC 路径** | 不 `cd`,只用 `%~dp0` 拼绝对路径 → UNC 下可用 | 模板里刻意不含 `cd`,保持这条 |
| **PowerShell 调 `.cmd`** | 能调,但 PS 7.3 之前 PowerShell 往原生命令传参会改写引号 | 开发期烦恼,不影响分发 |

### 8.6 连带收益

- **P0-4 消失**:`.CMD` 在默认 PATHEXT 里 → cmd / PowerShell / 被别的程序 spawn
  三种情形都能直接调 `chandler`。
- **`bootstrap.ss:287` 的「Windows 跳过冒烟测试」可以取消** —— 现在跳过是因为没法
  直接跑 `.ps1`;改 `.cmd` 后 `(system (q launcher-path))` 直接可用,补上一个覆盖缺口。
- **模板数量不变但每份都变短**:sh + cmd 各两族,awk / 正则两份解析实现归零。

### 8.7 迁移

- `remove-app-launcher!`(`commands.ss:363`)补删 `.cmd`;`.ps1` 的删除**保留**,
  让旧安装能被干净卸载。
- `bin/chandler`(开发期 wrapper)补一份 `bin/chandler.cmd`,逻辑与 sh 版对齐
  (含 `_prog_ok` 能力探测的等价物或明确省略,二选一并在 parity 测试里钉住)。

## 9. 换行符与 hash 跨平台一致(D38)—— ✅ 已实现

两个方向都要堵:

1. **入口**:仓库根加 `.gitattributes`,把 `*.ss` / `*.sps` / `*.lock` / `*.md` 钉成
   `text eol=lf`,`*.cmd` 钉成 `text eol=crlf`。防止 `core.autocrlf=true` 在 checkout
   时改写文件内容 → P1-3。
2. **出口**:chandler 自己写 lock / registry / manifest 时走**二进制端口**(或显式
   `(eol-style none)` 的 transcoder),保证 Windows 上写出的字节与 Linux 一致。
   `sexp.ss:105` 的 `call-with-output-file` 是主要落点。

`sha256-file` **不做任何归一化** —— 它是「文件真实字节的指纹」,归一化会让
`chandler verify` 失去意义。

## 10. 文件系统语义 —— ✅ 已实现

| 问题 | 处理 |
|------|------|
| `rm-rf` 遇只读文件(git 的 `.git/objects/**`) | 清只读位(Chez 自带 `chmod`,不 shell-out)后重试一次;仍失败则**抛**。**实测发现**:Chez 的 `delete-file`/`delete-directory` 失败时**返回 `#f` 而不抛**(要抛得传 `error?` 第二参),所以原先那圈 `ignore-errors` 其实什么都没接住 —— 静默不是它造成的,是这条默认语义造成的,而 `ignore-errors` 让代码**看起来**已经考虑过失败了(P1-4) |
| `rm-rf` / rename 遇被占用文件(已加载的 DLL、运行中的 exe) | 无法回避,但要**响亮失败**并给可操作提示(「有进程正在使用 X,关闭后重试」),而不是静默留残件 |
| `move-file`(`fs.ss:110`) | 与 `sexp.ss` / `pack/core.ss` / `staging.ss` 对齐:目标存在先删再 rename。修掉 `touch-file!` 在 Windows 上静默失效(P1-6) |
| `copy-exe!`(`pack/core.ss:183`) | 补 win 分支,不调 `chmod`(P1-5) |
| NTFS 大小写不敏感 / 保留名(`aux`/`con`/`nul`/`prn`) | 不做自动改名。`install` 与 `doctor` 增加校验并报错 —— 静默改名会让库名与磁盘路径失去对应 |

## 11. 不在本设计范围

- **FFI 直调 `CreateProcessW` / `_wspawnvp`** —— 能拿到真正的 argv spawn,但把
  chandler 从「纯 Scheme + 系统 git」拖进 FFI 依赖,且要按 mt 分别维护。§3.3 的
  引用规则虽然琐碎,但是**纯字符串逻辑,可在 Linux 上单元测试**,这点更值钱。
- **原生 `.exe` shim** —— 能解掉 Ctrl+C 提示和进程树多一层的问题,但需要 C 工具链
  或预编译二进制进仓库,与 git-first 的分发模型冲突。`.cmd` 的代价可接受。
- **MSYS / Cygwin / WSL 路径互通** —— 明确不支持。目标是**原生 Windows**;
  在 MSYS 环境里跑到的是 POSIX 分支,那是用户自己的选择,不做混合路径转换。
- **跨平台 pack**(一个包多 mt)—— 沿用 [00 §11](00-design-principles.md) 的既有边界,
  per-mt pack,由 CI 分别构建。
- **`-j` 并行编译的 Windows 原生实现** —— D37 退化为串行。可选增强:开发态检测到
  pwsh 时用 `Start-Job`/`Wait-Job`,但**不作为默认、不作为依赖**。

## 12. 验证策略

Windows 支持最大的风险不是写不对,而是**写完没人跑**。三层:

1. **平台参数化单元测试**(Linux 上就能跑):把平台判别抽成可 `parameterize` 的参数,
   对 `shell-quote` / `env-prefix` / cwd 前缀 / 路径原语 / 两族启动器模板,
   断言**生成结果**的字符串。覆盖 `\`、空格、`$`、`&`、`^`、`"`、含 `%` 的已知失真。
2. **launcher parity 测试**:照 `bootstrap-parity` / `pack-verifier-parity` 的模式,
   渲染 sh 与 cmd 两份,解析出 (registry 路径, runner 路径, runtime 候选序,
   五个退出码) 五元组并断言一致。**必须验证非空转** —— 故意制造分叉,确认它会红。
3. **CI**:至少跑 `bootstrap.ss` + `run-tests.sps` + 一次 `pack` 后的实跑。
   `.github/workflows/{linux,windows}.yml` **刻意同构** —— 本节的整个主张就是
   「同一套断言在两个平台上跑」,少跑一步那句话就不成立。Linux 那份另加一遍
   Petite(「跳过」本身也会坏:一条本该被 `when-compiler` 跳过的用例若在 Petite
   上跑起来,就是 `compiler-available?` 判错了)。
   **Windows 那份跑绿之前,Windows 支持一律标注为「未验证」。**

   装运行时两边都不容易,理由不同:Windows 上 release 只有安装器(走 scoop);
   Linux 上 Ubuntu 仓库的 chezscheme 是 9.5.8、够不着 `>=10.0`,而官方 release
   **没有 Linux 二进制**,只能从源码建(走 mise 的 chezscheme 插件,
   `./configure --threads`,产出的就是开发者本地那份 `ta6le`)。

### 12.1 测试套件自身的 shell 依赖(C9)—— ✅ 已清理

第 1、2 层都跑在 `run-tests.sps` 里,于是**套件自己不能依赖 POSIX 工具**,
否则第 3 层根本起不来。清掉的与保留的:

| 原来 | 现在 |
|------|------|
| 夹具的 `mktemp -d` 子进程(两处) | `(chandler fs)` 的 `make-temp-dir`,由 harness 的 `mktmp` 统一登记清理 |
| 硬编码 `/tmp/…`(sexp / lock) | 每用例一个临时目录;纯字符串用的字面量改成不像临时目录的形状,免得被当成需要真存在的路径 |
| `sh -c` + `echo` / `pwd` / `true` / `false` 做端到端 | **探针程序 = Scheme 运行时本身**(harness 的 `run-probe`)。它两平台都在,且按各自规则解析 argv —— 批处理做不到:cmd 的 `%*` 给的是原始命令行尾部(引号还在),`%1` 又脱一层引号,两者都证明不了 argv 里到底是什么 |
| `chmod +x` / `mkdir -p` 子进程 | `fs` 的 `make-executable!` / `ensure-dir`(生产侧三处 `chmod +x` 也一并收口) |
| `command -v`(native-build 的 include 探测) | `proc` 的 `which`(按平台走 `command -v` / `where.exe`) |
| pack 版本探针的 `sh -c "… < /dev/null"` | `run-capture` 的 `(env . …)` / `(stdin . null)`;空设备名由 `fs` 的 `null-device` 按平台给出 |
| 只在 `/bin/sh` 语义下成立的断言 | 保留,但用 `when-posix` **明确跳过**另一侧,并在注释里写明对侧由谁守 —— 跳过不是放宽 |

## 12.2 native `script` 后端的 Windows 分支(D39)

**问题**:`run-script-backend` 原先写死 `sh <script>`。Windows 上没有 sh,于是
声明了 `(build (script …))` 的依赖根本建不起来,报出来的还是 cmd 的一句
「'sh' 不是内部或外部命令」—— 既不提 native-task,也不提该怎么办。

**为什么不能只换个解释器**:脚本是**用别的语言写的**,而那门语言的解释器两个
平台不一样。`sh build.sh` 换成 `cmd /c build.sh` 不会让 sh 脚本变得能跑;要求
Windows 用户装 sh 又和 §1 的底线("只依赖 cmd.exe")冲突。**一个包要两边都能建,
就得两边各带一份脚本 —— 这是事实,不是我们造出来的复杂度。**

**D39**:`(script …)` 收**一个或多个**脚本,按扩展名挑第一个本平台能跑的。

```scheme
(build (script "build.sh"))                ; 只在 POSIX 上能建
(build (script "build.sh" "build.cmd"))    ; 两边都能建
```

| | 可跑的扩展名 | 起法 |
|---|---|---|
| Windows | `.cmd` / `.bat`(大小写不敏感) | `call <script>` |
| POSIX | **除** `.cmd` / `.bat` 之外的一律可跑 | `sh <script>` |

三条取舍,都有理由:

- **`call` 不能省**:cmd 里不带 `call` 调另一个批处理时,控制权**不返回** ——
  后面的命令不执行,errorlevel 也不回传。这类问题不会崩,只会让失败的构建
  看起来成功了。
- **POSIX 侧刻意不要求 `.sh`**:现存的包写 `(script "build")` / `"mk.bash"`
  都是合法的,收紧扩展名等于无端把它们判死。只排除 `.cmd` / `.bat` 就够 ——
  它们在多脚本声明里必须让位给 sh 那份。
- **挑不出来 → config 错,当场说清该加什么**,而不是把命令扔给 shell 让它
  用自己的话报错。

**连带**:多带一个脚本会改 `native-fingerprint`(build 声明进哈希)。这是对的 ——
构建描述变了,依赖的 `--allow-build` 授权本就该重新确认(designs/07)。

**同一处顺带修掉的静默失效**:`toolchain-id` 原先用
`cc --version 2>/dev/null | head -1` 取工具链版本。那是 POSIX shell 的写法 ——
Windows 上 `/dev/null` 不是路径、`head` 不是程序,整条命令失败后被 guard 吞成 `""`。
于是**指纹里的工具链分量恒为空**:换了编译器也不会让 native 产物失效,而
这个函数存在的唯一理由就是那个。改走 `run-capture`(stderr 本就分开捕获,
不需要 `2>`)+ 在 Scheme 里取首行;POSIX 上逐字节同结果,故已有指纹不失效。

**验证**:`pick-script` / `script-command` 都是纯函数并导出,两侧在 Linux 上
用 `windows-shell?` 参数化逐字断言(`cd /d` / `set "K=v" &&` / `call` 三处差异
一次看清);夹具的 native 依赖同时带 `build.sh` 与 `build.cmd`,于是 build / pack
的 native 端到端用例**两平台跑同一组断言**,不再有 POSIX 门。

## 13. 落地顺序

按「先无风险、后有风险」和「先解耦、后改地基」排:

| 序 | 内容 | 为何这个位置 |
|---|------|------------|
| 1 | `.registry/<name>.active` sidecar(D35) | 纯增量,POSIX 侧先受益(awk 下线),不动任何 Windows 代码就能测 |
| 2 | `runtime-paths.ss` 的 `\` 穿越校验(P1-2) | 一行,安全边界,不该等 |
| 3 | 启动器 `.ps1` → `.cmd`(D34)+ CRLF 写入 + parity 测试 | 依赖第 1 步;做完 Windows 就「装得上、发得出」 |
| 4 | `.gitattributes` + 二进制写(D38) | 独立;不做则跨平台协作随机报错 |
| 5 | `proc.ss` 平台派发层(D33) | 最大一块,但可独立单元测试;做完 Windows 才「开发得动」 |
| 6 | 路径原语认 `\`(D36)+ `system-temp-dir` + 文件系统语义(§10) | 依赖第 5 步的实跑才能验证 |
| 7 | 测试套件去 shell 依赖 + CI | 前面所有工作的验收关口。套件侧已清理(§12.1);CI 见 `.github/workflows/{linux,windows}.yml`,两份**都还没在 Actions 上跑过** |
| 8 | native `script` 后端的 Windows 分支(D39) | 第 7 步收尾时点出的缺口 —— 它不挡「装得上、发得出」,只挡「建得了带 native 的依赖」,故排在验收关口之后单独做(§12.2) |

## 相关文档

- [00-design-principles.md](00-design-principles.md) — 宪法;决策记录 D33–D38
- [08-launchers.md](08-launchers.md) — 启动器现状(§3 的 PowerShell 版将被本文 §8 取代)
- [04-install.md](04-install.md) — `.registry/` 形态与 install 事务
- [05-pack.md](05-pack.md) — pack envelope 与分发态约束
