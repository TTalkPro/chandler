# Chandler

> git-first 的 Chez Scheme 库管理器,**Skiff** 运行时生态里的包供应商(船具商)。读 `manifest.ss`,把 git 仓库里的 R6RS 库装进项目 `lib/`,一行 `(activate)` 挂载整个依赖环境。标准 Chez 与 Skiff **双运行时**皆可用。

设计文档见 [designs/](designs/);实现任务与进度见 [TASK.md](TASK.md)。

## 定位

- **Skiff**(轻舟)= 运行时(Chez + libuv);**Chandler**(船具商)= 包管理器,管**依赖获取与激活**;**bake** = 构建工具(另仓),管**编译**。
- git-first:依赖来源(URL + tag/rev/branch pin)写在 `manifest.ss`,无需中心 registry。
- 依赖 = 整仓 checkout 到 `vendor/<name>/`,再经 `bake install` 摊平进 `lib/{src,<mt>}`(src/mt 拆分);`manifest.lock` 锁确切 commit,可复现。

> **2026-07-22 对齐 bake install 改版**:`bake install` 落点由扁平 `lib/` 改为 **src/mt 拆分**——源码 → `<prefix>/src/`、平台绑定产物(编译 `.so` + native)整棵 `_build/<mt>/` → `<prefix>/<mt>/`。消费方用一条 Chez 库目录**对** `<prefix>/src::<prefix>/<mt>`(`::` = 源::对象)同时解析源码与对象;native 收进所属库 `<prefix>/<mt>/<lib>/native/`。

## 安装

需 skiff(优先)或 Chez Scheme ≥ 10.0(自带 `git`),以及生态里的构建工具 **bake**——**chandler 的自安装基于 `bake install`**:库树由 bake 装进 Chez 库前缀(读本仓 `recipe.ss`,src/mt 拆分),`install.sh` 再补一个运行时发现启动器。

```sh
git clone <this-repo> chandler && cd chandler
./install.sh                      # 库经 bake → ~/.local/share/chez/{src,<mt>},启动器 → ~/.local/bin/chandler
./install.sh --global             # /usr/local(需 root)
export PATH="$HOME/.local/bin:$PATH"
chandler --version
```

安装生成的 `bin/chandler` 启动器**运行时发现**:优先 `skiff`,回退 `scheme`/`chez`(designs/06 双运行时),并挂 `<prefix>/src::<prefix>/<mt>` 一对跑 `<prefix>/src/chandler/cli/main.sps`。卸载:`chandler uninstall-self`(据 bake 的 `<prefix>/.bake-install/chandler.files` 清单删库 + 删启动器,不依赖源码)。开发期无需安装,直接 `./bin/chandler <命令>`(同样 skiff 优先)。

### 用 bake 构建/安装(生态闭环)

chandler 带 `recipe.ss`,可被生态里的构建工具 **bake** 直接构建与安装——把 `(chandler …)` 库树装进 Chez lib dir,`(import (chandler …))` 全局可解析(bake 自身即依赖 `(chandler lock/registry/…)`,这是 **skiff 跑 · chandler 管依赖 · bake 装库** 的闭环处):

```sh
bake            # = bake build,编译 (chandler) 库树为 .so
bake test       # 跑全测试套件(133 用例)
bake install    # 装 (chandler) 库树 → ~/.local/share/chez/{src,<mt>}(--global 装 /usr/local)
bake uninstall  # 据清单干净卸载
```

> `bake install` 装的是 **库**(供 `import`,src/mt 拆分,`(needs build)` 恒装编译内容);`chandler` **CLI 启动器**由 `chandler install-self` / `install.sh` 提供。

## 快速上手

```sh
chandler init --name=myapp                 # 生成骨架 manifest.ss(vendor/ lib/ setup 入 .gitignore)
chandler add http https://github.com/x/http --tag v1.2.0
chandler install                           # 解析 → 写 lock → git 依赖到 vendor/ → bake install 到 lib/{src,<mt>}
chandler list                              # 看已锁依赖
chandler verify                            # CI:校验 vendor/ 与 lock 一致
chandler repl                              # 交互 shell(自动挂库路径)
```

## 依赖模型(Bundler 式)

