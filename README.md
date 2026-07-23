# Chandler

> git-first 的 Chez Scheme 库管理器,**Skiff** 运行时生态里的包供应商(船具商)。读 `manifest.ss`,把 git 仓库里的 R6RS 库装进项目 `lib/`,一行 `(activate)` 挂载整个依赖环境。标准 Chez 与 Skiff **双运行时**皆可用。

**中文 | [English](README.en.md)** — 设计文档见 [designs/](designs/);实现任务与进度见 [TASK.md](TASK.md)。

## 定位

- **Skiff**(轻舟)= 运行时(Chez + libuv);**Chandler**(船具商)= 包管理器,管**依赖获取与激活**;**bake** = 构建工具(另仓),管**编译**。
- git-first:依赖来源(URL + tag/rev/branch pin)写在 `manifest.ss`,无需中心 registry。
- 依赖 = 整仓 checkout 到 `vendor/<name>/`,再由 **chandler 直接**摊平进 `lib/{src,<mt>}`(src/mt 拆分);`manifest.lock` 锁确切 commit,可复现。

> **2026-07-22 对齐 bake install 改版**:`bake install` 落点由扁平 `lib/` 改为 **src/mt 拆分**——源码 → `<prefix>/src/`、平台绑定产物(编译 `.so` + native)整棵 `_build/<mt>/` → `<prefix>/<mt>/`。消费方用一条 Chez 库目录**对** `<prefix>/src::<prefix>/<mt>`(`::` = 源::对象)同时解析源码与对象;native 收进所属库 `<prefix>/<mt>/<lib>/native/`。

## 安装

### 前置环境

| 需要 | 说明 |
|------|------|
| **Scheme 运行时** | **skiff**(优先)或 **Chez Scheme ≥ 10.0**。二者装一个即可;都在则默认用 skiff。**Petite 不够**——它没有编译器,而 `bake install` 要编译库树。 |
| **git** | 依赖获取靠它(`git` 需在 PATH 上)。 |
| **bake** | 生态里的构建工具。`chandler build` 委托 bake 编译依赖闭包。**`chandler install` 不需要 bake**(只拷源码)。bake 仅 `chandler build` 时需要。 |
| PowerShell | **仅 Windows 需要**(启动器与安装脚本是 `.ps1`)。Windows 10/11 自带;或 `mise use powershell`。 |

装 bake 前若尚无运行时,先装 skiff 或 Chez;`mise` 用户可 `mise use chezscheme`。

### POSIX(Linux / macOS)

```sh
git clone <this-repo> chandler && cd chandler
scheme --script bootstrap.sh               # chandler 铺库 → ~/.local/share/chez/{src,<mt>};启动器 → ~/.local/bin/chandler
skiff --script bootstrap.sh --global        # 装到 /usr/local(需 root)

export PATH="$HOME/.local/bin:$PATH"        # 若尚未在 PATH 上(脚本会提示这行)
chandler --version                          # → chandler 0.1.4 (skiff 0.1.2) (chez 10.4.1)
```

### Windows(PowerShell)

```powershell
git clone <this-repo> chandler; cd chandler
scheme --script bootstrap.sh                 # 启动器 → %USERPROFILE%\.local\bin\chandler.ps1
scheme --script bootstrap.sh --global        # 系统级(需管理员)

$env:PATH = "$HOME\.local\bin;$env:PATH"
chandler --version
```

> `bootstrap.ss` 是自包含安装器(纯 `(chezscheme)`,零 chandler 依赖):铺源码 + 编译产物 + 写运行时发现启动器。
> 用法:`scheme --script bootstrap.ss [--global] [--force] [--uninstall]`。用户通过调用方式选择运行时(`scheme` vs `skiff`)。
>
> 若 PowerShell 报「running scripts is disabled」,是执行策略为 Restricted,二选一:
> `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`(一次性),或
> `pwsh -ExecutionPolicy Bypass -File ...`(仅本次)。

### 装完之后

安装出的启动器做**运行时发现**:优先 `skiff`,回退 `scheme`/`chez`(designs/06 双运行时),并挂 `<prefix>/src::<prefix>/<mt>` 一对跑 `<prefix>/src/chandler/cli/main.sps`。POSIX 是 `chandler`(sh),Windows 是 `chandler.ps1`(PowerShell)。

