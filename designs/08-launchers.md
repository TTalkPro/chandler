# 08 — 启动器生成

> 状态: 已实现(v3 + v4),对齐 `chandler/cli/commands.ss` `write-app-launcher!` /
> `app-launcher-sh` / `app-launcher-cmd` 与 `chandler/pack/launchers.ss`。
> v3 中心设计见 [06-installed-layout.md](06-installed-layout.md) §10。

## 1. 一句话目标

生成两种形态的启动器,**都是稳定 shim**(D17):模板里**不嵌入 version**,
version 由启动器运行时读 `<libdir>/.registry/<name>.active` 决定;
`chandler switch` 改 active,shim 文件永不重写。

> **v4(D35)**:shim 读的是 `.registry/<name>.active` **纯文本 sidecar**(单行版本号
> \+ 结尾换行),不是权威的 `<name>.ss`。先前 sh 侧用 awk、ps1 侧用正则各解析一遍
> s-expr —— 两份实现、两份 bug 面,还让 shim 与 registry 的文件格式绑死。
> sidecar 的写入点、顺序与 drift 检测见 `chandler/registry/io.ss`;
> 动机见 [14-windows-portability.md §8.1](14-windows-portability.md)。

| 模式 | 启动器位置 | runtime 来源 | 找 run.sps 的依据 |
|------|----------|------------|------------------|
| **install** | `~/.local/bin/<app>`(POSIX)/ `%LOCALAPPDATA%\chez\bin\<app>.cmd`(Windows) | 系统 runtime(运行时发现,skiff 优先) | `.registry/<app>.active` 的单行版本号 → `<libdir>/<app>/<v>/.chandler/run.sps` |
| **pack** | `<pack>/bin/<app>`(POSIX)/ `<pack>/bin/<app>.cmd`(Windows) | bundled `<pack>/bin/<runtime>` | `<pack>/share/chez/<app>/<v>/.chandler/run.sps`(同 layout) |
| **dev** | (无独立启动器) | — | `chandler run` 子进程:实时算 `resolved-libdirs`,不走 shim |

## 2. POSIX 稳定 shim(install 模式)

```sh
#!/bin/sh
# <name> launcher — chandler v3 stable shim; do not edit.
# Reads active version from .registry/<name>.active at runtime.
NAME="<name>"
LIBDIR="<libdir>"
REGFILE="$LIBDIR/.registry/$NAME.active"

[ -f "$REGFILE" ] || { echo "$NAME: not installed, or installed by an older chandler; run: chandler install" 1>&2; exit 70; }

# Plain-text sidecar: one line, the active version. No s-expr parsing needed.
IFS= read -r ACTIVE < "$REGFILE"
[ -n "$ACTIVE" ] || { echo "$NAME: no active version; run: chandler switch" 1>&2; exit 70; }

RUNNER="$LIBDIR/$NAME/$ACTIVE/.chandler/run.sps"
[ -f "$RUNNER" ] || { echo "$NAME: active version $ACTIVE missing runner (reinstall)" 1>&2; exit 70; }

# Runtime discovery: CHANDLER_RUNTIME > PATH search (skiff > scheme > chez)
case "${CHANDLER_RUNTIME:-}" in
  skiff) _rt="${CHANDLER_SKIFF:-skiff}" ;;
  chez)  _rt="${CHANDLER_SCHEME:-scheme}" ;;
  "")    for _c in skiff scheme chez; do
            command -v "$_c" >/dev/null 2>&1 && { _rt="$_c"; break; }
          done ;;
  *) echo "$NAME: invalid CHANDLER_RUNTIME (want: skiff|chez)" 1>&2; exit 64 ;;
esac

[ -z "$_rt" ] && { echo "$NAME: no Scheme runtime found (install skiff or Chez Scheme)" 1>&2; exit 127; }

exec "$_rt" -q --program "$RUNNER" "$@"
```

### 2.1 关键点

- **不嵌 version**:启动器文件名 = `<app>`,内部只引 `<libdir>`;`ACTIVE` 每次启动现读
- **`--libdirs` 没了**(与 v2 不同):run.sps 自己在 §3 步通过 lock 驱动设
  `library-directories`,launcher 无需预先挂 chandler-runtime
