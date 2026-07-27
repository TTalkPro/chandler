# Chandler

> git-first 的 Chez Scheme 包管理器 + 构建器,**Skiff** 运行时生态里的包供应商(船具商)。读 `chandler-manifest.ss`,把 git 仓库里的 R6RS 库装进项目,一行 `chandler run` 挂载整个依赖环境并运行。标准 Chez 与 Skiff **双运行时**皆可用。

**中文 | [English](README.en.md)** — 设计文档见 [designs/](designs/),变更记录见 [CHANGELOG.md](CHANGELOG.md)。

## 定位

> **v3 新增**:多版本共存 + `chandler switch` 版本切换;资源 method B(与库源码同居);中心 `.registry/`;lock 驱动 run.sps。详见 [designs/06-installed-layout.md](designs/06-installed-layout.md)。

- **Skiff**(轻舟)= 运行时(Chez + libuv);**Chandler**(船具商)= 包管理器 + 构建器,管**依赖获取、编译、激活、打包**。
- git-first:依赖来源(URL + tag/rev/branch pin)写在 `chandler-manifest.ss`,无需中心 registry。
- 依赖 = 整仓 checkout 到 `_vendor/<name>/`,各依赖**就地编译**(产物留在它自己的 `_build/<mt>/`);`chandler-manifest.lock` 锁确切 commit,可复现。
- 消费方用 Chez 库目录**对** `<src>::<obj>`(`::` = 源::对象)同时解析源码与对象;native 收进所属库 `<obj>/<lib>/native/`。

## 安装

### 前置环境

| 需要 | 说明 |
|------|------|
| **Scheme 运行时** | **skiff**(优先)或 **Chez Scheme ≥ 10.0**。二者装一个即可;都在则默认用 skiff。**Petite 不够**——它没有编译器,而 `chandler build`/`chandler make` 要编译库树。 |
| **git** | 依赖获取靠它(`git` 需在 PATH 上)。 |
| ~~PowerShell~~ | **不需要**。启动器是 `.cmd`(D34),只依赖每台 Windows 必有的 `cmd.exe` —— 不受 ExecutionPolicy 管,`.CMD` 也在默认 `PATHEXT` 里。 |

若尚无运行时,先装 skiff 或 Chez;`mise` 用户可 `mise use chezscheme`。

### POSIX(Linux / macOS)

```sh
git clone <this-repo> chandler && cd chandler
scheme --script bootstrap.ss               # chandler 铺库 → ~/.local/share/chez/{src,<mt>};启动器 → ~/.local/bin/chandler
skiff --script bootstrap.ss --system        # 装到 /usr/local(需 root)

export PATH="$HOME/.local/bin:$PATH"        # 若尚未在 PATH 上(脚本会提示这行)
chandler --version                          # → chandler 0.1.6 (skiff 0.1.2) (chez 10.4.1)
```

### Windows

不需要 PowerShell,`cmd.exe` 即可(下面是 cmd 语法):

```bat
git clone <this-repo> chandler && cd chandler
scheme --script bootstrap.ss                 :: 启动器 → %LOCALAPPDATA%\chez\bin\chandler.cmd
scheme --script bootstrap.ss --system        :: 系统级(需管理员)

set "PATH=%LOCALAPPDATA%\chez\bin;%PATH%"
chandler --version
```

> **`.cmd` 用裸名调用**:`.CMD` 在默认 `PATHEXT` 里,故 `chandler` 直接可用 ——
> cmd、PowerShell、被别的程序 spawn 三种情形都一样,也不会撞上 PowerShell 的执行策略。
>
> **已知限制**(cmd 固有,npm / yarn 的 Windows shim 同款):参数里含 `%` 会被变量展开、
> 未加引号的 `& | < > ^` 会破;`Ctrl+C` 会弹 `Terminate batch job (Y/N)?`。
>
> **从 0.1.6 及更早升级**:那时的启动器是 `.ps1`,重装一次即换成 `.cmd`;
> `chandler uninstall` 会把残留的 `.ps1` 一并带走。

