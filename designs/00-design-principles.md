# 00 — 设计原则与核心模型

> 本文是 Chandler v2 的"宪法"。所有其他设计文档必须遵守本文的不变量与术语。本文优先级最高;冲突时以本文为准。

## 1. 一句话定位

Chandler 是 **git-first + prebuilt 可选**的 Chez Scheme 包管理器。它把 R6RS 库装进**版本化中央仓库**,以 `(chandler setup)` 启动钩子让每个已安装的 app 在运行时**精确锁定自己依赖的版本**,跟 Bundler 模型同构。

- **Skiff**(轻舟)= 运行时(Chez + libuv)
- **Chandler**(船具商)= 包管理器 + 构建器,管**依赖获取、编译、安装、打包、激活**
- **bake** = 编译引擎,被 chandler 内嵌消费

## 2. 双源模型(git + prebuilt)

依赖有两个来源,在 manifest 里用 `source` 字段表达:

| 源 | 形式 | 编译 |
|----|------|------|
| **git** | `(source (git "<url>"))` + tag/rev/branch/version pin | chandler build 在本地编译 |
| **prebuilt** | `(source (prebuilt (mt <mt> (url "<url>") (sha256 "<hex>")) ...))` | 中央仓库已编译,client 只下载解包 |

**git 是默认源,prebuilt 是加速 / 闭源 / 中央分发渠道**。两者产出的 install 结果**字节级一致**(见 §4 layout),只是 `.chandler/source.ss` 记录的 provenance 不同。

`prebuilt` 可带 `git-fallback`:本机 mt 无对应 prebuilt 时,回退 git clone + 本地编译。

## 3. 核心抽象:Versioned Package

Chandler 的一切操作围绕一个核心抽象 —— **versioned package**:

- 三元组 `(name, version, mt)` 唯一标识一份已编译的库/app 实例
- 每个 versioned package 是**自包含的** —— 独立可装/可卸/可 pack
- name 是 R6RS library name 的顶层标识符(`(mylib)`、`(http)`)
- version 是 semver 字符串(`"1.2.0"`),从 git tag 或 manifest 显式声明得来
- mt 是 Chez machine-type(`ta6le`、`a6le` 等),ABI 绑定

**R6RS 运行时是硬单版本约束** —— 一个进程内每个 library name 只能加载一个 version。Chandler 的多版本**只在文件系统层**(中央仓库可同时存 `http/1.2.0/` 和 `http/1.3.0/`),每个 app 通过自己的 `(chandler setup)` 锁定到具体版本。两个 app 用同一 lib 的不同版本完全互不干扰。

## 4. Unified Layout v2

### 4.1 根布局(payload,所有形态共享)

```
<root>/                              ← central-repo-prefix | pack-payload | _vendor
  .chandler/
    format.ss                        ← (= 2),版本号
    registry/index.ss                ← DERIVED 缓存(扫各 version 的 registry.ss)
  <name>/
    <version>/                       ← 一个 self-contained mini-prefix
      src/                           ← ABI 中立:源码 + 资源
        <name>.ss                    ← umbrella
        <name>/                      ← sub-lib tree
        resources/<libpath>/         ← 资源
      <mt>/                          ← ABI 绑定:编译产物 + native
        <name>.so
        <name>/*.so
        <libpath>/native/<soname>    ← per-lib native
      .chandler/
        manifest.lock                ← 此 version 的 resolve 闭包
        registry.ss                  ← 真相:name, version, exports, files+sha256
        source.ss                    ← (git "<rev>") | (prebuilt (mt ...) ...)
        run.sps                      ← 入口(仅 app 有)
```

### 4.2 Envelope(仅 app pack 根追加)

```
<pack-root>/                         ← = payload + envelope
  bin/
    <app>                            ← POSIX 启动器(sh,ABI 中立)
    <app>.ps1                        ← Windows 启动器
    <mt>/<runtime>                   ← bundled skiff/scheme(ABI 绑定)
  boot/<mt>/*.boot                   ← boot 文件(ABI 绑定)
  chandler-runtime/                  ← bundled chandler runtime(解决 bootstrap paradox)
    src/chandler/
    <mt>/chandler/
  .chandler/
    pack.ss                          ← (entry-app <name>)(entry-version <ver>)(mts <mt>...)
  <name>/<version>/...               ← payload(同 §4.1)
  <dep-name>/<dep-version>/...       ← 依赖闭包 payload
```

