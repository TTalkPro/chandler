# 06 — Installed Layout(v3 中心设计)

> 本文是 Chandler v3 安装结构的**权威设计**。v3 是 v2 的增量重构(不兼容),聚焦:资源同居、中心注册表、版本切换、registry 简化。其他设计文档(04 install / 05 pack / 08 launchers / 09 runtime-paths / 11 cli)与本文冲突时以本文为准。

## 1. 设计目标

- **I2 真正成立**:install 与 pack 的 payload 字节级一致(v2 有 4 处不一致,v3 修复)。
- **I1 真正成立**:`<name>/<version>/` 自包含,`rm -rf` 干净卸载,无 staging 残留。
- **多版本共存 + 切换**:`myapp/0.1.0/` 与 `myapp/0.2.0/` 同时存在,`chandler switch` 切 `bin/<app>` 指向。
- **资源靠约定,不靠声明**:删 manifest `(resources ...)`,资源与库源码同居。
- **单一真相源**:中心 `.registry/<name>.ss` 管"装了什么、哪个 active"。

## 2. 决策记录(v3 增量)

| # | 决策 | 理由 |
|---|------|------|
| D13 | 资源 method B:`<src>/<libpath>/resources/` | libpath 已在库名里,无需 `<src>/resources/<libpath>/` 双层;资源跟库源码自然同居 |
| D14 | 文件命名统一 `chandler-` 前缀 | `chandler-manifest.ss` + `chandler-manifest.lock`,命名空间一致 |
| D15 | lock 吸收 registry 的 `files+sha256`(Method Y) | `<vroot>/.chandler/` 只剩 manifest + lock + run.sps;doctor/uninstall 走 lock |
| D16 | 中心 `.registry/<name>.ss` 管 versions + active | 多版本共存、切换、list/doctor 的单一真相源 |
| D17 | 启动器 = 稳定 shim,运行时读 `.registry/` | switch 不需重写 launcher;切换瞬时生效 |
| D18 | `run.sps` lock 驱动 library-directories | 多版本 lib 共存时,各 app 用自己 lock 声明的版本,互不干扰 |
| D19 | `chandler switch` 命令 | 多版本管理的用户入口 |
| D31 | dev 期全局兜底每包只挂一个版本(app 取 active,lib 取最高 semver) | 先前挂全部版本,生效的是「最后登记的那个」——偶然结果,且让 `switch` 在 dev 期失效(见 §9.5) |

## 3. 术语

