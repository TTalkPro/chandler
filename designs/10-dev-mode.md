# 10 — dev 模式

> 状态: 设计中

## 1. 一句话目标

开发者在项目根编辑代码,实时运行/测试,无需 `install`。

## 2. 概述

dev 模式是 Chandler 三种运行模式之一(00 §6)。它让 `_vendor/` 里的 git checkout 保持 live 状态——源码就地编辑,`chandler run/repl/exec` 实时挂载库搜索路径,子进程里的 `(import ...)` 通过 `--libdirs` 解析。

与 install/pack 模式的根本区别:**不需要 `(chandler setup)`**,因为 `chandler run` 在启动时实时计算 `resolved-libdirs` 并透传给子进程。

## 3. 布局(app 与 dep 对称)

### 3.1 统一规则

**每个单元(项目自身 / git 依赖 / chandler runtime gate)都遵循同一布局**:

```
<unit-root>/                       ← src(整个目录作为源码根)
  <name>.ss                        ← umbrella
  <name>/                          ← sub-lib tree
  resources/<libpath>/             ← 资源(live)
  _build/
    <mt>/                          ← obj(编译产物隔离)
      <name>.so
      <name>/*.so
      <libpath>/native/<soname>    ← native(若有)
```

`(src . obj) = (<unit-root>/ . <unit-root>/_build/<mt>)`

**`_build/` 的作用**:把编译产物跟源码隔离。源码目录可能含 manifest、tests、resources 等非源码内容,编译 `.so`/native 统一进 `_build/<mt>/` 命名空间,不污染源码根。

### 3.2 项目自身(app)

```
<project>/                         ← src
  myapp.ss
  myapp/
  resources/<libpath>/
  manifest.ss
  manifest.lock
  _build/<mt>/                     ← obj
    myapp.so
    myapp/*.so
```

`(src . obj) = (<project>/ . <project>/_build/<mt>)`

### 3.3 git 依赖(dep)

```
<project>/_vendor/
  <dep-name>/                      ← src(git checkout 根)
    <dep-name>.ss
    <dep-name>/
    resources/<libpath>/
    manifest.ss                    ← 依赖自己的 manifest
    _build/<mt>/                   ← obj
      <dep-name>.so
      <dep-name>/*.so
      <libpath>/native/<soname>
  chandler/                        ← chandler runtime gate(从 CHANDLER_HOME copy)
    chandler/<sub>.ss
    _build/<mt>/
      chandler/<sub>.so
```

`(src . obj) = (_vendor/<name>/ . _vendor/<name>/_build/<mt>)`

**chandler runtime gate 也是同构的**:`_vendor/chandler/` 跟其他 dep 完全一样(`<dir>/` 是 src,`<dir>/_build/<mt>/` 是 obj),不需要特殊例外。

### 3.4 对称性收益

app / dep / chandler gate 三者**完全对称**:

| 单元 | src | obj |
|------|-----|-----|
| app | `<project>/` | `<project>/_build/<mt>/` |
| dep | `_vendor/<name>/` | `_vendor/<name>/_build/<mt>/` |
| chandler gate | `_vendor/chandler/` | `_vendor/chandler/_build/<mt>/` |

统一规则意味着 `resolved-libdirs`、native 加载、资源定位对三者走**同一套代码路径**,无分支特判。

## 4. dev 模式不版本化

dev 是 live checkout,只有一份,version 是隐含的(当前 HEAD/lock 的 rev)。这符合 00 §3 的语义:versioned package 是**已安装**的概念,dev 状态下依赖尚未安装到中央仓库,不存在多版本共存问题。

## 5. 库定位:`resolved-libdirs`

`resolved-libdirs` 返回 per-unit `(src . obj)` 对:

| 层级 | src | obj |
|------|-----|-----|
| 每个 git 依赖 | `_vendor/<name>/` | `_vendor/<name>/_build/<mt>` |
| 项目自身 | `<project>/` | `<project>/_build/<mt>` |
| chandler runtime gate | `_vendor/chandler/` | `_vendor/chandler/_build/<mt>` |
| path 依赖 | `<path-dir>/` | (无 obj,source-only) |
| 全局兜底 | (Phase 2:扫中央仓库 index.ss 得到 list of per-version pairs;Phase 1:暂无全局兜底) |

