# 13 — 库源码布局规范(Skiff 生态,参照 chez-markding)

> 本文规定**单个 Chez 库/项目仓库的源码组织方式**——它是标准 Chez R6RS 惯例,纯靠库搜索路径即可被引用,**不依赖任何包管理器**。与 [06](06-installed-layout.md)(install 目标布局)正交:06 讲"装到哪里、怎么挂",本文讲"仓库源码本身长什么样"。
>
> **规范来源**:`~/workspace/chez-markding` —— Skiff 生态所有库/项目的布局范本。
>
> **历史**:本文前身是仓库根的 `chez-skiff-library-layout.md`,2026-07-26 迁入 designs/ 并对齐 v3/v4(bake 已并入 chandler、`manifest.ss` → `chandler-manifest.ss`、消费方由中心 `lib/` 改为 per-dep `(src . obj)` 对)。

## 1. 核心约定(6 条)

1. **umbrella facade**:仓库根放 `<name>.ss` = `(library (<name>) ...)`,re-export 公共 API,给使用者一个"一 import 即全"的门面。
2. **子库树镜像库名**:`<name>/` 目录下,`<name>/a/b.ss` = `(library (<name> a b) ...)`。**目录名 = 库名前缀 = 仓库目录名,三者必须一致**。
3. **搜索根 = 仓库根**:仓库根同时含 `<name>.ss`、`<name>/` 与 `tests/`,把**仓库根**加进 `library-directories`(或 `CHEZSCHEMELIBDIRS`),`(import (<name> ...))` 与 `(import (tests <name> ...))` 全部可解析。
4. **`#!chezscheme` + 文件头**:每个 `.ss` 首行 `#!chezscheme`(启用 Chez 扩展),次行 `;;; <相对路径> --- <一句话>`。
5. **核心零依赖**:核心只 `(import (chezscheme))`;可选功能(扩展 / FFI)隔离到子目录,按需引入。
6. **测试独立 collection**:测试套件置于 `tests/<name>/`(namespace `(tests <name> *)`),与生产代码 `<name>/` 解耦——发布的库树不含测试代码,用户安装的是已通过测试的产物,而非开发期库。runner 入口 `tests/run-tests.sps` 同居 `tests/` 下。

## 2. 目录骨架

```
myproj/                            ← 仓库根 = 搜索根(加进 CHEZSCHEMELIBDIRS)
  myproj.ss                        (library (myproj))              ← umbrella facade
  myproj/                          ← Chez 库子树(仅生产代码)
    core/thing.ss                  (library (myproj core thing))
    helpers/util.ss                (library (myproj helpers util))
    ffi/sqlite.ss                  (library (myproj ffi sqlite))   ← Scheme 侧 FFI 绑定;用 chandler build 生成的 (myproj native-loader) 的 native-foreign-procedure(自加载),activate/run 仅兜底
  native/ta6le/sqlite.so           ← C/C++ 产物,置于仓库根(不在 myproj/ 子树内,避开 §4 的 .so 混淆)
  tests/                           ← 测试集中区(各库测试 collection + 顶层脚本入口)
    myproj/                        ← myproj 的测试套件,与生产 myproj/ 解耦
      harness.ss                   (library (tests myproj harness))   ← 测试基础设施
      thing.ss                     (library (tests myproj thing))     ← 对应 myproj/core/thing.ss
    smoke.ss                       scheme --script tests/smoke.ss       ← 顶层脚本(非库)
    run-tests.sps                  scheme --program tests/run-tests.sps
    bench.sps
  tools/                           ← codegen 等一次性脚本(gen-*.ss)
  specs/  examples/  designs/      ← 规格 / 示例 / 设计文档
  chandler-manifest.ss             ← Chandler 清单(仅当有外部依赖时,D14 命名)
  chandler-manifest.lock           ← Chandler 锁(由 chandler deps 写)
  chandler-tasks.ss                ← chandler make 任务描述(可选;无则从 manifest 推导)
```

> **native 放仓库根、不放 `myproj/` 子树**:C/C++ 的 `.so` 与 Chez 编译产物的 `.so` 同名不同物(见 §4)。把 C 产物放在 `native/<machine-type>/`(不构成任何库名前缀),Chez 搜索库时不会撞到它。

## 3. 与 chez-markding 的对应