- **`--program "$RUNNER"`**:runtime 加载 run.sps;run.sps 内做挂库 + 入口
- 启动器跨 install/uninstall 持久;同 name 重装不必删 shim(D17 不变量)
- shim 失败原因直接打到 stderr,且退出码语义化(70 / 64 / 127)

## 3. Windows 稳定 shim(`.cmd`)

**D34:`.ps1` 已下线,Windows shim 是批处理。** 理由三条,任何一条都够呛:

1. **pwsh 从不预装**。Windows 10/11 自带的是 **PowerShell 5.1**,而旧 `.ps1` 模板用了
   PS6+ 的 `Join-Path` 多段形式 —— 在裸机上直接报错,即「用户什么都不装就必挂」。
2. **ExecutionPolicy** 可能拒跑未签名脚本。对「解包即用」的分发包是不可接受的门槛。
3. **`.PS1` 不在默认 `PATHEXT` 里**。`bin/` 进 PATH 后,cmd 里敲 `myapp` 找不到,
   被别的程序 spawn 也找不到。

`.cmd` 三条全无:只依赖每台 Windows 必有的 cmd.exe,`.CMD` 在默认 PATHEXT 里,
不受执行策略管。完整动机见
[14-windows-portability.md §8](14-windows-portability.md)。

```bat
@echo off
rem <name> launcher -- chandler v4 stable shim; do not edit.
rem Reads active version from .registry\<name>.active at runtime.
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

rem Runtime discovery: CHANDLER_RUNTIME > PATH search (skiff > scheme > chez).
rem An empty CHANDLER_RUNTIME is undefined to cmd, so it falls through to the
rem PATH search -- same semantics as the sh shim's "" branch.
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
>&2 echo %NAME%: not installed, or installed by an older chandler; run: chandler install
exit /b 70
:e_noactive
>&2 echo %NAME%: no active version; run: chandler switch
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

### 3.1 关键点

- **全直线代码 + 底部错误标签**。不用内嵌 `( … )` 块(块内变量按块解析,要么写延迟
  展开要么处处踩坑)、不用正则、**不 `cd`**(于是 UNC 路径下也可用)。
- **必须 CRLF**。cmd.exe 对 LF-only 的批处理大体容忍,但标签与 `goto` 会出错 ——
  而本模板正是用标签组织的。由 `(chandler fs)` 的 `write-text-crlf` 保证。
- **ASCII-only**。cmd.exe 按 OEM 代码页读批处理,不是 UTF-8;注释里的非 ASCII
  即便无害也会显示成乱码。
- **退出码显式转发**:cmd 没有 `exec`,不写 `exit /b %errorlevel%` 就永远返回 0。
- 退出码与 POSIX 侧逐条对齐(70 / 64 / 127),由 `tests/chandler/launcher-parity.ss` 钉住。

### 3.2 与 POSIX 侧刻意保留的差异

这两条是 cmd 的固有限制,**不是待修的 bug**(parity 测试里显式钉住,免得被人「修」掉):

| 差异 | 后果 |
|------|------|
| cmd 无 `exec` | cmd.exe 作为父进程常驻,进程树多一层;Ctrl+C 会弹 `Terminate batch job (Y/N)?`。无干净解法,除非将来出真的 `.exe` shim |
| `%*` vs `"$@"` | `%*` 传原始命令行尾部(cmd 下最保真的做法),但含 `%` 的参数会被展开、未加引号的 `& \| < > ^` 会破。npm/yarn 的 Windows shim 同款限制 |

## 4. pack 模式启动器

pack 启动器与 install shim **不是同一份模板**:pack 启动器指 **bundled runtime**
(`<pack>/bin/<runtime>`),**不读 `.registry/`**(pack 是部署态,无注册表)。

### 4.1 POSIX

skiff 包(`launcher-sh-skiff`):

```sh
#!/bin/sh
# generated by chandler pack -- do not edit
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export SKIFF_BOOT_DIR="$HERE/lib/chez"
exec "$HERE/bin/skiff" -q --program "$HERE/share/chez/<name>/<version>/.chandler/run.sps" "$@"
```

stock 包(`launcher-sh-stock`)—— 用绝对 `-b` 链取代 `SKIFF_BOOT_DIR`:

```sh
#!/bin/sh
# generated by chandler pack -- do not edit
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec "$HERE/bin/scheme" -b "$HERE/lib/chez/petite.boot" [-b "$HERE/lib/chez/scheme.boot"] \
  -q --program "$HERE/share/chez/<name>/<version>/.chandler/run.sps" "$@"