**path 依赖**:`(path "../x")` 不进 `_vendor`,直挂其源目录(live):

```scheme
;; manifest.ss
(deps
  (x (path "../x")))
```

`path-dep-source-dirs` 返回源目录绝对路径,直接加入库搜索路径作为 source-only 条目。

## 6. 跟 install/pack 模式对比

| 维度 | dev 模式 | install/pack 模式 |
|------|---------|------------------|
| 触发 | `chandler run` 在项目根 | app 启动器 |
| 库定位 | `chandler run` 实时算 `resolved-libdirs` + `--libdirs` 透传 | run.sps 里 `(import (chandler setup))` 读 lock |
| 用 `(chandler setup)` 吗 | **否** | **是** |
| 版本化 | 否(live checkout) | 是(已安装,有 version 目录) |
| 单元内布局 | `<unit-root>/{<src>},_build/<mt>/` | `<name>/<version>/{src,<mt>}/` |
| src/obj 关系 | obj 是 src 的子目录(`_build/`) | src 和 obj 是兄弟(`src/` + `<mt>/`) |

**为什么 src/obj 关系不对称也 functional**:Chez 的 `library-directories` 只关心 `(src . obj)` 对的两个独立路径,不要求它们有特定的相对关系。dev 用嵌套(`_build/` 在 src 内),install 用兄弟(`src/` + `<mt>/`),Chez 都支持——只要 `(src . obj)` 对内部 library name → path 结构一致。

**为什么 dev 用嵌套而非兄弟**:dev 的单元根是 git checkout,源码直接在根(没有 `src/` 子目录的概念);编译产物用 `_build/` 隔离是最自然的。install 用兄弟是因为 version 目录是 mini-prefix,需要 src/obj 分层(资源在 src/,ABI 绑定的在 `<mt>/`)。

## 7. `chandler run` 命令行为

```
chandler run <script.ss> [args...]
```

1. 读 `manifest.lock`
2. 算 `resolved-libdirs`(per-unit `(src . obj)` 对 + path 源目录 + 项目自身 + chandler runtime gate + 全局兜底)
3. exec runtime with `--libdirs = path-list(resolved-libdirs)`
4. 子进程里 `(import ...)` 通过 `--libdirs` 解析

## 8. `chandler repl` / `chandler exec`

- **`chandler repl`**:同 run 逻辑,只是解释器调用方式不同。输出当前模式(project/global)和库搜索条目数。
- **`chandler exec -- <cmd...>`**:设 `CHEZSCHEMELIBDIRS` 环境变量后跑命令。

## 9. `chandler env`

输出 shell eval-able 的环境变量:

```sh
export CHEZSCHEMELIBDIRS="src::obj:src::obj:..."
# APP_ROOT 在 dev 模式不设(只 pack 模式设)
# .env 覆盖(若有)
```

## 10. 资源定位

dev 模式下**只走 primary 路径**(`scan-library-directories`),扫各 `(src . obj)` 对的 src 侧:

- dep 资源: `_vendor/<name>/resources/<libpath>/`
- app 资源: `<project>/resources/<libpath>/`
- path 依赖资源: `<path-dir>/resources/<libpath>/`

**N+1 fallback 在 dev 模式不可用**:fallback 走 `(library-object-filename)` + N+1 parents,然后拼 `src/resources/<libpath>/`(09-runtime-paths §fallback)。但 dev 模式的 src 直接是目录根(无 `src/` 子目录),fallback 会 miss。这是**可接受的**——primary 路径扫描 library-directories 列表(已包含所有 unit 的 src 端),覆盖率 100%,fallback 只在 primary 失败时兜底,dev 下不会到那一步。

## 11. native 加载

