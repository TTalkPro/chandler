# Chandler

> git-first 的 Chez Scheme 包管理器 + 构建器,**Skiff** 运行时生态里的包供应商(船具商)。读 `manifest.ss`,把 git 仓库里的 R6RS 库装进项目,一行 `chandler run` 挂载整个依赖环境并运行。标准 Chez 与 Skiff **双运行时**皆可用。

**中文 | [English](README.en.md)** — 设计文档见 [designs/](designs/);实现任务与进度见 [TASK.md](TASK.md)。

## 定位

- **Skiff**(轻舟)= 运行时(Chez + libuv);**Chandler**(船具商)= 包管理器 + 构建器,管**依赖获取、编译、激活、打包**。
- git-first:依赖来源(URL + tag/rev/branch pin)写在 `manifest.ss`,无需中心 registry。
- 依赖 = 整仓 checkout 到 `_vendor/<name>/`,各依赖**就地编译**(产物留在它自己的 `_build/<mt>/`);`manifest.lock` 锁确切 commit,可复现。
- 消费方用 Chez 库目录**对** `<src>::<obj>`(`::` = 源::对象)同时解析源码与对象;native 收进所属库 `<obj>/<lib>/native/`。

## 安装

### 前置环境

| 需要 | 说明 |
|------|------|
| **Scheme 运行时** | **skiff**(优先)或 **Chez Scheme ≥ 10.0**。二者装一个即可;都在则默认用 skiff。**Petite 不够**——它没有编译器,而 `chandler build`/`chandler make` 要编译库树。 |
| **git** | 依赖获取靠它(`git` 需在 PATH 上)。 |
| PowerShell | **仅 Windows 需要**(启动器与安装脚本是 `.ps1`)。Windows 10/11 自带;或 `mise use powershell`。 |

若尚无运行时,先装 skiff 或 Chez;`mise` 用户可 `mise use chezscheme`。

### POSIX(Linux / macOS)

```sh
git clone <this-repo> chandler && cd chandler
scheme --script bootstrap.ss               # chandler 铺库 → ~/.local/share/chez/{src,<mt>};启动器 → ~/.local/bin/chandler
skiff --script bootstrap.ss --system        # 装到 /usr/local(需 root)

export PATH="$HOME/.local/bin:$PATH"        # 若尚未在 PATH 上(脚本会提示这行)
chandler --version                          # → chandler 0.1.4 (skiff 0.1.2) (chez 10.4.1)
```

### Windows(PowerShell)

```powershell
git clone <this-repo> chandler; cd chandler
scheme --script bootstrap.ss                 # 启动器 → %LOCALAPPDATA%\chez\bin\chandler.ps1
scheme --script bootstrap.ss --system        # 系统级(需管理员)

$env:PATH = "$HOME\.local\bin;$env:PATH"
chandler --version
```

> `bootstrap.ss` 是自包含安装器(纯 `(chezscheme)`,零 chandler 依赖):铺源码 + 编译产物 + 写运行时发现启动器。
> 用法:`scheme --script bootstrap.ss [--user|--system|--dev] [--force] [--uninstall]`。`--user`(默认)装 `~/.local`;`--system` 装 `/usr/local`;`--dev` 装进仓库 `./dist/`(开发用)。用户通过调用方式选择运行时(`scheme` vs `skiff`)。
>
> 若 PowerShell 报「running scripts is disabled」,是执行策略为 Restricted,二选一:
> `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`(一次性),或
> `pwsh -ExecutionPolicy Bypass -File ...`(仅本次)。

### 装完之后

安装出的启动器做**运行时发现**:优先 `skiff`,回退 `scheme`/`chez`(designs/06 双运行时),并挂 `<prefix>/src::<prefix>/<mt>` 一对跑 `<prefix>/src/chandler/cli/main.sps`。POSIX 是 `chandler`(sh),Windows 是 `chandler.ps1`(PowerShell)。