| 术语 | 定义 |
|------|------|
| **libdir** | 库前缀,如 `~/.local/share/chez/`(POSIX)、`%LOCALAPPDATA%\chez`(Windows) |
| **bindir** | 命令行入口目录,如 `~/.local/bin/`(POSIX);Windows 在 libdir 内 `chez\bin\` |
| **version root** | `<libdir>/<name>/<version>/`,自包含的 mini-prefix(I1) |
| **中心 registry** | `<libdir>/.registry/`,管 installed name 的所有 version + active |
| **per-version lock** | `<vroot>/.chandler/chandler-manifest.lock`,含闭包 + 文件清单 + sha256 |
| **active version** | app 在 `.registry/<name>.ss` 的 `(active "<v>")`,决定 `bin/<app>` 指向 |

## 4. 目录布局

### 4.1 libdir(install 落点)

```
<libdir>/                                    例:~/.local/share/chez/
├── .registry/                               中心注册表(NEW)
│   ├── <name>.ss                            每 name 一份,管 versions + active
│   ├── <name2>.ss
│   └── staging/                             事务暂存(从 version root 挪出)
│       └── <name>-<version>/                install 期间的临时树,成功后 promote
│
├── <name>/                                  例:myapp、mylib
│   └── <version>/                           version root(I1:自包含)
│       ├── src/
│       │   ├── <name>.ss                    库入口源码
│       │   └── <name>/                      子库 + 资源同居(D13)
│       │       ├── <sub>.ss
│       │       └── resources/               该库的资源(method B)
│       │           └── <file>
│       ├── <mt>/                            例:ta6le
│       │   ├── <name>.so                    编译对象
│       │   └── <name>/*.so                  子库对象
│       └── .chandler/
│           ├── chandler-manifest.ss         此 lib 的清单快照(D14 命名)
│           ├── chandler-manifest.lock       闭包 + files+sha256(D15)
│           └── run.sps                      app 才有(D18 lock 驱动)
│
└── (POSIX:bin/ 不在 libdir 内,见 §4.2)
```

### 4.2 bindir(命令行入口)

**POSIX**(遵循 XDG,不在 libdir 内):
```
~/.local/bin/
└── <app>                                    稳定 shim,读 .registry/ 找 active(D17)
```

**Windows**(在 libdir 内):
```
%LOCALAPPDATA%\chez\bin\
└── <app>.ps1                                PowerShell shim,同上
```

### 4.3 pack 解开后的结构

```
<pack-root>/                                 = <out>/<name>-<version>-<mt>/
├── bin/
│   ├── <app>[.ps1]                          pack 启动器(指 bundled runtime)
│   └── <mt>/<runtime>[.exe]                 bundled skiff/scheme
├── boot/<mt>/*.boot                         bundled boot 文件
│
├── <name>/<version>/                        payload —— 与 install 字节级一致(I2)
│   ├── src/
│   │   ├── <name>.ss
│   │   └── <name>/resources/                资源随源码(D13)
│   ├── <mt>/                                对象树(过滤 .bake-manifest/.wpo)
│   └── .chandler/
│       ├── chandler-manifest.ss
│       ├── chandler-manifest.lock           pack 不写 .registry/(部署态无需事务)
│       └── run.sps                          pack 模式(追加 verifier + native walk)
│
├── <dep-name>/<dep-version>/...             各 dep 的 payload(同构)
├── chandler/<chandler-ver>/                 chandler 运行时门(独立 namespace)
│
└── pack.manifest                            pack 根级元数据
```

### 4.4 四态字节级一致性(I2 v3)

| 形态 | 根 | payload(`<name>/<version>/{src,<mt>,.chandler}/`) | envelope |
|------|----|------|----------|
| 中央仓库 install | `<libdir>/` | ✓ | `.registry/` + `bin/<app>`(POSIX) |
| 项目 `_vendor/` | `<project>/_vendor/<dep>/` | ✓(live) | — |
| App pack 解开 | `<pack-root>/` | ✓ | `bin/` + `boot/` + `pack.manifest` |
| Lib pack 解开 | `<lib-pack-root>/` | ✓ | — |

`<name>/<version>/{src,<mt>}/.chandler/{chandler-manifest.ss, chandler-manifest.lock}` 在四态下字节级一致(除 `.chandler/run.sps`:install 与 pack 模式内容不同,合理)。

## 5. 中心 `.registry/` 设计(D16)

### 5.1 文件:`<libdir>/.registry/<name>.ss`

```scheme
(registered
  (format 1)
  (name myapp)
  (kind app)                                  ;; app | lib(从 manifest 推导)
  (versions
    ("0.1.0" (installed-at "2026-07-25T19:11:27")
             (source (path "/home/me/proj/myapp"))
             (installer chandler))
    ("0.2.0" (installed-at "2026-07-26T10:00:00")
             (source (git "https://..."))
             (installer chandler)))
  (active "0.1.0"))                           ;; 仅 app 有;lib 不带 (active ...)
```

### 5.2 字段语义

| 字段 | 必需 | 说明 |
|------|------|------|
| `format` | ✓ | 当前 `1` |
| `name` | ✓ | symbol,与 R6RS library name 顶层标识符一致 |
| `kind` | ✓ | `app`(manifest 有 `(app ...)`)或 `lib` |
| `versions` | ✓ | 版本字符串 → 条目 alist,至少 1 项 |
| `versions.<v>.installed-at` | ✓ | ISO-8601 时间戳 |
| `versions.<v>.source` | ✓ | `(path "...")` / `(git "<url>")` / `(pack "<path>")` |
| `versions.<v>.installer` | ✓ | 通常 `chandler` |
| `active` | app 必需 | 当前 `bin/<name>` 指向的 version;lib 无此字段 |

### 5.3 与 per-version lock 的职责分工

| 信息源 | 内容 | 谁读 |
|--------|------|------|
| `.registry/<name>.ss` | 此 name 的所有 version + active + 安装元数据 | launcher shim、list、switch、conflict 检测 |
| `<vroot>/.chandler/chandler-manifest.lock` | 此 version 的解析闭包 + 文件清单 + sha256 | run.sps(挂 libdirs)、doctor(sha256 比对)、verify-pack |

**不重叠**:registry 不记文件清单(I1 保证 version 自包含),lock 不记 active(version 自己不知道是否被链接)。

## 6. `chandler-manifest.lock` 格式(D14 + D15)

```scheme
(lock
  (format 1)
  (manifest-sha256 "<hex>")                   ;; 对应 chandler-manifest.ss 的 sha256
  (chandler ">=0.1.4")                        ;; chandler 运行时门
  (deps
    (mylib (version "1.0.0")
           (source (git "https://..."))
           (rev "abc123def0")
           (scope lib)
           (src . "<libdir>/mylib/1.0.0/src")     ;; 绝对路径(install 模式)
           (obj . "<libdir>/mylib/1.0.0/ta6le")))
  (files                                      ;; NEW (D15),此 version 自己的文件
    ("src/myapp.ss" (sha256 "<hex>"))
    ("ta6le/myapp.so" (sha256 "<hex>"))
    ("src/myapp/resources/hello.txt" (sha256 "<hex>"))))
```

### 6.1 关键约束

- `(files ...)` 有**两种用途,基准不同**,由 lock 所在位置决定:

  | lock 在哪 | 基准 | 覆盖什么 | 谁写 / 谁读 |
  |---|---|---|---|
  | `<vroot>/.chandler/chandler-manifest.lock`(已装包快照) | `<vroot>` | 该 version 自己的文件 | registry / uninstall |
  | `<project>/chandler-manifest.lock`(项目 lock) | **项目根** | 整棵 `_vendor/`(多依赖 + 运行时门) | `chandler deps` 写 / `chandler verify` 读 |

  第二行是 2026-07-27 定的:依赖树校验没有单一 `<vroot>` 可作基准,故取项目根
  (`_vendor/greet/greet.ss`)。生产侧见 `(chandler install)` 的 `record-vendor-files!`,
  消费侧见 [11 §verify](11-cli.md)。
- 项目 lock 的 `(files ...)` **排除 `.git/` 与 `_build/`**:前者是 checkout 自带的仓库
  元数据(其一致性由 `verify` 的 git 态检查管),后者是 `chandler build` 的产物 ——
  写清单时还不存在,记进去只会让 build 之后的 `verify` 立刻失效。
- `(files ...)` 不含 `.chandler/chandler-manifest.lock` 自己(避免自哈希悖论),也不含 staging。
- `(deps <name> (src . ...) (obj . ...))` —— install 模式写绝对路径;pack 模式 lock 在 pack 根级,可写相对路径或省略(由 run.sps 推导)。
- v2 的 `manifest.lock`(无前缀)已废弃;v3 全部用 `chandler-manifest.lock`。

## 7. `chandler-manifest.ss` 格式(D13 取消 resources 字段)

```scheme
(manifest
  (format 1)
  (name myapp)
  (version "0.1.0")
  (library (myapp))                           ;; 可选,缺省从 name 推
  (deps (mylib (git "https://...") (tag "v1.0.0")))
  (dev-deps ...)                              ;; 可选
  (chandler ">=0.1.4")                        ;; 可选,运行时门
  (app (entry (myapp)) (main main)))          ;; app 才有
```

**v3 删除字段**:`(resources ...)`。资源靠约定(D13):每个库的资源住在同名子目录的 `resources/` 下,跟库源码同居。

旧 manifest 的 `(resources ...)` 字段解析时**静默忽略**(降低升级摩擦),`chandler init` 不再生成。

## 8. 资源布局(D13 method B)

### 8.1 约定

资源与库源码同居:

| 库 | 源码路径 | 资源路径 |
|----|---------|---------|
| `(myapp)` | `<src>/myapp.ss` | `<src>/myapp/resources/<file>` |
| `(mylib parser)` | `<src>/mylib/parser.ss` | `<src>/mylib/parser/resources/<file>` |
| `(mylib io json)` | `<src>/mylib/io/json.ss` | `<src>/mylib/io/json/resources/<file>` |

### 8.2 资源定位 API

```scheme
(resource-path '(myapp) "hello.txt")
;; → 扫 (library-directories) 各 src 侧的 <src>/myapp/resources/hello.txt
```

`runtime-paths` 改扫描路径:`<src>/<libpath>/resources/<segs>`(原 `<src>/resources/<libpath>/<segs>`)。

### 8.3 install/pack 不需要专门拷资源

源码树拷贝时,`<src>/<libpath>/resources/` 自动跟着 `.ss` 文件过来 —— 资源在源码树里就是普通子目录。

**收益**:删 `install-project-resources!`、`copy-resources!`、`copy-share!`、`prefix-resource-dir`、manifest `(resources ...)` 字段。

## 9. `run.sps` 设计(D18 lock 驱动)

### 9.1 install 模式

```scheme
(import (chezscheme))
;; 根推导:run.sps 在 <vroot>/.chandler/run.sps → 4× path-parent → <libdir>
(define %runner (car (command-line)))
(define %dot-chandler (path-parent %runner))
(define %version-dir (path-parent %dot-chandler))
(define %name-dir (path-parent %version-dir))
(define %root (path-parent %name-dir))         ;; = libdir
(define %mt (symbol->string (machine-type)))

;; 读 lock(D18)
(define %lock-path (string-append %dot-chandler "/chandler-manifest.lock"))
(define %lock (read-lock-file %lock-path))

;; 挂库对:app 自己 + lock 声明的每个 dep 的精确 version
(library-directories
  (cons (cons (string-append %version-dir "/src")
              (string-append %version-dir "/" %mt))
        (map (lambda (d)
               (let ([n (symbol->string (locked-dep-name d))]
                     [v (locked-dep-pin-val d)])
                 (cons (string-append %root "/" n "/" v "/src")
                       (string-append %root "/" n "/" v "/" %mt))))
             (lock-deps %lock))))

;; 动态 import + 调 main
(let ([args (cdr (command-line))]
      [env (environment '(myapp))])
  (eval (list 'main args) env))
```

### 9.2 pack 模式

install 模式之上追加:
- `pack.manifest` 读取 + format/target 校验
- runtime 检测(skiff vs chez)
- native walk(递归 `load-shared-object` 所有 `<mt>/<libpath>/native/*.so`)

### 9.3 dev 模式

无 lock(项目根跑 `chandler run`),`resolved-libdirs` 实时算 per-dep 对,通过 `--libdirs` 传给子进程。dev 模式不走 run.sps。

### 9.4 多版本 lib 共存(D18 的核心)

`.registry/` 允许 `mylib/1.0.0/` 与 `mylib/2.0.0/` 同时存在。app A 的 lock 指向 1.0.0,app B 指向 2.0.0 —— 各自 run.sps 只挂自己 lock 声明的版本,Chez 不会看到冲突版本。

### 9.5 dev 期全局兜底的选版规则(D31,2026-07-27)

`run.sps` 靠 lock 精确挂载,但 **dev 期**(`chandler run` / `repl` / `build` / `test`)的
全局兜底段走 `global-libdir`,它没有 lock 可依。规则是**每个包只挂一个版本**:

| registry kind | 选哪个版本 |
| --- | --- |
| `app` | `(active …)` —— 这正是 `chandler switch` 控制的东西 |
| `lib` | 盘上存在的最高 semver(lib 没有 active:`registered-set-active` 对 lib 直接报错) |

两种情况都只在**版本目录真在盘上**的候选里选;app 的 active 若指向已被删掉的版本,
退到盘上存在的最高 semver。一个可用版本都没有 → 该包整个不出现在搜索路径里。
返回序按包名升序。

> **先前的行为是 bug**:把每个包的**每个**版本都挂进 `library-directories`。Chez 解析
> 一个库名时只命中其中一条,命中哪条取决于累积顺序 —— 实际是「最后登记的那个版本」。
> 于是 `chandler switch` 改了 active,dev 期却照旧解析到别的版本;`10.0.0` 也会输给
> 后装的 `2.0.0`。多挂的条目还会拖累资源定位(§8.2)与 native 兜底扫描(09 §5.3),
> 二者都逐条走这张表。

## 10. 启动器(D17 稳定 shim)

### 10.1 POSIX

```sh
#!/bin/sh
# <bindir>/<app> — generated once by chandler install, never rewritten
NAME="<app>"
LIBDIR="${CHANDLER_HOME:-$HOME/.local/share/chez}"
REGFILE="$LIBDIR/.registry/$NAME.ss"

[ -f "$REGFILE" ] || { echo "$NAME: not registered (run chandler install)" >&2; exit 70; }

# 解析 (active "<version>") —— 单行 scheme datum
ACTIVE=$(awk '/^[[:space:]]*\(active/ { gsub(/[(")]/, "", $2); print $2; exit }' "$REGFILE")
[ -n "$ACTIVE" ] || { echo "$NAME: no active version (run chandler switch)" >&2; exit 70; }

RUNNER="$LIBDIR/$NAME/$ACTIVE/.chandler/run.sps"
[ -f "$RUNNER" ] || { echo "$NAME: active version $ACTIVE missing runner (reinstall)" >&2; exit 70; }

# runtime 发现(skiff 优先)
case "${CHANDLER_RUNTIME:-}" in
  skiff) _rt="${CHANDLER_SKIFF:-skiff}" ;;
  chez)  _rt="${CHANDLER_SCHEME:-scheme}" ;;
  "")    for _c in skiff scheme chez; do
           command -v "$_c" >/dev/null 2>&1 && { _rt="$_c"; break; }
         done ;;
  *) echo "$NAME: invalid CHANDLER_RUNTIME (want: skiff|chez)" >&2; exit 64 ;;
esac
[ -n "$_rt" ] || { echo "$NAME: no Scheme runtime found" >&2; exit 127; }

exec "$_rt" -q --program "$RUNNER" "$@"
```

### 10.2 Windows(PowerShell)

```powershell
$Name = '<app>'
$LibDir = if ($env:CHANDLER_HOME) { $env:CHANDLER_HOME } else { Join-Path $env:LOCALAPPDATA 'chez' }
$RegFile = Join-Path $LibDir ".registry" "$Name.ss"
if (-not (Test-Path $RegFile)) { [Console]::Error.WriteLine("$Name: not registered"); exit 70 }
$content = Get-Content $RegFile -Raw
if ($content -match '\(\s*active\s+"([^"]+)"\)') { $Active = $Matches[1] }
else { [Console]::Error.WriteLine("$Name: no active version"); exit 70 }
$Runner = Join-Path $LibDir $Name $Active ".chandler" "run.sps"
# ... runtime discovery + exec
```

### 10.3 shim 的不变量

- install 时生成一次,后续 install/switch/doctor 不重写它
- switch 只改 `.registry/<name>.ss` 的 `(active ...)`,所有新进程立即用新版本
- shim 跨 install/uninstall 持久(同 name 重装不必删 shim)

## 11. CLI 命令

### 11.1 新增/重写

```
chandler install [--user|--system|--prefix=DIR] [--force] [--adopt]
    装 project + deps 到 libdir,更新 .registry/,首次 install 写 bin/<app> shim。
    同 name 已装其他版本 → 新增 version 条目;同 version 重装 → 替换。
    apps:首次 install 设 active = 此 version;后续 install 不自动改 active。

chandler uninstall --name=<n> [--version=<v>] [--keep-modified]
    不带 --version:删 name 的所有 version + bin shim。
    带 --version:只删该 version;若它是 active,active 清空(下次启动报错)。

chandler list [<name>] [--all]
    默认:列所有 name 的 active version(app 标 [active])。
    带 <name>:列该 name 的所有 version + active。
    --all:列所有 version(不只 active)。

chandler doctor
    检查:
    ① .registry/<name>.ss 里每个 version 的 <vroot> 存在
    ② <vroot>/.chandler/chandler-manifest.lock 存在,且其 (files ...) 的每个文件 sha256 一致
    ③ 每个 app 的 active version 真实存在
    ④ .registry/staging/ 无残留

chandler switch <name> <version>
    切 active version。前提:
    ① <name> 已注册
    ② <version> 已装
    行为:改 .registry/<name>.ss 的 (active ...)。
    bin shim 不需重写(下次启动自动读新 active)。

chandler switch <name> --latest
    切到该 name 的最高 version(semver 排序)。

chandler switch <name> --previous
    切到上一个 active 之前的 version(若历史可推导)。

chandler switch --list
    列所有 app + 当前 active,如:
      myapp  0.1.0
      cli2   2.3.1
```

### 11.2 不变的命令

`init`、`add`、`remove`、`deps`、`build`、`make`、`run`、`env`、`repl`、`pack`、`verify-pack`、`tree`、`--version`。

## 12. 与 v2 的差异(迁移影响)

| 维度 | v2 | v3 | 迁移 |
|------|----|----|------|
| lock 文件名 | `manifest.lock` | `chandler-manifest.lock` | 用户重跑 `chandler deps` |
| manifest 字段 | `(resources ...)` | 删 | 用户删该字段(或保留,解析器静默忽略) |
| 资源路径 | `<src>/resources/<libpath>/` | `<src>/<libpath>/resources/` | 用户重组资源目录 |
| `<vroot>/.chandler/registry/` | per-version registry | **删** | 重装 |
| `<vroot>/.chandler/chandler-manifest.lock` | — | 新增 files 字段 | 重装 |
| `<libdir>/.registry/` | — | **新** | 重装 |
| `<vroot>/.chandler/staging/` | 在 version root | 挪到 `<libdir>/.registry/staging/` | 自动 |
| 启动器 | 生成式,embed version | 稳定 shim,读 .registry | 重装 |
| run.sps | scan-libdirs 全扫 | lock 驱动精确挂 | 重装 |
| `.bake-manifest`/`*.wpo` | install 过滤、pack 不过滤 | 都过滤 | — |
| chandler-manifest.ss 在 src/ | pack 多拷 | 不拷(只在 .chandler/) | — |

**v3 是 breaking change,不提供自动迁移**。用户重装即可。

## 13. 实施阶段(详见 TASK.md)

| Phase | 内容 | 关键模块 |
|-------|------|---------|
| 1 | 数据层(纯函数) | registered(NEW)、lock、manifest、layout |
| 2 | registry 门面拆分 | registry/{data,io,staging}、registry facade |
| 3 | 管线简化 | install、pack、runtime-paths |
| 4 | runner + launcher | run-sps-content、launcher shim |
| 5 | CLI 命令重写 | install/uninstall/list/doctor/switch |
| 6 | 整合 | bootstrap.ss、designs 文档、测试套件 |

## 相关文档

- [04-install.md](04-install.md) — install 流水线(待重写,以本文为准)
- [05-pack.md](05-pack.md) — pack 流水线(待重写,以本文为准)
- [08-launchers.md](08-launchers.md) — 启动器(待重写)
- [09-runtime-paths.md](09-runtime-paths.md) — 资源定位(路径模式更新)
- [11-cli.md](11-cli.md) — CLI 命令面(switch 新增)
- [00-design-principles.md](00-design-principles.md) — 宪法(待重写,D4-D12 + D13-D19)