> `bootstrap.ss` 是自包含的**三段式自举安装器**(纯 `(chezscheme)`,零 chandler import,chandler 库坏了也能装):
> ① 源码直载 CLI 跑 `deps` + `build` + `install --prefix=./_bootstrap`,产出一个与正常 `--user` 安装**完全同构**的 `_bootstrap/`(库树 + `.registry/` + 稳定 shim);
> ② 用 `_bootstrap` 里的 chandler 重新 `build` 本仓库(自托管验证);
> ③ 再用它 `install` 到最终前缀并冒烟启动器。安装逻辑全部复用 chandler 自己的 `cmd-install`,bootstrap 只做编排。
> 用法:`scheme --script bootstrap.ss [--user|--system|--prefix=DIR] [--force] [--uninstall] [--bootstrap-only]`。`--user`(默认)装 `~/.local`;`--system` 装 `/usr/local`;`--prefix=DIR` 装 `DIR` + `DIR/bin`;`--bootstrap-only` 只跑①(调试自举用)。用户通过调用方式选择运行时(`scheme` vs `skiff`)。

### 装完之后

安装出的启动器是**稳定 shim**(D17):运行时读 `<libdir>/.registry/chandler.active` 找 active 版本,交接给 `<vroot>/.chandler/run.sps`(lock 驱动挂库路径,D18),再做**运行时发现**(优先 `skiff`,回退 `scheme`/`chez`)。POSIX 是 `chandler`(sh),Windows 是 `chandler.cmd`(批处理)。多版本共存时用 `chandler switch` 切换,shim 本身不变。

