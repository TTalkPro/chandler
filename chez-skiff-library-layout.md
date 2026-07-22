# Skiff 生态库布局规范(参照 chez-markding)

> **规范来源**:`~/workspace/chez-markding` —— Skiff 生态所有库/项目的布局范本。它是标准 Chez R6RS 惯例:纯靠库搜索路径即可被引用,**不依赖任何包管理器**。分工:库作者按本规范组织代码 → **bake** 构建+安装 → **Chandler** 把它装进消费方并 `activate`。

## 核心约定(5 条)

1. **umbrella facade**:仓库根放 `<name>.ss` = `(library (<name>) ...)`,re-export 公共 API,给使用者一个"一 import 即全"的门面。
2. **子库树镜像库名**:`<name>/` 目录下,`<name>/a/b.ss` = `(library (<name> a b) ...)`。**目录名 = 库名前缀 = 仓库目录名,三者必须一致**。
3. **搜索根 = 仓库根**:仓库根同时含 `<name>.ss` 与 `<name>/`,把**仓库根**加进 `library-directories`(或 `CHEZSCHEMELIBDIRS`),`(import (<name> ...))` 全部可解析。
4. **`#!chezscheme` + 文件头**:每个 `.ss` 首行 `#!chezscheme`(启用 Chez 扩展),次行 `;;; <相对路径> --- <一句话>`。
5. **核心零依赖**:核心只 `(import (chezscheme))`;可选功能(扩展 / FFI)隔离到子目录,按需引入。

## 目录骨架

```
myproj/                        ← 仓库根 = 搜索根(加进 CHEZSCHEMELIBDIRS)
  myproj.ss                    (library (myproj))              ← umbrella facade
  myproj/                      ← Chez 库子树
    core/thing.ss              (library (myproj core thing))
    helpers/util.ss            (library (myproj helpers util))
    ffi/sqlite.ss              (library (myproj ffi sqlite))   ← Scheme 侧 FFI 绑定;用 bake 生成的 (myproj native-loader) 的 native-foreign-procedure(自加载),Chandler 仅兜底
    test/thing.ss              (library (myproj test thing))   ← 与被测库同名共置
  native/ta6le/sqlite.so       ← C/C++ 产物,置于仓库根(不在 myproj/ 子树内,避开难点 4 的 .so 混淆)
  tests/                       ← 顶层脚本入口(非库)
    smoke.ss                   scheme --script tests/smoke.ss
    run-tests.sps              scheme --program tests/run-tests.sps
    bench.sps
  tools/                       ← codegen 等一次性脚本(gen-*.ss)
  specs/  examples/  design/   ← 规格 / 示例 / 设计文档
  manifest.ss  manifest.lock   ← Chandler 清单(仅当有外部依赖时)
  recipe.ss                    ← bake 构建+安装描述(见下)
```

> **native 放仓库根、不放 `myproj/` 子树**:C/C++ 的 `.so` 与 Chez 编译产物的 `.so` 同名不同物(见 Chandler 难点 4)。把 C 产物放在 `native/<machine-type>/`(不构成任何库名前缀),Chez 搜索库时不会撞到它。

## 与 chez-markding 的对应

| 约定 | chez-markding 实例 |
|------|-------------------|
| umbrella | `chez-markding.ss` = `(library (chez-markding) ...)` re-export facade |
| 子库树 | `chez-markding/syntax/block.ss` = `(library (chez-markding syntax block) ...)` |
| 搜索根=仓库根 | `Makefile` 里 `export CHEZSCHEMELIBDIRS := .` |
| 文件头 | `#!chezscheme` + `;;; chez-markding/syntax/block.ss --- …` |
| 共置测试 | `chez-markding/test/*.ss` 为库,顶层 `tests/{smoke.ss,run-tests.sps,bench.sps}` 为脚本 |
| codegen | `tools/gen-unicode-tables.ss` 等 |
| 核心零依赖 | 只用 `(chezscheme)`,无 SRFI/正则/外部库 |

## bake:构建 + 安装(chez-markding Makefile 的泛化)

bake 承担 chez-markding 里 `Makefile` 的角色并泛化,处理**本项目自身**的构建与安装(依赖获取归 Chandler):

- **`bake`(build,默认)**:遍历 `<name>.ss` + `<name>/**/*.ss`,`compile-library` 逐个出 `.so`,编译时 `CHEZSCHEMELIBDIRS` 含仓库根;产物按 `build/<machine-type>/` 隔离(见 bake 文档难点 5)。
- **`bake install`**(> **2026-07-22 src/mt 分裂**):把源码(`<name>.ss` + `<name>/` 树)与平台绑定产物(编译 `.so` + native,即 `_build/<mt>/` 整棵)**分裂**落到**前缀**下的 `src/` 与 `<mt>/` 两支,源侧仍**保持"仓库根=搜索根"结构**:
  - 用户级 `~/.local/share/chez`(默认)→ 源→`<prefix>/src/<name>.ss` 与 `<prefix>/src/<name>/`;编译 `.so` + native→`<prefix>/<mt>/`,native 嵌于归属库下 `<prefix>/<mt>/<lib>/native/`
  - 系统级 `/usr/local/share/chez`(`bake install --global`,需 root)同构
  - 消费方挂**一对** `<prefix>/src::<prefix>/<mt>`,源码与产物同时可解析
  - 记录**已装文件清单**以支持干净卸载(见 Chandler 难点 1)。
  - **现总是同时发**源码与编译产物(src/mt 分裂),不再"发源码还是带 `.so`"二选一。
- **`bake test` / `bake clean`**:同 chez-markding Makefile(跑 `tests/`、删 `.so`)。

详见 **bake 项目**(独立仓库)。

## Chandler:消费(与本规范咬合)

因为"搜索根 = 仓库根"(在 src 侧成立),[Chandler](chez-chandler-git-lib-manager-design.md) 走 Bundler 模型:把依赖**整仓 checkout** 到 `vendor/<name>/`,再 `bake install` 进项目本地的 `lib/{src,<mt>}`,把**一对** `lib/src::lib/<mt>` prepend 到 `library-directories`(源树的根仍是 src 侧的搜索根),`(import (<name> ...))` 即通。native 由扫描 `lib/<mt>/**/native/` **统一自动加载**(一次性 `load-shared-object`),库自身只写 `foreign-procedure`,不必各自 load。

> `manifest.ss` 的 `srcdir` 默认 `"."`(本规范:搜索根=仓库根)。仅当某上游库把库根放在 `src/` 等子目录(不遵循本规范)时,才需为它显式声明 `srcdir "src"`。

## 相关文档

- **skiff 项目**(独立仓库)—— Skiff 运行时
- [chez-chandler-git-lib-manager-design.md](chez-chandler-git-lib-manager-design.md) —— Chandler 包管理器 / `activate` / `load-native`
- **bake 项目**(独立仓库)—— bake 构建 + 安装