| 约定 | chez-markding 实例 |
|------|-------------------|
| umbrella | `chez-markding.ss` = `(library (chez-markding) ...)` re-export facade |
| 子库树 | `chez-markding/syntax/block.ss` = `(library (chez-markding syntax block) ...)` |
| 搜索根=仓库根 | `Makefile` 里 `export CHEZSCHEMELIBDIRS := .` |
| 文件头 | `#!chezscheme` + `;;; chez-markding/syntax/block.ss --- …` |
| 独立测试 collection | `tests/<name>/*.ss` 为库 `(library (tests <name> *))`,与生产 `<name>/` 解耦;`tests/{smoke.ss,run-tests.sps,bench.sps}` 为顶层脚本入口 |
| codegen | `tools/gen-unicode-tables.ss` 等 |
| 核心零依赖 | 只用 `(chezscheme)`,无 SRFI/正则/外部库 |

## 4. 为什么 native 放仓库根

Chez 编译库产出的 `.so`(`compile-library` 的对象文件)与 C/C++ 编译产出的 `.so`(native 共享库)**同名不同物**。若把 C 产物放在 `<name>/native/` 这种子树里,它会构成库名前缀 `<name> native`,Chez 在 `(library-directories)` 里扫到时无法区分二者,出现"找到 .so 但不是预期库对象"的诡异错误。

把 C 产物置于 `native/<machine-type>/`(在 `<name>/` 子树**之外**),它就不参与任何库名解析,只能由生成的 `native-loader` 显式 `load-shared-object`。

## 5. chandler:构建(已吸收 bake)

bake 的编译引擎已整体并入 chandler,独立 `bake` 二进制作废。chandler 承担 chez-markding 里 `Makefile` 的角色并泛化,处理**本项目自身**的构建(依赖获取、安装是另一层,见 [04](04-install.md) / [06](06-installed-layout.md)):

- **`chandler build`**:按 lock 拓扑序逐依赖**就地编译**(cwd = 该依赖 srcdir,产物留 `_vendor/<dep>/<srcdir>/_build/<mt>/`);本项目自身编译产物落 `_build/<mt>/`。编译时 `CHEZSCHEMELIBDIRS` 含仓库根,已编好的上游作为 `(prebuilt src obj)` 挂入。进程内编译,不 spawn 子进程。
- **`chandler make [task]`**:跑 `chandler-tasks.ss` 里的任务(默认 `build`);无任务文件时从 `chandler-manifest.ss` 的 `(app (entry …))` 推导要编什么。
- **`chandler test` / `chandler make clean`**:同 chez-markding Makefile(跑 `tests/run-tests.sps`、删 `.so`)。测试入口已从 `chandler-tasks.ss` 自带的 `'test` 任务迁到独立 CLI 子命令 `chandler test`(挂项目库路径 + native 兜底 + 选择 runtime + 加载 `.env`/`.env.tests`)。

## 6. chandler:消费(与本规范咬合)

因为"搜索根 = 仓库根"(在 src 侧成立),chandler 走 Bundler 模型:`chandler deps` 把依赖**整仓 checkout** 到 `_vendor/<name>/`,各依赖就地编译(产物留在它自己的 `_build/<mt>/`);**消费方挂的是 per-dep `(src . obj)` 对**(`_vendor/<dep>/<srcdir>::_vendor/<dep>/<srcdir>/_build/<mt>`),`(import (<name> ...))` 即通。详见 [06](06-installed-layout.md) 与 [10](10-dev-mode.md)。

native 加载:**自加载优先,统一加载兜底**。`chandler build` 为每个带 native 的库生成 `(<lib> native-loader)`,该库的 FFI 被引用时 loader 自己定位并加载 `.so`——其候选之一正是 `(library-directories)` 的对象侧,而各依赖 obj 侧恰是 native 落点,故**挂好对即自动生效**,且是惰性的(不碰 FFI 就不 `dlopen`)。`activate` / `run` / `repl` 的预加载降级为兜底:只为"无生成 loader"的第三方库扫描加载。

> `chandler-manifest.ss` 的 `srcdir` 默认 `"."`(本规范:搜索根=仓库根)。仅当某上游库把库根放在 `src/` 等子目录(不遵循本规范)时,才需为它显式声明 `srcdir "src"`。

## 7. install 目标布局(交叉引用)

本文只管"源码仓库长什么样"。**装到全局前缀后的目录布局**(版本化 `<libdir>/<name>/<version>/{src,<mt>}/`、中心 `.registry/`、稳定 shim launcher、lock 驱动 run.sps)是另一层设计,见 [06](06-installed-layout.md)。

## 相关文档

- [06-installed-layout.md](06-installed-layout.md) —— v3 中心设计:install 目标布局、中心 `.registry/`、switch
- [04-install.md](04-install.md) —— install 操作:整目录 promote + per-prefix 锁
- [00-design-principles.md](00-design-principles.md) —— 核心模型 + 不变量 + 术语表
- **skiff 项目**(独立仓库)—— Skiff 运行时(Chez + libuv)
