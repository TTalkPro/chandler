# 10 — dev 模式

> 状态: 设计中

## 1. 一句话目标

开发者在项目根编辑代码,实时运行/测试,无需 `install`。

## 2. 概述

dev 模式是 Chandler 三种运行模式之一(00 §6)。它让 `_vendor/` 里的 git checkout 保持 live 状态——源码就地编辑,`chandler run/repl/exec` 实时挂载库搜索路径,子进程里的 `(import ...)` 通过 `--libdirs` 解析。

与 install/pack 模式的根本区别:**不需要 `(chandler setup)`**,因为 `chandler run` 在启动时实时计算 `resolved-libdirs` 并透传给子进程。

## 3. `_vendor/` 布局(继承现状)

dev 模式下每个依赖的目录结构:

```
<project>/_vendor/
  <dep-name>/<srcdir>/             ← live git checkout(源码 live)
    _build/<mt>/                   ← chandler build 就地编译产物
    resources/<libpath>/           ← 依赖声明的资源(直接 live)
  chandler/                        ← chandler runtime gate(deps 从 CHANDLER_HOME copy)
    chandler/<sub>.ss              ← runtime 子集源码
    _build/<mt>/
      chandler/<sub>.so
```

**项目自身**:

```
<project>/
  <srcdir>/                        ← 项目源码(live)
    resources/<libpath>/           ← 项目自己的资源(verbatim)
  _build/<mt>/                     ← chandler build 产物(就地)
  manifest.ss
  manifest.lock
```

## 4. dev 模式不版本化

dev 是 live checkout,只有一份,version 是隐含的(当前 HEAD/lock 的 rev)。这符合 00 §3 的语义:versioned package 是**已安装**的概念,dev 状态下依赖尚未安装到中央仓库,不存在多版本共存问题。

## 5. 库定位:`resolved-libdirs`

`resolved-libdirs` 返回 per-dep `(src . obj)` 对:

| 层级 | src | obj |
|------|-----|-----|
| 每个 git/path 依赖 | `_vendor/<name>/<srcdir>` | `_vendor/<name>/<srcdir>/_build/<mt>` |
| 项目自身 | `<project>/<srcdir>` | `<project>/_build/<mt>` |
| 全局兜底 | `CHANDLER_HOME/src` | `CHANDLER_HOME/<mt>` |

**注意**:全局兜底从单对(00 v1)变成 list of per-version pairs——中央仓库可同时存多版本,按 versioned package 语义各自独立。

**path 依赖**:`(path "../x")` 不进 `_vendor`,直挂其源目录(live):

```scheme
;; manifest.ss
(deps
  (x (path "../x")))
```

`path-dep-source-dirs` 返回源目录绝对路径,直接加入库搜索路径。

## 6. 跟 install/pack 模式对比

| 维度 | dev 模式 | install/pack 模式 |
|------|---------|------------------|
| 触发 | `chandler run` 在项目根 | app 启动器 |
| 库定位 | `chandler run` 实时算 `resolved-libdirs` + `--libdirs` 透传 | run.sps 里 `(import (chandler setup))` 读 lock |
| 用 `(chandler setup)` 吗 | **否** | **是** |
| 版本化 | 否(live checkout) | 是(已安装到中央仓库) |
| 全局兜底 | list of per-version pairs | 单对(前缀根) |

## 7. `chandler run` 命令行为

```
chandler run <script.ss> [args...]
```

1. 读 `manifest.lock`
2. 算 `resolved-libdirs`(per-dep `(src . obj)` 对 + path 源目录 + 项目自身 + 全局兜底)
3. exec runtime with `--libdirs = path-list(resolved-libdirs)`
4. 子进程里 `(import ...)` 通过 `--libdirs` 解析

## 8. `chandler repl` / `chandler exec`

- **`chandler repl`**:同 run 逻辑,只是解释器调用方式不同。输出当前模式(project/global)和库搜索条目数。
- **`chandler exec -- <cmd...>`**:设 `CHEZSCHEMELIBDIRS` 环境变量后跑命令。

## 9. `chandler env`

输出 shell eval-able 的环境变量:

```sh
export CHEZSCHEMELIBDIRS="src::obj:src::obj:..."
export APP_ROOT="<project>/lib"   # 仅 pack 模式设;dev 模式不设
# .env 覆盖(若有)
```

## 10. 资源定位

dev 模式下 `scan-library-directories` 扫 `_vendor/<dep>/<srcdir>/resources/<libpath>/`——直接 live 源码,无 copy。`APP_ROOT` 不用于资源定位。

## 11. native 加载

dev 用 `_vendor/<dep>/<srcdir>/_build/<mt>/<lib>/native/`。自加载优先,统一加载兜底。有 `native-loader.so` 的库跳过预加载。

## 12. APP_ROOT 的角色

dev 由 `chandler run` 设为 `<project>/lib`(继承现状),**只用于** native-loader candidate 1(`$APP_ROOT/<mt>/<libpath>/native/`)。dev 模式下 native 分散在各 `_vendor/<dep>/<srcdir>/_build/<mt>/`,没有单一前缀能覆盖,故 candidate 1 恒 miss,走 candidate 2(扫 `(library-directories)` obj 侧)命中。

## 13. `chandler build`

按 lock 拓扑序逐依赖就地编译(cwd = dep srcdir,产物留 `_vendor/<dep>/<srcdir>/_build/<mt>/`)。

## 14. dev 模式不变 v1 的核心

C0 决策保留——`resolved-libdirs` 的 per-dep 对模型、path 依赖 live 直挂、资源直接扫 src 侧,全部继承。只是中央仓库兜底从单对变 list of per-version pairs。

## 15. 完整 dev 流程示例

```sh
# 1. 初始化项目
chandler init --name=myapp --app
cd myapp

# 2. 添加 git 依赖
chandler add http https://github.com/x/http --tag v1.2.0

# 3. 解析依赖 + 写 lock + checkout 到 _vendor/
chandler deps
# → manifest.lock 生成
# → _vendor/http/<srcdir>/ = git checkout at v1.2.0
# → _vendor/chandler/ = chandler runtime subset

# 4. 编译依赖闭包
chandler build
# → 各 _vendor/<dep>/<srcdir>/_build/<mt>/ 填充 .so + native/

# 5. 运行
chandler run main.ss
# → 实时算 resolved-libdirs
# → exec skiff/chez --libdirs "src::obj:src::obj:..."
# → 子进程 import 解析通过 --libdirs
```

## 相关文档

- [00-design-principles.md](00-design-principles.md) — 核心模型 + 术语表(宪法)
- [01-manifest-lock.md](01-manifest-lock.md) — manifest.lock schema
- [07-chandler-setup.md](07-chandler-setup.md) — install/pack 的 `(chandler setup)` 机制
- [09-runtime-paths.md](09-runtime-paths.md) — 资源定位 API
- [11-cli.md](11-cli.md) — CLI 命令面