想固定用某个运行时,见下面[「指定运行时」](#指定运行时skiff--chez)——安装脚本与启动器认同一套变量。

**卸载**:`scheme --script bootstrap.ss --uninstall`(按命名空间删库 + 删启动器,**不依赖文件清单**,装完把仓库删了也能卸干净)。

**开发期不必安装**:仓库里直接 `./bin/chandler <命令>`(同样 skiff 优先)。

### 构建与任务(`chandler make`)

bake 的编译引擎已整体吸收进 chandler,原来的独立 `bake` 二进制作废。chandler 自己带一份 `chandler-tasks.ss`(原名 `recipe.ss`),由 `chandler make` 子命令消费:

```sh
chandler make            # = build,编译 (chandler) 库树为 .so → _build/<mt>/
chandler make test       # 跑全测试套件
chandler make test-ps    # PowerShell 启动器验收(需 pwsh,缺则跳过)
chandler make -T         # 列任务
```

> **多数项目不需要 `chandler-tasks.ss`**:`chandler build` 直接从 `manifest.ss` 的 `(app (entry …))` 推导要编什么。只有需要自定义任务(如上面的 `test`/`test-ps`)时才写。它是**程序**(加载即求值),与**数据**文件 `manifest.ss` 配对。
>
> **安装**由自含的 `bootstrap.ss` 负责(装库树 + 生成 CLI 启动器),不经 `chandler make`。

## 快速上手

```sh
chandler init --name=myapp                 # 生成骨架 manifest.ss + chandler-tasks.ss(_vendor/ 入 .gitignore)
chandler add http https://github.com/x/http --tag v1.2.0
chandler deps                              # 解析 → 写 lock → git 依赖整仓 checkout 到 _vendor/
chandler build                             # 进程内编译依赖闭包 → 各 _vendor/<dep>/_build/<mt>/
chandler list                              # 看已锁依赖
chandler verify                            # CI:校验 _vendor/ 与 lock 一致
chandler repl                              # 交互 shell(自动挂库路径)
```

## 依赖模型(Bundler 式)

```
myapp/
  manifest.ss  manifest.lock
  _vendor/<name>/                    ← git 依赖整仓 checkout(源码 live)
    <srcdir>/_build/<mt>/            ← chandler build 就地编译产物(留在原地)
  _vendor/chandler/                  ← 运行时门(deps 从 CHANDLER_HOME copy)
    chandler/<sub>.ss                ← runtime subset 源码
    _build/<mt>/chandler/<sub>.so    ← 对象
  resources/<libpath>/               ← 项目自己的资源(verbatim)
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

**资源定位不依赖环境变量**:`(chandler runtime-paths)` 的 `resource-path` / `find-resource-path` 扫 `(library-directories)` 的 src/obj 两侧(`<side>/resources/<libpath>/<file>`),进程对着哪些前缀跑,资源就在那里——不再需要 `APP_ROOT`。

`.env`(项目根)由 `run`/`repl`/`env` 消费(`.env` 覆盖进程环境);刻意**不碰** `build`/`deps`/`install`,保住可复现。

> 早期版本生成过 `chandler-setup.ss`(Bundler 的 `bundler/setup` 式)与 `APP_ROOT` 环境变量,均已取消:启动只留 `chandler run` 一条路,资源与库住在同一个前缀里。
> 需要在别的进程里挂同一套路径,用 `eval "$(chandler env)"`;已持有 `(chandler)` 的脚本可直接 `(activate)`。

### 库搜索规则(run / env / repl / activate 一致)

- **项目**(有 lock + 依赖):各依赖的 `(src . obj)` per-dep 对 + path 源目录 + 项目自身库根 + 全局兜底一对(项目最高优先)。
- **非项目**:直接用全局前缀一对 `~/.local/share/chez/src::~/.local/share/chez/<mt>`。

## 命令一览

| 命令 | 作用 |
|------|------|
| `init [--lib\|--app] [--name=N]` | 生成骨架 `manifest.ss` + `chandler-tasks.ss`(默认 lib;`--app` 写 `(app …)` 使其可 pack) |
| `add <name> <url> [--tag/--rev/--branch/--path]` | 添加依赖 |
| `remove <name>` | 移除依赖 |
| `deps [--production] [--offline] [--force] [--update]` | 解析 → 写 lock → git 依赖 checkout 到 `_vendor/` + chandler 运行时门就位 |
| `build [--allow-build[=a,b]]` | 进程内编译依赖闭包 + native → 各 `_vendor/<dep>/_build/<mt>/` |
| `verify` | 校验 `_vendor/` 与 lock 一致(CI) |
| `list` / `tree` | 显示已锁依赖 |
| `run <script.ss> [args…]` | 挂库搜索路径后跑脚本 |
| `exec -- <cmd…>` | 设 `CHEZSCHEMELIBDIRS` 后跑命令 |
| `repl [--runtime skiff\|chez]` | 交互 shell,自动挂库路径(项目优先 + 全局兜底) |
| `make [task]` | 跑 `chandler-tasks.ss` 的任务(`build`/`test`/…);无任务文件时从 manifest 推导 |
| `install [--user\|--system\|--prefix=DIR]` | 装项目库 + 依赖到全局前缀(注册表事务)。**app 自动建命令行入口** `~/.local/bin/<app>`(POSIX)/ `%LOCALAPPDATA%\chez\bin\<app>.ps1`(Windows) |
| `uninstall --name=<n>` | 干净卸载(含 app 的命令行入口) |
| `list --global` / `doctor` | 列出/体检全局已装包 |
| `pack [--runtime r] [--out dir]` | 组装自包含分发包(自带运行时) |

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
chandler 0.1.4 (skiff 0.1.1) (chez 10.4.1)   # 跑在 skiff 上
$ CHANDLER_RUNTIME=chez chandler --version
chandler 0.1.4 (chez 10.4.1)                 # 跑在标准 Chez 上
```

> **显式覆盖照单执行**:指定了 `CHANDLER_SKIFF`/`CHANDLER_SCHEME` 就只用它——找不到即失败(退出码 127),**不**静默回退到别的运行时(静默回退等于否定了覆盖)。同理,显式指定的运行时不再跑能力探测。
>
> **自动发现时**则相反:名为 `skiff` 的候选须通过能力探测——真跑一段 R6RS 程序、且它以 `(skiff-version)` **自证是 skiff**,才会被选中。故一个能跑程序但并非 skiff 的同名可执行文件会被正确跳过,回退到 Chez。

## 安全模型(designs/08)

- **清单只 `read` 不求值**:`manifest.ss`/`manifest.lock`/registry 一律纯数据,永不 `eval`/`load`。
- **git clone/checkout 零执行**:所有 git 调用带 `-c core.hooksPath=/dev/null`。
- **native 构建 = RCE,须显式授权**:依赖的 native 构建(别人的代码)须 `--allow-build`,且授权**绑构建描述哈希**写入 `.chandler-approvals`——脚本掉包(描述变更)则授权失效重提示。
- **rev 全长锁定 = 内容寻址**:物化只认 lock 里的确切 commit,篡改/重放由 git 对象哈希兜底。

## 开发

```sh
scheme --libdirs . --program tests/run-tests.sps    # 全量测试(纯 Chez,无外部依赖)
petite  --libdirs . --program tests/run-tests.sps   # 同上(Petite 子集校验)
skiff   --libdirs . --program tests/run-tests.sps   # 同上(Skiff 运行时)
bash tests/powershell-run.sh                        # Windows 启动器验收(需 pwsh,缺则跳过)
```

`tests/powershell-run.sh` 把生成的 `chandler.ps1` **渲染后用 pwsh 真跑**(语法 / 运行时强制 / 覆盖 / 退出码 / 参数透传 / 端到端启动)——因为生成的脚本用正斜杠且分隔符取 `[System.IO.Path]::PathSeparator`,同一份脚本在 Linux 的 pwsh 下也成立。装 pwsh:`mise use powershell`。

库布局遵循[库布局规范](chez-skiff-library-layout.md):umbrella `chandler.ss` + 同名子库树 `chandler/`,搜索根 = 仓库根。核心只 `import (chezscheme)`,限 Petite 可跑子集(双运行时可移植)。

### 语言约定

- **用户可见输出一律英文**:CLI 帮助、运行期提示/警告/错误(`printf`/`fprintf`/`error` 的消息),以及**生成物**的头注释(`.chandler-build.ss`、pack 的 `bootstrap.ss`)——工具面向的用户不限中文。风格取 Unix 诊断惯例:小写、简短、不加句号,如 ``manifest.ss not found; run `chandler init` first``。
- **源码注释(`;;` / `;;;`)与本仓文档保持中文**,便于设计推理的表达密度。
- 单复数用 `(plural n "dependency" "dependencies")`(`(chandler util)`),避免 `1 dependencies`。