想固定用某个运行时,见下面[「指定运行时」](#指定运行时skiff--chez)——安装脚本与启动器认同一套变量。

**卸载**:`scheme --script bootstrap.ss --uninstall`(registry 驱动:删 `<vroot>` + 更新 `.registry/` + 删启动器,同时清掉 `_bootstrap/`;需仓库源码在,因为要加载 CLI 执行卸载)。

**开发期不必安装**:仓库里直接 `./bin/chandler <命令>`(同样 skiff 优先)。

### 构建与任务(`chandler make`)

bake 的编译引擎已整体吸收进 chandler,原来的独立 `bake` 二进制作废。chandler 自己带一份 `chandler-tasks.ss`(原名 `recipe.ss`),由 `chandler make` 子命令消费:

```sh
chandler make            # = build,编译 (chandler) 库树为 .so → _build/<mt>/
chandler make clean      # 删 .so 等构建产物
chandler make -T         # 列任务
```

> **多数项目不需要 `chandler-tasks.ss`**:`chandler build` 直接从 `chandler-manifest.ss` 的 `(app (entry …))` 推导要编什么。只有需要自定义任务(如自定义打包、清理等)时才写。它是**程序**(加载即求值),与**数据**文件 `chandler-manifest.ss` 配对。
>
> **安装**由自含的 `bootstrap.ss` 负责(装库树 + 生成 CLI 启动器),不经 `chandler make`。
>
> **跑测试用 `chandler test`**(见下),不再通过 `chandler-tasks.ss` 自带的 `'test` 任务。

### 测试(`chandler test`)

```sh
chandler test            # 跑全测试套件(tests/run-tests.sps)
chandler test --runtime=chez   # 强制用 Chez(默认跟随当前运行时)
```

`chandler test` 是跑测试的**规范入口**:挂项目库路径(`resolved-libdirs` 的 per-dep `(src . obj)` 对 + 项目库根 + 全局兜底)+ native 预加载兜底 + 选择 runtime + 加载 `.env`/`.env.tests`,然后以测试进程的退出码作为自己的退出码。额外参数透传给 `tests/run-tests.sps`。它取代了原先 `chandler-tasks.ss` 里的 `'test` 任务——后者已从默认模板移除,以免和 CLI 子命令重名造成混淆。

`.env.tests`(项目根,**可选**)覆盖 `.env` 同名键,**仅在 `chandler test` 期间生效**(`run`/`repl`/`exec`/`env` 不读它),用来给测试套件切数据库 / API stub / 关掉副作用,而不污染开发环境。`.env.tests` 不存在则仅读 `.env`(与 `run`/`repl` 一致)。

## 快速上手

```sh
chandler init --name=myapp                 # 生成骨架 chandler-manifest.ss + chandler-tasks.ss(_vendor/ 入 .gitignore)
chandler add http https://github.com/x/http --tag v1.2.0
chandler deps                              # 解析 → 写 lock → git 依赖整仓 checkout 到 _vendor/
chandler build                             # 进程内编译依赖闭包 → 各 _vendor/<dep>/_build/<mt>/
chandler deps --list                      # 看已锁依赖(全局已装包用 `chandler list`)
chandler verify                            # CI:校验 _vendor/ 与 lock 一致
chandler repl                              # 交互 shell(自动挂库路径)
```

## 依赖模型(Bundler 式)

```
myapp/
  chandler-manifest.ss  chandler-manifest.lock
  _vendor/<name>/                    ← git 依赖整仓 checkout(源码 live)
    <srcdir>/_build/<mt>/            ← chandler build 就地编译产物(留在原地)
  _vendor/chandler/                  ← 运行时门(deps 从 CHANDLER_HOME copy)
    chandler/<sub>.ss                ← runtime subset 源码
    _build/<mt>/chandler/<sub>.so    ← 对象
  resources/<libpath>/               ← 项目自己的资源(与库源码同居:method B,`<src>/<libpath>/resources/`)
```

- **`chandler deps`**:git 依赖整仓 checkout 到 `_vendor/<name>/`(源码 live);chandler 运行时门从 CHANDLER_HOME copy 进 `_vendor/chandler/`。
- **`chandler build`**:按 lock 拓扑序逐依赖**就地编译**(cwd = 该依赖 srcdir,产物留 `_vendor/<dep>/<srcdir>/_build/<mt>/`),已编好的上游作为**预构建根** `(prebuilt src obj)` 挂入。进程内编译,不再 spawn 子进程。
- **path 依赖** `(path "../x")`:不进 _vendor,直挂其源目录(live,改一行立即生效)。
- **库搜索**:`resolved-libdirs` 为每个依赖挂一条 `(src . obj)` 对 —— 源在 `_vendor/<dep>/<srcdir>`,对象在它自己的 `_build/<mt>`。不再有汇总的 `lib/`。

### native 加载:自加载优先,统一加载兜底

`chandler build` 为每个带 native 的库生成 `(<lib> native-loader)`(产物 `<obj>/<lib>/native-loader.so`),该库的 FFI 被引用时 loader **自己**定位并加载 `.so`——其候选之一正是 `(library-directories)` 的**对象侧**,而 resolved-libdirs 挂的各依赖 obj 侧恰是 native 落点,故**挂好对即自动生效**,且是**惰性**的(不碰 FFI 就不 `dlopen`)。

因此 `activate` / `run` / `repl` 的预加载已降级为**兜底**:只为「无生成 loader」的第三方库扫描加载,带 `native-loader.so` 的库一律跳过。

### 启动:统一走 `chandler run`

```sh
chandler run --script main.ss [args...]
```

它交接一样东西:**库搜索路径**(`resolved-libdirs` 的 per-dep `(src . obj)` 对 + path 源目录 + 项目库根 + 全局兜底)。之后脚本里 `(import (dep))` 即通。

**资源定位不依赖环境变量**:`(chandler runtime-paths)` 的 `resource-path` / `find-resource-path` 扫 `(library-directories)` 的 src/obj 两侧(`<side>/<libpath>/resources/<file>`,method B:资源与库源码同居),进程对着哪些前缀跑,资源就在那里——不再需要 `APP_ROOT`。

`.env`(项目根)由 `run`/`repl`/`env` 消费(`.env` 覆盖进程环境);刻意**不碰** `build`/`deps`/`install`,保住可复现。

> 测试时(`chandler test`),若仓库根存在 `.env.tests`,会先读 `.env` 再用 `.env.tests` 覆盖同名键——用来给测试套件切数据库 / 关闭副作用,而不污染开发环境。`.env.tests` **仅**被 `chandler test` 消费,`run`/`repl`/`exec`/`env` 不读它。

> 早期版本生成过 `chandler-setup.ss`(Bundler 的 `bundler/setup` 式)与 `APP_ROOT` 环境变量,均已取消:启动只留 `chandler run` 一条路,资源与库住在同一个前缀里。
> 需要在别的进程里挂同一套路径,用 `eval "$(chandler env)"`;已持有 `(chandler)` 的脚本可直接 `(activate)`。

### 库搜索规则(run / env / repl / activate 一致)

- **项目**(有 lock + 依赖):各依赖的 `(src . obj)` per-dep 对 + path 源目录 + 项目自身库根 + 全局兜底一对(项目最高优先)。
- **非项目**:直接用全局前缀一对 `~/.local/share/chez/src::~/.local/share/chez/<mt>`。

## 命令一览

| 命令 | 作用 |
|------|------|
| `init [--lib\|--app] [--name=N]` | 生成骨架 `chandler-manifest.ss` + `chandler-tasks.ss`(默认 lib;`--app` 写 `(app …)` 使其可 pack) |
| `add <name> <url> [--tag/--rev/--branch/--path]` | 添加依赖 |
| `remove <name>` | 移除依赖 |
| `deps [--production] [--offline] [--force] [--update]` | 解析 → 写 lock → git 依赖 checkout 到 `_vendor/` + chandler 运行时门就位 + 记录 `_vendor/` 文件清单与 sha256 到 lock 的 `(files …)`(供 `verify`);`--list` 显已锁依赖,`--tree` 树状显已锁依赖 |
| `build [--allow-build[=a,b]]` | 进程内编译依赖闭包 + native → 各 `_vendor/<dep>/_build/<mt>/` |
| `verify` | 校验 `_vendor/` 与 `chandler-manifest.lock` 一致(CI,只读):**git 态**(每个 git 依赖的 HEAD == lock 的 rev、工作区无脏改动)+ **内容哈希**(lock 的 `(files …)`,仅在其非空时比对;`.git/`、`_build/` 不计 EXTRA)。任一不符 → exit 65 |
| `list` | 列全局已装包(多版本,active 版本标 `[active]`) |
| `tree` | `deps --tree` 别名:树状显已锁依赖 |
| `run <script.ss> [args…]` | 挂库搜索路径后跑脚本 |
| `exec -- <cmd…>` | 设 `CHEZSCHEMELIBDIRS` + 加载 `.env` 后透传跑命令;退出码 = 子进程退出码 |
| `env` | 打印 `export CHEZSCHEMELIBDIRS=…` + `.env` 各键导出,供 `eval "$(chandler env)"` |
| `repl [--runtime skiff\|chez]` | 交互 shell,自动挂库路径(项目优先 + 全局兜底) |
| `make [task]` | 跑 `chandler-tasks.ss` 的任务(默认 `build`);无任务文件时从 manifest 推导 |
| `test [args…]` | 跑 `tests/run-tests.sps`(挂项目库路径 + 加载 `.env`/`.env.tests` + 选择 runtime);退出码 = 测试进程退出码 |
| `install [--user\|--system\|--prefix=DIR]` | 装项目库 + 依赖到全局前缀(中心 `.registry/` 登记)。**app 自动建命令行入口** `~/.local/bin/<app>`(POSIX,稳定 shim)/ `%LOCALAPPDATA%\chez\bin\<app>.cmd`(Windows)。首次 install 自动设 active;同 name 多 version 共存 |
| `uninstall --name=<n> [--version=<v>]` | 干净卸载(`rm -rf <vroot>` + 更新 `.registry/`);删 active 自动清空 |
| `switch <name> <version>` | **切换 app 的 active version**(D19);`--latest` 按 semver 数值序选最高;`--list` 列所有 active |
| `doctor` | 体检全局前缀:`missing-vroot` / `missing-active` / `missing-runner` / `malformed-registry` / `orphan-vroot` / `kind-mismatch` / `name-filename-mismatch` / `duplicate-version` / `stale-staging` |
| `pack [--runtime r] [--out dir] [--lib]` | 组装自包含分发包到 `dist/<name>-<ver>-<mt>/`(载荷与 install 同管线 → `share/chez/`;envelope 在 `bin/` + `lib/chez/`,自带运行时;`--lib` 只打载荷) |
| `verify-pack [--target] <dir>` | 校验分发包:强制 schema(`(format …)` 不得超 supported + `(files …)` 须存在且每项含 `sha256`/`size`)+ hash/size 完整比对 + 未声明文件 `EXTRA` 致命;`--target` 再核 machine-type / chez-version / skiff-version |

全局旗标:`-C <dir>` `--offline` `--production` `--force` `--keep-extra` `--verbose`。

## 指定运行时(skiff / chez)

「用哪一种运行时」与「用哪个可执行文件」分开:

| 变量 | 作用 |
|------|------|
| `CHANDLER_HOME=<dir>` | chandler 装在哪(前缀,src/mt);deps 从这里 copy chandler runtime、全局兜底挂它。启动器自动设,一般不用管 |
| `CHANDLER_RUNTIME=skiff\|chez` | 选**哪一种**运行时,默认 skiff;非法值报错(退出码 64),不静默忽略 |
| `CHANDLER_SKIFF=<exe>` | skiff 的可执行文件(名或路径) |
| `CHANDLER_SCHEME=<exe>` | Chez 的可执行文件(名或路径) |

**优先级**(`run` / `exec` / `repl`、**启动器**、**安装脚本**共用一套):

```
--runtime 旗标  >  CHANDLER_RUNTIME  >  manifest(明确 chez-only→chez / skiff-only→skiff)  >  默认:跟随 chandler 当前所在(启动器 skiff 优先,故默认 skiff)
```

```sh
CHANDLER_RUNTIME=skiff chandler run app.ss        # 强制 skiff
CHANDLER_RUNTIME=chez  chandler repl              # 强制 Chez
chandler run --runtime=chez app.ss                # 旗标最高优先
CHANDLER_RUNTIME=chez CHANDLER_SCHEME=/opt/chez/bin/scheme chandler run app.ss
```

**安装期也认**(用哪个运行时跑安装本身):

```sh
CHANDLER_RUNTIME=chez scheme --script bootstrap.ss    # 用 Chez 跑安装
skiff --script bootstrap.ss                            # 用 skiff 跑安装(默认)
```

**确认当前用的是哪个** —— `--version` 报出所在运行时(skiff 自 0.1.1 起以内置 `(skiff-version)` 自证版本):

```sh
$ chandler --version
chandler 0.1.6 (skiff 0.1.1) (chez 10.4.1)   # 跑在 skiff 上
$ CHANDLER_RUNTIME=chez chandler --version
chandler 0.1.6 (chez 10.4.1)                 # 跑在标准 Chez 上
```

> **显式覆盖照单执行**:指定了 `CHANDLER_SKIFF`/`CHANDLER_SCHEME` 就只用它——找不到即失败(退出码 127),**不**静默回退到别的运行时(静默回退等于否定了覆盖)。同理,显式指定的运行时不再跑能力探测。
>
> **自动发现时**则相反:名为 `skiff` 的候选须通过能力探测——真跑一段 R6RS 程序、且它以 `(skiff-version)` **自证是 skiff**,才会被选中。故一个能跑程序但并非 skiff 的同名可执行文件会被正确跳过,回退到 Chez。

## 安全模型(designs/08)

- **清单只 `read` 不求值**:`chandler-manifest.ss`/`chandler-manifest.lock`/`.registry/` 一律纯数据,永不 `eval`/`load`。
- **git clone/checkout 零执行**:所有 git 调用带 `-c core.hooksPath=/dev/null`。
- **native 构建 = RCE,须显式授权**:依赖的 native 构建(别人的代码)须 `--allow-build`,且授权**绑构建描述哈希**写入 `.chandler-approvals`——脚本掉包(描述变更)则授权失效重提示。
- **rev 全长锁定 = 内容寻址**:物化只认 lock 里的确切 commit,篡改/重放由 git 对象哈希兜底。

## 开发

```sh
chandler test                                      # 规范入口:挂库路径 + native 兜底 + runtime 选择 + .env/.env.tests
scheme --libdirs . --program tests/run-tests.sps    # 同上,纯 Chez,无外部依赖(手写时:注意自己挂库路径,无 native 兜底)
petite  --libdirs . --program tests/run-tests.sps   # 同上(Petite 子集校验)
skiff   --libdirs . --program tests/run-tests.sps   # 同上(Skiff 运行时)
```

`tests/chandler/launcher-parity.ss` 把 sh 与 `.cmd` 两族启动器**都渲染出来对拍**:读的 sidecar 路径、runner 路径拼法、运行时发现顺序、五个退出码必须一致,刻意保留的差异(cmd 无 `exec`、`%*` vs `"$@"`)则显式钉住。**跑 `run-tests.sps` 就跑到,不需要 Windows,也不需要 pwsh。**

库布局遵循[库布局规范](designs/13-library-source-layout.md):umbrella `chandler.ss` + 同名子库树 `chandler/`,搜索根 = 仓库根。核心只 `import (chezscheme)`,限 Petite 可跑子集(双运行时可移植)。

### 语言约定

- **用户可见输出一律英文**:CLI 帮助、运行期提示/警告/错误(`printf`/`fprintf`/`error` 的消息),以及**生成物**的头注释(`.chandler-build.ss`、pack 的 `run.sps` 与启动器)——工具面向的用户不限中文。风格取 Unix 诊断惯例:小写、简短、不加句号,如 ``chandler-manifest.ss not found; run `chandler init` first``。
- **源码注释(`;;` / `;;;`)与本仓文档保持中文**,便于设计推理的表达密度。
- 单复数用 `(plural n "dependency" "dependencies")`(`(chandler util)`),避免 `1 dependencies`。
