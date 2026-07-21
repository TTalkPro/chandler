# Chandler

> git-first 的 Chez Scheme 库管理器,**Skiff** 运行时生态里的包供应商(船具商)。读 `manifest.ss`,把 git 仓库里的 R6RS 库装进项目 `lib/`,一行 `(activate)` 挂载整个依赖环境。标准 Chez 与 Skiff **双运行时**皆可用。

设计文档见 [designs/](designs/);实现任务与进度见 [TASK.md](TASK.md)。

## 定位

- **Skiff**(轻舟)= 运行时(Chez + libuv);**Chandler**(船具商)= 包管理器,管**依赖获取与激活**;**bake** = 构建工具(另仓),管**编译**。
- git-first:依赖来源(URL + tag/rev/branch pin)写在 `manifest.ss`,无需中心 registry。
- 依赖 = 整仓 checkout 到 `lib/<name>/`,仓库根即库搜索根;`manifest.lock` 锁确切 commit,可复现。

## 安装

需 skiff(优先)或 Chez Scheme ≥ 10.0(自带 `git`)。安装方式对齐 **bake**(生态里的构建工具,独立项目):`install.sh` 只做**运行时发现**(skiff → Chez)后委托给工具自身的 `install-self`,默认装到 `~/.local`。

```sh
git clone <this-repo> chandler && cd chandler
./install.sh                      # → ~/.local/share/chez/lib + ~/.local/bin/chandler
./install.sh --prefix ~/opt       # 自定义 prefix
./install.sh --global             # /usr/local(需 root)
export PATH="$HOME/.local/bin:$PATH"
chandler --version
```

安装生成的 `bin/chandler` 启动器**运行时发现**:优先 `skiff`,回退 `scheme`/`chez`(designs/06 双运行时)。卸载:`chandler uninstall-self`(据 `.chandler-self.files` 清单干净删除)。开发期无需安装,直接 `./bin/chandler <命令>`(同样 skiff 优先)。

## 快速上手

```sh
chandler init --name=myapp                 # 生成骨架 manifest.ss(lib/ 入 .gitignore)
chandler add http https://github.com/x/http --tag v1.2.0
chandler install                           # 解析 → 写 manifest.lock → 物化到 lib/
chandler list                              # 看已锁依赖
chandler verify                            # CI:校验 lib/ 与 lock 一致
chandler run app.ss                        # 挂依赖库路径 + 载 native 后跑脚本
```

应用入口一行激活(脚本顶层):

```scheme
(import (chandler))
(activate)               ; 读 ./manifest.lock:挂所有依赖库路径 + 统一载 native
(import (http) (json))   ; 在 activate 之后展开,解析成功
```

## 命令一览

| 命令 | 作用 |
|------|------|
| `init [--lib] [--name=N]` | 生成骨架 `manifest.ss` |
| `add <name> <url> [--tag/--rev/--branch/--path]` | 添加依赖 |
| `remove <name>` | 移除依赖 |
| `install [--production] [--offline] [--force]` | 解析并物化到 `lib/` |
| `update` | 忽略旧 lock 重解析 |
| `build [--allow-build[=a,b]]` | 排单 → bake 编译依赖闭包 + native |
| `verify` | 校验 `lib/` 与 lock 一致(CI) |
| `list` / `tree` | 显示已锁依赖 |
| `run <script.ss> [args…]` | 激活环境后跑脚本 |
| `exec -- <cmd…>` | 设 `CHEZSCHEMELIBDIRS` 后跑命令 |
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