| 单元 | native 位置 |
|------|------------|
| dep | `_vendor/<name>/_build/<mt>/<lib>/native/<soname>` |
| app | `<project>/_build/<mt>/<lib>/native/<soname>` |

**自加载优先**(bake 生成的 `native-loader.so`):loader candidate 1 走 `APP_ROOT/<mt>/<libpath>/native/`,dev 下 APP_ROOT 是 `<project>/lib`(由 `chandler run` 设),只覆盖 app 自己的 native,**dep 的 native 走 candidate 2**(扫 `(library-directories)` obj 侧,即各 `_build/<mt>/`)命中。

有 `native-loader.so` 的库(自加载)跳过预加载扫描。

## 12. APP_ROOT 的角色

dev 由 `chandler run` 设为 `<project>/lib`(沿用现状,兼容旧 native-loader),**只用于** native-loader candidate 1。资源定位不读 APP_ROOT(09-runtime-paths 已移除 APP_ROOT 依赖,走 library-directories 扫描)。

## 13. `chandler build`

按 lock 拓扑序逐单元就地编译,**所有单元规则一致**:

- dep: cwd = `_vendor/<name>/`(checkout 根),产物留 `_vendor/<name>/_build/<mt>/`
- app: cwd = `<project>/`,产物留 `<project>/_build/<mt>/`
- chandler runtime gate: cwd = `_vendor/chandler/`,产物留 `_vendor/chandler/_build/<mt>/`

已编好的上游 dep 作为 prebuilt root `(prebuilt src obj)` 挂入编译环境。

## 14. 跟 v1 C0 的差异(简化记录)

| | v1 C0 | v2(本文) |
|---|---|---|
| dep src | `_vendor/<name>/<srcdir>/` | `_vendor/<name>/`(去掉 srcdir) |
| dep obj | `_vendor/<name>/<srcdir>/_build/<mt>/` | `_vendor/<name>/_build/<mt>/`(保留 _build,去掉 srcdir) |
| app src | `<project>/<srcdir>/` | `<project>/`(去掉 srcdir) |
| app obj | `<project>/_build/<mt>/` | 不变 |
| srcdir 字段 | 有(manifest 声明) | **去掉**(默认源码在 checkout 根/项目根) |
| app/dep 对称性 | 不对称(app 无 srcdir,dep 有) | **完全对称**(都是 `<dir>/` + `<dir>/_build/<mt>/`) |

**去掉 srcdir 的代价**:依赖若把源码放在 checkout 的子目录(如 `src/`),不再支持。这是可接受的——绝大多数 Scheme 库的源码在仓库根;真在子目录的库,消费方可以用 `(path "../x/src")` 直挂。

**保留 `_build/` 的理由**:统一 app/dep/gate 三者的 obj 路径规则,代码无特判;隔离编译产物跟源码,避免 `.so` 混进源码树。

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
# → _vendor/http/ = git checkout at v1.2.0(整个目录是 src)
# → _vendor/chandler/ = chandler runtime gate

# 4. 编译依赖闭包
chandler build
# → _vendor/http/_build/<mt>/ 填充 http.so + http/*.so + native/
# → _build/<mt>/ 填充 myapp.so(项目自身)

# 5. 运行
chandler run main.ss
# → 实时算 resolved-libdirs:
#     (_vendor/http/ . _vendor/http/_build/ta6le)
#     (_vendor/chandler/ . _vendor/chandler/_build/ta6le)
#     (<project>/ . <project>/_build/ta6le)
# → exec skiff/chez --libdirs "..."
# → 子进程 import 解析通过 --libdirs
```

## 相关文档

- [00-design-principles.md](00-design-principles.md) — 核心模型 + 术语表(宪法)
- [01-manifest-lock.md](01-manifest-lock.md) — manifest.lock schema
- [07-chandler-setup.md](07-chandler-setup.md) — install/pack 的 `(chandler setup)` 机制(dev 不用)
- [09-runtime-paths.md](09-runtime-paths.md) — 资源定位 API(dev 只走 primary)
- [11-cli.md](11-cli.md) — CLI 命令面