想固定用某个运行时,见下面[「指定运行时」](#指定运行时skiff--chez)——安装脚本与启动器认同一套变量。

**卸载**:`scheme --script bootstrap.ss --uninstall`(按命名空间删库 + 删启动器,**不依赖文件清单**,装完把仓库删了也能卸干净)。

**开发期不必安装**:仓库里直接 `./bin/chandler <命令>`(同样 skiff 优先)。

### 用 bake 构建/安装(生态闭环)

chandler 带 `recipe.ss`,可被生态里的构建工具 **bake** 直接构建与安装——把 `(chandler …)` 库树装进 Chez lib dir,`(import (chandler …))` 全局可解析(bake 自身即依赖 `(chandler lock/registry/…)`,这是 **skiff 跑 · chandler 管依赖 · bake 装库** 的闭环处):

```sh
bake            # = bake build,编译 (chandler) 库树为 .so
bake test       # 跑全测试套件(138 用例)
bake test-ps    # PowerShell 启动器验收(需 pwsh,缺则跳过)
bake install    # 装 (chandler) 库树 → ~/.local/share/chez/{src,<mt>}(--global 装 /usr/local)
bake uninstall  # 据清单干净卸载
```

> `bake` 装的是 **库**(供 `import`,src/mt 拆分);`chandler` **CLI 启动器**由 `bootstrap.ss` 安装时生成。

## 快速上手

```sh
chandler init --name=myapp                 # 生成骨架 manifest.ss(vendor/ lib/ setup 入 .gitignore)
chandler add http https://github.com/x/http --tag v1.2.0
chandler install                           # 解析 → 写 lock → git 依赖到 vendor/ → chandler 直接铺源码到 lib/src/
chandler list                              # 看已锁依赖
chandler verify                            # CI:校验 vendor/ 与 lock 一致
chandler repl                              # 交互 shell(自动挂库路径)
```

## 依赖模型(Bundler 式)

```
myapp/
  manifest.ss  manifest.lock
  vendor/<name>/           ← git 依赖的原始整仓 checkout
  lib/                     ← 项目自己的 Chez 库**前缀**(结构同 ~/.local/share/chez 与解开的 pack)
    src/<name>.ss  src/<name>/…       ← 各依赖源码并存(install 摊平)
    <mt>/<name>.so  <mt>/<name>/…  <mt>/<name>/native/…   ← 编译产物 + native(chandler build 后填充)
    share/<name>/resources/…          ← 资源(依赖声明的 + 本项目 resources/ 同步过来的)
    .chandler/<name>/manifest.ss      ← 清单快照(应用名由此可辨)
```

- **`chandler install`**:git 依赖整仓 checkout 到 `vendor/`,chandler **直接**把源码摊进 `lib/src/`(不经 bake)。库搜索挂**一对** `lib/src::lib/<mt>`,结构同全局前缀 `~/.local/share/chez`。
- **`chandler build`**:于项目根生成一份 recipe(`define-lib-roots "lib/src"` + 逐依赖 `library-task`/授权的 `native-task`),跑**真实 bake** 编译进 `_build/<mt>/`,再拷进 `lib/<mt>/` 补齐对(编译产物 + native)。
- **path 依赖** `(path "../x")`:不进 vendor/lib,直挂其源目录(live,改一行立即生效)。

### native 加载:自加载优先,统一加载兜底

bake 会为每个带 native 的库生成 `(<lib> native-loader)`(产物 `lib/<mt>/<lib>/native-loader.so`),该库的 FFI 被引用时 loader **自己**定位并加载 `.so`——其候选之一正是 `library-directories` 的**对象侧**,而 chandler 挂的 `lib/src::lib/<mt>` 对象侧恰是 native 落点,故**挂好对即自动生效**,且是**惰性**的(不碰 FFI 就不 `dlopen`)。

因此 `activate` / `run` / `repl` 的预加载已降级为**兜底**:只为「非 bake 构建、无生成 loader」的第三方库扫描加载,带 `native-loader.so` 的库一律跳过。

### 启动:统一走 `chandler run`

```sh
chandler run --script main.ss [args...]
```

它一次交接两样东西,之后脚本里 `(import (dep))` 即通:

- **库搜索路径** —— `lib/src::lib/<mt>` 一对(+ path 源目录 + 项目库根 + 全局兜底一对);
- **`APP_ROOT`** —— 指向项目库前缀 `<project>/lib`。资源与 native 都挂在它下面的固定路径上:
  `$APP_ROOT/share/<app>/resources/`(应用数据,见 `(chandler runtime-paths)` 的 `app-resource-path`)、
  `$APP_ROOT/<mt>/<lib>/native/`(bake 生成的 native-loader 自己拼)。

关键在于**三态同一形状**:项目的 `lib/`、全局前缀 `~/.local/share/chez`、解开的 pack ——
都是同一种前缀,`APP_ROOT` 指向哪一个,应用代码一个字都不用改。

项目自己的 `resources/` 由 `chandler deps` / `run` / `repl` 同步进 `lib/share/<name>/resources/`
(按 mtime 增量),故开发期改一个资源文件,下次 `chandler run` 即生效。

> 早期版本生成过 `chandler-setup.ss`(Bundler 的 `bundler/setup` 式,由主脚本 `(load)`)。
> 现已取消:启动器只留 `chandler run` 一条路,省掉「生成物与真实规则可能漂移」这一类问题。
> 需要在别的进程里挂同一套路径,用 `eval "$(chandler env)"`(它同时导出 `CHEZSCHEMELIBDIRS`
> 与 `APP_ROOT`);已持有 `(chandler)` 的脚本可直接 `(activate)`。

### 库搜索规则(run / env / repl / activate 一致)

- **项目**(有 lock + 依赖):`lib/src::lib/<mt>` 一对 + path 源目录 + 项目自身库根 + 全局兜底一对(项目最高优先)。
- **非项目**:直接用全局前缀一对 `~/.local/share/chez/src::~/.local/share/chez/<mt>`。

## 命令一览

| 命令 | 作用 |
|------|------|
| `init [--lib\|--app] [--name=N]` | 生成骨架 `manifest.ss`(默认 lib;`--app` 写 `(app …)` 使其可 pack) |
| `add <name> <url> [--tag/--rev/--branch/--path]` | 添加依赖 |
| `remove <name>` | 移除依赖 |
| `install [--production] [--offline] [--force]` | 解析并物化到 `lib/{src,<mt>}` |
| `update` | 忽略旧 lock 重解析 |
| `build [--allow-build[=a,b]]` | 生成 recipe → 真实 bake 编译依赖闭包 + native → `lib/<mt>/` |
| `verify` | 校验 `vendor/` 与 lock 一致 + `lib/src` 在(CI) |
| `list` / `tree` | 显示已锁依赖 |
| `run <script.ss> [args…]` | 激活环境后跑脚本 |
| `exec -- <cmd…>` | 设 `CHEZSCHEMELIBDIRS` 后跑命令 |
| `repl [--runtime skiff\|chez]` | 交互 shell,自动挂库路径:**项目有 lock+依赖 → 项目 `lib/`(最高优先)+ 全局兜底;否则 → 全局** |
| `install --global[=dir]` | 装当前项目库到全局 libdir(注册表事务) |
| `uninstall --global --name=<n>` | 据文件清单干净卸载 |
| `list --global` / `doctor --global` | 列出/体检全局已装包 |
| `pack [--runtime r] [--out dir]` | 组装自包含分发包 |

全局旗标:`-C <dir>` `--offline` `--production` `--force` `--keep-extra` `--verbose`。

## 指定运行时(skiff / chez)

「用哪一种运行时」与「用哪个可执行文件」分开:

| 变量 | 作用 |
|------|------|
| `CHANDLER_RUNTIME=skiff\|chez` | 选**哪一种**;非法值报错(退出码 64),不静默忽略 |
| `CHANDLER_SKIFF=<exe>` | skiff 的可执行文件(名或路径) |
| `CHANDLER_SCHEME=<exe>` | Chez 的可执行文件(名或路径) |
| `CHANDLER_BAKE=<exe>` | bake 的可执行文件(build 委托它编译;install 不需要) |

**优先级**(`run` / `exec` / `repl`、**启动器**、**安装脚本**共用一套):

```
--runtime 旗标  >  CHANDLER_RUNTIME  >  manifest 声明(仅 (skiff …) → skiff)  >  默认
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