```

### 4.2 Windows(`.cmd`)

与 §3 同样的理由改用批处理(D34)。pack 启动器**没有任何发现逻辑** —— 全是从
`%~dp0..` 起算的固定相对路径 —— 所以翻译是平凡的:

```bat
@echo off
rem generated by chandler pack -- do not edit
setlocal
set "HERE=%~dp0.."
set "SKIFF_BOOT_DIR=%HERE%\lib\chez"
"%HERE%\bin\skiff.exe" -q --program "%HERE%\share\chez\<name>\<version>\.chandler\run.sps" %*
exit /b %errorlevel%
```

stock 包同构,`-b` 链取代 `SKIFF_BOOT_DIR`:

```bat
"%HERE%\bin\scheme.exe" -b "%HERE%\lib\chez\petite.boot" [-b "%HERE%\lib\chez\scheme.boot"] -q --program "%HERE%\share\chez\<name>\<version>\.chandler\run.sps" %*
exit /b %errorlevel%
```

要点:

- **`%~dp0` 带尾反斜杠**,故 `%~dp0..` 就是包根;**不 `cd`**,于是 UNC 下可用。
- **可执行文件带 `.exe`**(`pack/paths.ss` 的 `exe-name`):`.cmd` 按全名调用,
  无扩展名跑不起来。
- **`boots-flags` 两侧共用同一个函数** —— Chez 在 Windows 上也接受 `/`,不必写第二份;
  只在 cmd 侧出口把分隔符归一成 `\`,免得生成半 Unix 半 Windows 的路径。
- CRLF / ASCII-only / `exit /b %errorlevel%` 三条同 §3.1。

### 4.3 boot 路径

包内 boot 恒在 `<pack>/lib/chez/`(与 `bin/` 平级),两种运行时的交接方式不同:

- **skiff 包**:`SKIFF_BOOT_DIR=<pack>/lib/chez`,启动器 export 后 exec。
  env 是唯一可用的交接方式 —— skiff 按 exe 相对找 boot(`<exedir>/../lib/skiff/boot`),
  包内布局对不上;而 boot 必须在进程有堆之前注册,远早于 `--program` 被解析。
- **stock 包**:`-b "<pack>/lib/chez/petite.boot"` 绝对路径链。`petite.boot` 恒随;
  `scheme.boot` 只在 `runtime=scheme` 时随(部署态只 fasl 载入预编译 `.so`,
  petite 单独即可,包更小)。

详见 [05-pack.md](05-pack.md)。

## 5. run.sps 交接(lock 驱动,D18)

shim 把控制权交给 run.sps(`--program`),run.sps 做三件事:

1. **根推导**:`run.sps` 路径 = `<libdir>/<name>/<version>/.chandler/run.sps`,
   4 次 `path-parent` 得 `%root`(install = libdir;pack = share/chez)
2. **lock 驱动**(D18):读 `.chandler/chandler-manifest.lock` 的 `(deps ...)`,
   每 dep 取 `(pin (kind "val"))` 的 val 拼 `%root/<dep>/<val>/src::<mt>` 挂
   `library-directories`(版本目录名与 install 布局一致;lock 缺失 = 零依赖,
   不报错)
3. **入口**:`(eval (list '<main> (list 'quote args)) env)`,env 含 `(chezscheme)`
   + 入口库;main 契约 argv → exit-code,`(exit rc)` 透传回 shim → 父进程

run.sps 在 [06 §9](06-installed-layout.md#9-runsps-设计d18-lock-驱动) 有完整内容;
pack 模式追加 manifest 校验 + native walk。

## 6. 启动器生成位置

| 模式 | 触发 | 实现位置 |
|------|------|---------|
| install | `cmd-install`(app install 时) | `chandler/cli/commands.ss:write-app-launcher!` → `app-launcher-sh` + `app-launcher-cmd` |
| pack | `cmd-pack`(app pack 时) | `chandler/pack/launchers.ss:write-launcher!` → `launcher-{sh,cmd}-{skiff,stock}` |
| uninstall | `cmd-uninstall-global` | `remove-app-launcher!`(删 shim;不删 run.sps,它在 vroot 里随 rm -rf 走) |

### 6.1 不重写不变量(D17)

- shim 生成一次,后续 install / switch / doctor / uninstall 都不重写它(同 name 重装保留)
- switch 只改 `<libdir>/.registry/<name>.ss` 的 `(active ...)` → 所有新进程立即用新版本
- shim 持久跨 install/uninstall 生命周期

## 7. runtime 发现逻辑

shim 与 `chandler run` / `repl` / `exec` 共享同一套优先级(`interp-kind` + `choose-interp`,
[06 §11](06-installed-layout.md#11-cli-命令) 与 [11-cli.md](11-cli.md) §5):

```
--runtime 旗标  >  CHANDLER_RUNTIME 环境变量  >  manifest 声明(chez-only→chez / skiff-only→skiff)  >  默认:跟随 chandler 当前所在
```

- 默认 skiff:chandler 自己的启动器已 skiff 优先 → "当前所在"天然是"能用 skiff 就 skiff,
  否则 chez",不用单独探测;**显式**则照单执行,找不到即 127 不回退
- 显式 `CHANDLER_SKIFF=<path>` / `CHANDLER_SCHEME=<path>` 也照单(只试这个 exe,
  找不到即 127),**不静默回退**(静默回退 = 否定了用户的覆盖意图)

### 7.1 退出码

| 退出码 | 含义 |
|--------|------|
| 64 | `CHANDLER_RUNTIME` 非法值(不是 skiff/chez) |
| 70 | 启动器发现失败(registry 缺失 / 无 active / runner 缺失) |
| 127 | 找不到任何可用 runtime |

## 8. 与 v2 的差异

| 维度 | v2 | v3 |
|------|----|----|
| 形态 | 生成式,模板里 embed VERSION | 稳定 shim,version 运行时读 `.registry/` |
| version 切换 | 重写 launcher + `--libdirs` 重挂 | 改 `.registry/<name>.ss` 的 `(active ...)`,launcher 永不重写 |
| `--libdirs` 初始值 | `chandler-runtime/src::mt`(让 `(chandler setup)` 可见) | 不挂 `--libdirs`:run.sps 自管挂库 |
| `(chandler setup)` | 在 run.sps 里执行四步流程(反推 lock + 重写 library-directories) | **不存在**:library-directories 由 run.sps 直接 lock 驱动精确挂(D18) |
| bootstrap paradox | 需 shim 预先挂 chandler-runtime,让 `(chandler setup)` 能 import | run.sps 不 import `(chandler setup)`,lock 驱动天然精确挂,无 paradox |

> v3 的 run.sps 是**自足**的:它只读自己的 lock,然后直接挂库并执行 main;不需要先 bootstrap 一份 chandler runtime 让某个 setup 函数重写路径 —— 这就是 bootstrap paradox 的根除。

## 9. Windows 特殊处理

### 9.1 路径约定

| 平台 | 用户 bin 目录 |
|------|--------------|
| POSIX | `~/.local/bin/` |
| Windows | `%LOCALAPPDATA%\chez\bin\`(libdir 内) |

### 9.2 为什么不需要 PowerShell

启动器是 `.cmd`(D34),**只依赖 cmd.exe** —— 每台 Windows 必有,不受
ExecutionPolicy 管,`.CMD` 也在默认 `PATHEXT` 里(故 cmd / PowerShell /
被别的程序 spawn 三种情形都能直接调 `<app>`)。

先前用 `.ps1` 时用户可能撞上「running scripts is disabled」并被要求
`Set-ExecutionPolicy` —— 对一个「解包即用」的分发包,那是不可接受的门槛。
理由全文见 §3 与 [14-windows-portability.md §8](14-windows-portability.md)。

开发态另说:开发 chandler 自身时装个 PowerShell 无妨,但**产品路径不依赖它**。

## 相关文档

- [06-installed-layout.md](06-installed-layout.md) §10 — 启动器设计(D17 稳定 shim)
- [04-install.md](04-install.md) — install 流水线中生成启动器的步骤
- [05-pack.md](05-pack.md) — pack 流水线中生成启动器的步骤 + pack 启动器差异
- [11-cli.md](11-cli.md) — `switch` 命令 / 退出码 / runtime 优先级
- [10-dev-mode.md](10-dev-mode.md) — dev 模式不走 shim,`chandler run` 自管