```
myapp/
  manifest.ss  manifest.lock
  vendor/<name>/           ← git 依赖的原始整仓 checkout
  lib/                     ← bake install 出的 Chez 库前缀(src/mt 拆分,结构同 ~/.local/share/chez)
    src/<name>.ss  src/<name>/…       ← 各依赖源码并存(install 摊平)
    <mt>/<name>.so  <mt>/<name>/…  <mt>/<name>/native/…   ← 编译产物 + native(chandler build 后填充)
  chandler-setup.ss        ← 生成的「一行激活」文件(Bundler 的 bundler/setup)
```

- **`chandler install`**:git 依赖整仓 checkout 到 `vendor/`,再由 **bake install** 装进 `lib/{src,<mt>}`(只发源码)。库搜索挂**一对** `lib/src::lib/<mt>`,结构同全局前缀 `~/.local/share/chez`(install 依赖 bake)。
- **`chandler build`**:于项目根生成一份 recipe(`define-lib-roots "lib/src"` + 逐依赖 `library-task`/授权的 `native-task`),跑**真实 bake** 编译进 `_build/<mt>/`,再拷进 `lib/<mt>/` 补齐对(编译产物 + native)。
- **path 依赖** `(path "../x")`:不进 vendor/lib,直挂其源目录(live,改一行立即生效)。

### 一行激活(Bundler 式)

`chandler install` 生成 `chandler-setup.ss`。在主脚本顶部 `(load)` 它,即挂好 `lib/` 一对(源.对象)(+ path 源目录 + 全局兜底一对)并**运行时扫描** `lib/<mt>/**/native/` 载 native——之后 `(import (dep))` 即通,**纯 skiff/scheme 跑即可,无需 chandler 在场**:

```scheme
;; 位置无关加载(项目可整体移动、任意 cwd 皆可):
(load (string-append (let ([d (path-parent (car (command-line)))])
                       (if (string=? d "") "." d)) "/chandler-setup.ss"))
(import (http) (json))          ; 已可解析
(main)
;; 若总从项目根运行,简写:(load "chandler-setup.ss")
```

`chandler-setup.ss` 依**入口脚本(与它同目录)的位置**在运行时解析项目根,不硬编码绝对路径。

### 库搜索规则(run / exec / repl / setup 一致)

- **项目**(有 lock + 依赖):`lib/src::lib/<mt>` 一对 + path 源目录 + 项目自身库根 + 全局兜底一对(项目最高优先)。
- **非项目**:直接用全局前缀一对 `~/.local/share/chez/src::~/.local/share/chez/<mt>`。

## 命令一览

| 命令 | 作用 |
|------|------|
| `init [--lib] [--name=N]` | 生成骨架 `manifest.ss` |
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
| `install-self [--prefix D] [--global]` | 自装 chandler 到 `~/.local`(bake 式,skiff 优先启动器) |
| `uninstall-self [--prefix D]` | 卸载自装的 chandler |
| `self-update` | 提示重跑 `install.sh` |

全局旗标:`-C <dir>` `--offline` `--production` `--force` `--keep-extra` `--verbose`。

## 安全模型(designs/08)

- **清单只 `read` 不求值**:`manifest.ss`/`manifest.lock`/registry 一律纯数据,永不 `eval`/`load`。
- **git clone/checkout 零执行**:所有 git 调用带 `-c core.hooksPath=/dev/null`。
- **native 构建 = RCE,须显式授权**:依赖的 native 构建(别人的代码)须 `--allow-build`,且授权**绑构建描述哈希**写入 `.chandler-approvals`——脚本掉包(描述变更)则授权失效重提示。
- **rev 全长锁定 = 内容寻址**:物化只认 lock 里的确切 commit,篡改/重放由 git 对象哈希兜底。

## 开发

```sh
scheme --libdirs . --program tests/run-tests.sps    # 全量测试(纯 Chez,无外部依赖)
```

库布局遵循[库布局规范](chez-skiff-library-layout.md):umbrella `chandler.ss` + 同名子库树 `chandler/`,搜索根 = 仓库根。核心只 `import (chezscheme)`,限 Petite 可跑子集(双运行时可移植)。