**central-repo / `_vendor/` 永不带 envelope**。envelope 只在独立 app pack 出现。

### 4.3 三种形态的字节级一致性

| 形态 | 根 | payload | envelope |
|------|----|--------|----------|
| 中央仓库 install | `~/.local/share/chez/` | ✓ | ✗ |
| 项目 `_vendor/` | `<project>/_vendor/` | ✓ | ✗ |
| App pack 解开 | `<pack-root>/` | ✓ | ✓ |
| Lib pack 解开 | `<lib-pack-root>/`(只有 payload,无 envelope) | ✓ | ✗ |

`<name>/<version>/` 子树在**所有形态下字节级一致** —— pack tarball 解开就是 install subtree,lib pack 解开直接可解到中央仓库。

## 5. 五条不变量

所有其他设计文档必须满足:

### I1. Version 自包含

每个 `<name>/<version>/` 是独立可装/可卸(`rm -rf`)/可 pack(`tar` 子树)的单位。卸载一个 version 永不留下孤儿文件。

### I2. Payload 字节级统一

install / pack / central-repo / _vendor / prebuilt 解包**产出结构相同的 `<name>/<version>/{src,<mt>,.chandler/}`**。payload 对容器无感。

### I3. Registry 混合

- 每个 `<name>/<version>/.chandler/registry.ss` 是**真相之源**(self-contained)
- `<root>/.chandler/registry/index.ss` 是 **DERIVED 缓存**(扫各 version 的 registry.ss 得到)
- primary 查询走 index,N+1 扫描是 fallback(对应 C1:资源定位 primary 走 library-directories 扫描)

### I4. Envelope 仅 app pack 有

`bin/` / `boot/` / `chandler-runtime/` 只在独立 app pack 出现。central-repo、_vendor、lib pack 永不带。**lib pack = payload only,app pack = payload + envelope**。

### I5. Provenance 记录

每个 version 携带 `.chandler/source.ss`,记录来源(`(git "<rev>")` 或 `(prebuilt (mt ...) (url ...) (sha256 ...))`),支持安全审计、复现、mt-gating。

## 6. 三种运行模式

| 模式 | 触发 | 库定位机制 | 用 `(chandler setup)` 吗 |
|------|------|----------|-------------------------|
| **dev** | `chandler run` 在项目根 | `chandler run` 实时算 `resolved-libdirs` + `--libdirs` 传给子进程 | ✗ 不需要(命令实时算) |
| **install** | app 启动器(`~/.local/bin/<app>`) | run.sps 里 `(import (chandler setup))` 读 lock 动态构造 | ✅ **需要** |
| **pack** | 解开的 pack 的 `bin/<app>` | run.sps 里 `(import (chandler setup))` 读 pack 内嵌 lock | ✅ **需要** |

`(chandler setup)` 只在 install 和 pack 模式介入。dev 由 `chandler run` 直接交接。这跟 Bundler 一致(`bundle exec` 实时算,installed gem bin stub 走 `require 'bundler/setup'`)。

## 7. Bundler 模型:`(chandler setup)`

核心机制:**app 不在启动器里硬编码版本,而是 import 一个 setup 库,由它读 lock 动态配置 library-directories**。

```scheme
;; myapp/1.0.0/.chandler/run.sps(install/pack 时生成)
(import (chezscheme)
        (chandler setup)               ;; ← 接管 library-directories
        (myapp main))                  ;; ← import app 入口
(main (cdr (command-line)))
```

`(chandler setup)` 在 import 时:
1. 从 `(car (command-line))` 反推 run.sps 的绝对路径
2. `path-parent` → `<name>/<version>/.chandler/`
3. 读 `manifest.lock`(此 version 的 resolve 闭包)
4. 重写 `(library-directories)` 为 per-package-version 的 `(src . obj)` 对
5. 控制 交回 run.sps,后续 `(import (myapp main))` 通过新 library-directories 解析

**Bootstrap paradox 解决**:pack 在 envelope 里 bundle chandler-runtime,启动器用 Chez 原生 `--libdirs` 指向它,让 `(chandler setup)` 在接管前先能被找到。install 模式则用系统的 chandler-runtime。

