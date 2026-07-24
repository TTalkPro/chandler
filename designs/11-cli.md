# 11 — CLI 命令面

> 状态: 设计中

## 1. 一句话目标

统一的 CLI 命令集 + 全局旗标 + 标准化退出码,覆盖项目开发期和全局安装期全部操作。

## 2. 命令一览

| 命令 | 说明 | v2 变更 |
|------|------|--------|
| `init [--lib\|--app] [--name=N]` | 生成骨架 `manifest.ss` + `chandler-tasks.ss` | — |
| `add <name> <url> [--tag/--rev/--branch/--path]` | 添加 git 依赖 | — |
| `add <name> --prebuilt <url> [--mt <mt>]` | 添加 prebuilt 依赖 | **v2 新增** |
| `remove <name>` | 移除依赖 | — |
| `deps [--production] [--offline] [--force] [--update]` | 解析 + 写 lock + materialize 到 _vendor | — |
| `build [--allow-build[=a,b]]` | 编译 git 依赖闭包 | — |
| `install [--prefix=<dir>] [--user\|--system]` | 装到中央仓库或自定义 prefix | — |
| `install <pack.tar.gz>` | 从 pack 直接安装 | **v2 新增** |
| `uninstall --name=<n> [--version=<v>]` | 卸载 | **v2 加 --version** |
| `update [<name>...]` | 重新 resolve + 装 | — |
| `list --global` / `tree` | 列出已装依赖 | — |
| `doctor --global` | 体检 | — |
| `run <script.ss> [args...]` | dev 模式运行 | — |
| `repl [--runtime skiff\|chez]` | 交互 shell | — |
| `exec -- <cmd...>` | 设库路径后跑命令 | — |
| `env` | 输出 shell eval-able 环境变量 | — |
| `pack [--runtime skiff\|chez\|petite] [--out <dir>] [--name <n>] [--version <v>]` | 打 app pack | — |
| `pack --lib <name>` | 打 lib pack | **v2 新增** |
| `verify-pack <dir\|pack.manifest>` | 校验 pack 完整性 | — |
| `make [task]` | 跑 `chandler-tasks.ss` 的任务 | — |

### 2.1 命令语义

#### init

```sh
chandler init [--lib|--app] [--name=N]
```

生成骨架 `manifest.ss`:
- `--lib`(默认):生成 lib manifest,无 `(app ...)` 字段
- `--app`:生成 app manifest,含 `(app (entry ...))`
- `--name=N`:项目名,默认取目录名

#### add

```sh
chandler add <name> <url> [--tag v1.0.0|--rev <sha>|--branch <name>|--path <relpath>]
chandler add <name> --prebuilt <url> [--mt <mt>]
```

- git 依赖:`<name>` + `<url>` + pin策略
- prebuilt 依赖(v2):`--prebuilt` + URL,可选 `--mt` 指定 machine-type
- path 依赖:`--path <relpath>`,不进 `_vendor`,直挂源目录

#### deps

```sh
chandler deps [--production] [--offline] [--force] [--update]
```

- `--production`:跳过 dev-deps
- `--offline`:只从缓存解析
- `--force`:强制覆盖已有 vendor
- `--update`:删除旧 lock,重新解析

#### build

```sh
chandler build [--allow-build[=a,b]]
```

- `--allow-build`:授权 native 构建,可指定库名列表
- 按 lock 拓扑序就地编译,产物留各 `_vendor/<dep>/<srcdir>/_build/<mt>/`

#### install

```sh
chandler install [--prefix=<dir>] [--user|--system]
chandler install <pack.tar.gz>
```

- 装项目库 + 依赖到全局前缀
- app 自动建命令行入口(`~/.local/bin/<app>` / `%LOCALAPPDATA%\chez\bin\<app>.ps1`)
- **v2**:从 pack tarball 直接安装

#### uninstall

```sh
chandler uninstall --name=<n> [--version=<v>]
```

- `--version`:精确到版本卸载(v2 新增)
- 不带 `--version` 卸载该 name 的所有版本

#### pack

```sh
chandler pack [--runtime r] [--out <dir>] [--name <n>] [--version <v>]
chandler pack --lib <name>
```

- app pack:payload + envelope
- **v2** `--lib <name>`:打 lib pack(payload only,无 envelope)

## 3. 全局旗标

| 旗标 | 说明 | v2 变更 |
|------|------|--------|
| `-C <dir>` | 切工作目录 | — |
| `--offline` | 离线模式(只从缓存) | — |
| `--production` | 跳过 dev-deps | — |
| `--force` | 强制覆盖 | — |
| `--allow-build[=<libs>]` | 授权 native 构建 | — |
| `--allow-prebuilt-native` | 授权 prebuilt 含 native 的安装 | **v2 新增** |
| `--keep-extra` | 保留 vendor 中非 lock 来源的目录 | — |
| `--verbose` | 详细输出 | — |

## 4. 环境变量

| 变量 | 说明 |
|------|------|
| `CHANDLER_HOME` | chandler runtime prefix(源码 + 编译产物) |
| `CHANDLER_RUNTIME=skiff\|chez` | 选哪一种运行时 |
| `CHANDLER_SKIFF=<exe>` | skiff 可执行文件路径 |
| `CHANDLER_SCHEME=<exe>` | Chez 可执行文件路径 |
| `CHEZSCHEMELIBDIRS` | 库搜索路径(run/repl/exec 自动设) |

> **v2 去除 `APP_ROOT`**:完全靠 `(library-directories)` 定位文件路径(资源、native、import)。见 [09-runtime-paths §4](09-runtime-paths.md)。

## 5. 退出码(sysexits 风格)

| 码 | 常量 | 含义 |
|----|------|------|
| 0 | EX_OK | 成功 |
| 64 | EX_USAGE | 参数错误(非法旗标、缺少必需参数) |
| 65 | EX_DATAERR | manifest/lock 数据错误(格式错、校验失败) |
| 66 | EX_NOINPUT | 文件不存在(manifest.ss、lock 等) |
| 70 | EX_SOFTWARE | internal error / install broken |
| 73 | EX_CANTCREAT | 冲突,无法创建(目录冲突、文件已存在且 --force 未指定) |
| 77 | EX_NOPERM | 权限不足(如 prebuilt native 未授权 `--allow-prebuilt-native`) |
| 127 | — | runtime 找不到(skiff/scheme 不在 PATH) |

## 6. 版本输出格式

```sh
$ chandler --version
chandler <ver> (<runtime> <ver>) (<chez> <ver>)
```

示例:
```
chandler 0.2.0 (skiff 0.1.1) (chez 10.4.1)
chandler 0.2.0 (chez 10.4.1)
```

## 7. 用户可见输出语言

CLI 帮助、错误消息一律**英文**。风格取 Unix 诊断惯例:**小写、简短、不加句号**。

示例:
```
manifest.ss not found; run `chandler init` first
invalid CHANDLER_RUNTIME (want: skiff|chez)
no Scheme runtime found (install skiff or Chez Scheme)
```

## 8. 子命令帮助

```sh
chandler <cmd> --help
```

每个子命令的 help 输出该命令的用法、旗标说明、示例。

## 相关文档

- [00-design-principles.md](00-design-principles.md) — 核心模型 + 术语表(宪法)
- [10-dev-mode.md](10-dev-mode.md) — dev 模式命令(run/repl/exec/env)
- [12-security.md](12-security.md) — 安全旗标(--allow-prebuilt-native)