## 8. 跟 R6RS / Chez 的关系

| 事项 | R6RS / Chez | Chandler |
|------|------------|---------|
| 多版本共存(同进程内) | **禁止**(import 路径抛异常) | 单进程内仍然单版本(继承 R6RS 约束) |
| 多版本共存(文件系统) | 不规定 | 中央仓库支持多 version 并存 |
| 版本选择(import 时) | 仅 `and`/`or`/`not` + 精确 + prefix | 不用 Chez version ref,完全用 `(chandler setup)` 构造 library-directories |
| 版本号格式 | 整数列表 `(1 0 0)` | 字符串 semver `"1.0.0"`(在 path component 里用) |
| library-directories | list of `(src . obj)` | 直接复用,setup 构造 list |

Chandler **不依赖** R6RS library version reference 语法。版本选择完全在 Chandler 层(resolve + setup),R6RS library 声明不带 version annotation。

## 9. 术语表

| 术语 | 定义 |
|------|------|
| **central repo**(中央仓库) | 默认 install prefix `~/.local/share/chez/`,多 version 共存 |
| **prefix** | 任何能被解析为 §4.1 根布局的目录 |
| **payload** | `<name>/<version>/` 子树,所有形态字节级一致的部分 |
| **envelope** | app pack 根额外追加的 `bin/`、`boot/`、`chandler-runtime/`、`.chandler/pack.ss` |
| **versioned package** | `(name, version, mt)` 三元组对应的实例,即一个 `<name>/<version>/` 目录 |
| **mt** | Chez machine-type,如 `ta6le`(threaded x86_64 LE)、`a6le`(ARM64 LE) |
| **resolve** | 从 manifest 计算 manifest.lock 的过程 |
| **materialize** | 把 lock 里的 dep 落地为文件系统上的 `<name>/<version>/` |
| **activate** | `(chandler setup)` 接管 `(library-directories)` |
| **provenance** | `.chandler/source.ss` 记录的来源(git rev 或 prebuilt URL+hash) |
| **self-contained** | 一个目录不依赖外部环境即可工作(version 自包含、pack 自包含) |

## 10. 设计决策记录

本节列出已经拍板的关键决策,后续不再讨论:

| # | 决策 | 理由 |
|---|------|------|
| D1 | `.chandler/` 进 version 目录(`<name>/<version>/.chandler/`),而非平行树 | 扩展 design 05 的"registry 同居 prefix"到 version 层;原子卸载;pack = tar 子树 |
| D2 | pack = install --prefix + envelope(app pack) | payload 字节级统一;消除重复代码(pack.ss 减 ~41%);prebuilt install 免费获得 |
| D3 | lib 可 pack(Decision 3) | 支持中央仓库 prebuilt 分发;lib pack = payload only,无 envelope |
| D4 | `(chandler setup)` 走 Bundler 模型 | 业界主流(Bundler/Cargo/npm),纯 Scheme 跨平台,共享升级自动生效 |
| D5 | pack bundle chandler-runtime | 自包含,符合 design 09 原则;解决 bootstrap paradox |
| D6 | mt 嵌套(`<name>/<version>/<mt>/`),非复合 key `<version>-<mt>` | ABI-independent 数据共享;`split-pair` 零改;语义清晰 |
| D7 | 不考虑老版本兼容 | 重大架构升级,v2.0 是 breaking change |

## 11. 不在本设计范围

明确**不解决**的问题:

- 远程 registry server(crates.io / hex.pm 那种)—— v2 是 local-only,prebuilt 通过 URL 下载,没有索引 server
- 跨平台 pack(一个 pack 多 mt)—— v2 是 per-mt pack,跨平台由 CI 分别构建
- 自动升级(lock 变化触发 auto install)—— 拒绝 Bundler 的 auto-upgrade,显式 install
- 内容寻址存储(content-addressed store,如 Nix)—— 接受 v2 重复,Scheme 库小,disk 便宜
- Chez library version annotation(`(library (foo (1 0 0)) ...)`)—— 不用,版本完全在 Chandler 层

## 相关文档

- [README.md](README.md) — 所有设计文档的索引
- 后续 01-13 各专项设计(见 README)
