# Chandler v2 实施任务

> 本文档跟踪 Chandler v2(Unified Layout)的实施进度。设计文档见 [designs/](designs/),核心模型见 [designs/00-design-principles.md](designs/00-design-principles.md)。
>
> v2 是 **breaking change**(决策 D7),不考虑老版本兼容。每个 milestone 内部任务并行,跨 milestone 严格按顺序。

## 实施阶段划分

> v2 分两个阶段实施。**Phase 1 是当前焦点**,聚焦"pack 重构闭环"——把 pack 做对(payload 字节级统一 + `(chandler setup)` 启动钩子),**不依赖中央仓库**。Phase 2 引入中央仓库的多版本 install 和 prebuilt 分发。

### Phase 1 — pack 重构闭环(当前焦点)

自包含,pack 解开即用,不需要 `~/.local/share/chez/` 中央仓库。

| Milestone | 主题 | 状态 |
|-----------|------|------|
| **v2.0** | 基础数据层 + 新 layout(schema 升级,无运行时影响) | ⏳ 待开工 |
| **v2.1-partial** | `install --prefix=<dir>` 能力(pack 内部用,**不含** `install --global`) | ⏳ 待开工 |
| **v2.2** | `(chandler setup)` + launchers + runtime-paths | ⏳ 待开工 |
| **v2.3** | pack = install --prefix + envelope + bundle chandler-runtime | ⏳ 待开工 |

Phase 1 验收:dev 模式不变 + `chandler pack` 产出 nested layout 自包含 pack + pack 解开能跑。

### Phase 2 — 中央仓库 + 分发(暂缓)

依赖中央仓库 `~/.local/share/chez/` 或远程分发基础设施。

| Milestone | 主题 | 状态 |
|-----------|------|------|
| **v2.1-global** | `install --global` / `uninstall --version` / `doctor --global`(中央仓库多版本) | ⏸️ 暂缓 |
| **v2.4** | prebuilt 远程分发 + `--allow-prebuilt-native` + mt-gate | ⏸️ 暂缓 |
| **v2.5** | lib pack + CLI 全套 + skiff-demo 迁移验证 | ⏸️ 暂缓 |

Phase 2 前置:Phase 1 全部完成 + 中央仓库设计重新评估实际需求。

---

---

## v2.0 — 基础数据层 + 新 layout `[Phase 1]`

> 设计:[01-manifest-lock](designs/01-manifest-lock.md)、[02-resolution](designs/02-resolution.md)、[03-central-repo](designs/03-central-repo.md)
>
> 目标:把数据格式和 layout 函数从 v1 flat 升级到 v2 nested,**不破坏现有 install/build 的可运行性**(只是 schema 升级,流水线适配留给 v2.1)。

### 数据 schema

- [ ] **T1.1** 扩展 `manifest.ss` schema:加 `(source (prebuilt ...))` 字段定义(仅定义,实现留 v2.4)
  - 关联:[01-manifest-lock §2.2 prebuilt source kind BNF](designs/01-manifest-lock.md)
  - 文件:`chandler/manifest.ss`(reader)、`chandler/cli/commands.ss`(add 命令)
- [ ] **T1.2** 扩展 `manifest.lock` schema:加 `provenance` 字段(记录 git rev 或 prebuilt url+sha256)
  - 关联:[01-manifest-lock §3 lock schema](designs/01-manifest-lock.md)
  - 文件:`chandler/lock.ss`(`locked-dep` record 加字段、`lock->datum`/`datum->lock`)
- [ ] **T1.3** 加 `<name>/<version>/.chandler/source.ss` schema(name, version, mt, source 类型, provenance)
  - 关联:[01-manifest-lock §4 source.ss](designs/01-manifest-lock.md)、[I5 不变量](designs/00-design-principles.md#5-五条不变量)
- [ ] **T1.4** 加 `<name>/<version>/.chandler/registry.ss` schema(name, version, mt, exports, files+sha256, installed-at, source)
  - 关联:[03-central-repo §3 混合 registry](designs/03-central-repo.md)
- [ ] **T1.5** 加 `<root>/.chandler/format.ss`(= 2) 和 `<root>/.chandler/registry/index.ss` schema
  - 关联:[03-central-repo §3.2 顶层 derived index](designs/03-central-repo.md)

### Layout 函数

- [ ] **T1.6** 改造 `split-pair`:接受 prefix 返回 `(<prefix>/src . <prefix>/<mt>)`,**保持不变**(已是核心不变)
  - 文件:`chandler/layout.ss`
  - 验证:所有现有调用方仍 work
- [ ] **T1.7** 新增 `version-root`:`(version-root root name version)` → `<root>/<name>/<version>/`
  - 文件:`chandler/layout.ss`
- [ ] **T1.8** 改造 `vendor-dir`:dev 模式**不变**(仍 `_vendor/<name>/`),但加 `versioned-vendor-dir` 用于 install 路径
  - 文件:`chandler/install.ss`、`chandler/layout.ss`
- [ ] **T1.9** 新增 `prefix-resource-dir` 在新 layout 下验证仍 work:`(<name>/<version>/src/resources/<libpath>/)`
  - 关联:[09-runtime-paths §N+1 算法](designs/09-runtime-paths.md)
  - 文件:`chandler/layout.ss`

### Resolution

- [ ] **T1.10** `resolve.ss` 加 prebuilt source 的 stub 识别(不真正 fetch,只在 chosen 记录 source kind)
  - 关联:[02-resolution §prebuilt 路径](designs/02-resolution.md)
  - 文件:`chandler/resolve.ss`(`rspec`/`rentry` record 加 source-kind 字段)
- [ ] **T1.11** 多版本语义文档化:每个 app 的 lock 独立 resolve(无代码改动,只在 resolve.ss 加注释 + 测试)
  - 关联:[02-resolution §多版本语义](designs/02-resolution.md)

### v2.0 验收

- [ ] 全部测试通过(纯 Chez + skiff 两运行时)
- [ ] 现有 dev 模式仍 work(`chandler run` 不变)
- [ ] schema 升级不影响 build/deps/run(只影响 install,pending v2.1)

---

## v2.1 — install 流水线重构 `[Phase 1: T2.1-T2.6 install --prefix | Phase 2: T2.7-T2.10 global install]`

> 设计:[04-install](designs/04-install.md)、[03-central-repo](designs/03-central-repo.md)
>
> 目标:install 从 v1 flat merge 改为 v2 nested materialize。这是第一个**对用户可见**的破坏性变化。
>
> **前置:** v2.0 完成

### Install pipeline

- [ ] **T2.1** 重写 `install-global` 适配 nested layout:每个 dep 装到 `<prefix>/<name>/<version>/{src,<mt>}/`
  - 关联:[04-install §流水线](designs/04-install.md)、[03-central-repo §布局](designs/03-central-repo.md)
  - 文件:`chandler/registry.ss`(替换 `enumerate-lib`)
- [ ] **T2.2** 改造 `merge-lib-to-global!`:不再 flatten,改为 per-dep 写入各自 version 目录
  - 文件:`chandler/cli/commands.ss`
- [ ] **T2.3** 实现 staging → promote 事务,适配 nested staging path:`<root>/.chandler/staging/<name>-<version>-<mt>/`
  - 关联:[04-install §失败回滚](designs/04-install.md)
  - 文件:`chandler/registry.ss`
- [ ] **T2.4** 写 per-version `registry.ss`(含 sha256 files 清单)+ 触发 index.ss 重建
  - 关联:[03-central-repo §3 混合 registry](designs/03-central-repo.md)
- [ ] **T2.5** 实现 `index.ss` 重建算法(扫各 `<name>/<version>/.chandler/registry.ss`)和 lazy rebuild(mtime check)
  - 关联:[03-central-repo §3.2](designs/03-central-repo.md)

### Install 选项

- [ ] **T2.6** 加 `install --prefix=<dir>` 选项:跟 install-global 同流水线,只是 prefix 改为自定义(为 v2.3 pack 铺路)
  - 文件:`chandler/cli/commands.ss`
- [ ] **T2.7** 加 `install <pack.tar.gz>`:从 pack 解包安装(prebuilt install,只解 `<name>/<version>/` 子树)
  - 关联:[04-install §prebuilt install](designs/04-install.md)、[06-prebuilt](designs/06-prebuilt.md)
  - **注意:** tarball 解包前必须做 path traversal 防护([12-security](designs/12-security.md))

### Uninstall / doctor

- [ ] **T2.8** 改造 `uninstall --name=<n>`:`rm -rf <prefix>/<name>/<version>/` + 重建 index
- [ ] **T2.9** 加 `uninstall --name=<n> --version=<v>`:精确到版本卸载
- [ ] **T2.10** 改造 `doctor --global`:扫 per-version registry.ss 校验 sha256,检测篡改

### v2.1 验收

- [ ] `chandler install --global` 把 app+deps 装到 nested layout
- [ ] `chandler list --global` 列出所有 name+version+mt 组合
- [ ] `ch uninstall --name=X --version=Y` 精确卸载
- [ ] **此阶段下 install 后的 app 暂时跑不起来**(等 v2.2 launcher/setup)

---

## v2.2 — 运行时层(setup + launchers + runtime-paths) `[Phase 1]`

> 设计:[07-chandler-setup](designs/07-chandler-setup.md)、[08-launchers](designs/08-launchers.md)、[09-runtime-paths](designs/09-runtime-paths.md)
>
> 目标:让 v2.1 装好的 app 能跑起来。`(chandler setup)` 是核心。
>
> **前置:** v2.1 完成

### (chandler setup) 库

- [ ] **T3.1** 新建 `(chandler setup)` 库:副作用库,import 即读 lock 重写 library-directories
  - 关联:[07-chandler-setup §4 步流程](designs/07-chandler-setup.md)
  - 文件:`chandler/setup.ss`(新)、加进 chandler umbrella
- [ ] **T3.2** 实现路径反推:从 `(car (command-line))` → `<name>/<version>/.chandler/`
  - 关联:[07-chandler-setup §路径反推](designs/07-chandler-setup.md)
- [ ] **T3.3** 实现错误处理:lock 缺失 → 报错指明 `chandler install`;版本漂移 → WARN + exit(reject auto-upgrade)
  - 关联:[07-chandler-setup §错误处理](designs/07-chandler-setup.md)、[00 §11 拒绝 auto-upgrade](designs/00-design-principles.md)

### run.sps 生成

- [ ] **T3.4** 改造 `write-app-launcher!` 生成的 run.sps:加 `(import (chandler setup))` 一行
  - 关联:[07-chandler-setup §run.sps 模板](designs/07-chandler-setup.md)
  - 文件:`chandler/cli/commands.ss`、`chandler/registry.ss`

### 启动器生成

- [ ] **T3.5** 改造 install 模式 sh launcher:`--libdirs` 指向**系统 chandler-runtime prefix**(让 setup 可见)
  - 关联:[08-launchers §install 启动器模板](designs/08-launchers.md)
  - 文件:`chandler/cli/commands.ss`(`app-launcher-sh`/`app-launcher-ps1`)
- [ ] **T3.6** 设计 chandler-runtime 的固定位置(install 模式):`<CHANDLER_HOME>/src` + `<CHANDLER_HOME>/<mt>`(沿用现状)
  - 关联:[08-launchers §bootstrap paradox](designs/08-launchers.md)

### runtime-paths 适配

- [ ] **T3.7** 验证 `runtime-paths.ss` 的 N+1 fallback 在新 layout 仍 work(无代码改动,加测试)
  - 关联:[09-runtime-paths §N+1 算法](designs/09-runtime-paths.md)
- [ ] **T3.8** 验证 `scan-library-directories` 在新 layout work(primary 路径,无代码改动)
- [ ] **T3.9** 验证 `native-load-paths` 在新 layout work(per-lib native 落点不变,I4)

### v2.2 验收

- [ ] v2.1 装好的 app 通过启动器跑起来
- [ ] setup 读 lock 正确构造 library-directories
- [ ] 资源定位 + native 加载正常
- [ ] **此阶段 dev 模式仍走老路**(chandler run 实时算,不用 setup)

---

## v2.3 — pack 重构(install --prefix + envelope) `[Phase 1]`

> 设计:[05-pack](designs/05-pack.md)、[08-launchers §pack 启动器](designs/08-launchers.md)
>
> 目标:pack 改为 `install --prefix=<tmp>` + envelope。pack.ss 从 ~1100 行减到 ~300 行。
>
> **前置:** v2.2 完成

### pack pipeline 重构

- [ ] **T4.1** 新增 `chandler pack` 主流程:resolve closure → `install --prefix=<tmp>` → copy envelope → tar
  - 关联:[05-pack §流水线](designs/05-pack.md)
  - 文件:`chandler/pack.ss`(基本重写)
- [ ] **T4.2** envelope copy:`bin/<app>` + `bin/<app>.ps1`(用 v2.2 的 launcher 模板)
- [ ] **T4.3** envelope copy:`bin/<mt>/<runtime>`(bundled skiff/scheme)
- [ ] **T4.4** envelope copy:`boot/<mt>/*.boot`
- [ ] **T4.5** envelope copy:`chandler-runtime/{src,<mt>}/`(D5,bundle chandler runtime 解决 bootstrap paradox)
  - 关联:[05-pack §bootstrap paradox](designs/05-pack.md)、[08-launchers](designs/08-launchers.md)
- [ ] **T4.6** 写 `.chandler/pack.ss` pack 元数据(entry-app, entry-version, mts, runtime, chandler-version)

### pack launcher

- [ ] **T4.7** pack 模式 sh launcher:`--libdirs` 指向 **bundled** chandler-runtime(`<pack-root>/chandler-runtime/src::<pack-root>/chandler-runtime/<mt>`)
  - 关联:[08-launchers §pack 启动器](designs/08-launchers.md)
  - 文件:`chandler/pack.ss`

### pack verify

- [ ] **T4.8** 重写 `verify-pack`:校验 `.chandler/pack.ss` + per-version `.chandler/registry.ss` 的 sha256
  - 关联:[05-pack §verify](designs/05-pack.md)

### 旧 pack 清理

- [ ] **T4.9** 删除 pack.ss 中老的 flat 布局代码(copy-obj-tree!/copy-dep-trees!/bootstrap-source 等)
- [ ] **T4.10** 删除 design 09 提到的旧概念:`chandler-setup.ss`、`APP_ROOT` 资源路径(已被 setup 取代)

### v2.3 验收

- [ ] `chandler pack` 产出 nested layout 的 pack
- [ ] pack 解开后能直接跑(`bin/<app>` 启动)
- [ ] pack tarball 解包到中央仓库 → 字节级一致 install(prebuilt install 流水线验证)
- [ ] pack.ss 行数 < 400

---

## v2.4 — prebuilt 分发 + native 安全 `[Phase 2 — 暂缓]`

> 设计:[06-prebuilt](designs/06-prebuilt.md)、[12-security](designs/12-security.md)、[01-manifest-lock §prebuilt source](designs/01-manifest-lock.md)
>
> 目标:实现 prebuilt source 完整路径 + 安全 flag。
>
> **前置:** v2.3 完成

### prebuilt resolve

- [ ] **T5.1** resolve 时识别 `(source (prebuilt ...))`,选本机 mt 条目
  - 关联:[02-resolution §prebuilt resolve](designs/02-resolution.md)
- [ ] **T5.2** mt-gate:本机 mt 不在 prebuilt mt 列表 → 失败,提示 git-fallback 或报错
  - 关联:[06-prebuilt §mt-gate](designs/06-prebuilt.md)

### prebuilt fetch + materialize

- [ ] **T5.3** prebuilt fetch:HTTP 下载 tarball
  - 文件:`chandler/fetch.ss`(扩展)
- [ ] **T5.4** sha256 校验下载内容
- [ ] **T5.5** prebuilt materialize:解包 tarball 到 `<name>/<version>/`(走 v2.1 staging → promote)
- [ ] **T5.6** 写 `.chandler/source.ss` 记录 `(prebuilt (url ...) (sha256 ...))`

### 安全 flag

- [ ] **T5.7** 加 `--allow-prebuilt-native` flag:prebuilt 含 native 时默认拒绝
  - 关联:[12-security §prebuilt native](designs/12-security.md)、[06-prebuilt §native 安全](designs/06-prebuilt.md)
  - 文件:`chandler/cli/commands.ss`
- [ ] **T5.8** 实现官方 mirror 白名单(签名校验占位,v2 不强制签名)
- [ ] **T5.9** tarball 解包前的 path traversal 防护(tar 炸弹)

### v2.4 验收

- [ ] 一个库(http)发布 prebuilt,另一个项目(myapp)用 prebuilt install
- [ ] prebuilt 装的库跟 git clone+build 装的库**字节级一致**(只 source.ss 不同)
- [ ] 含 native 的 prebuilt 默认拒绝,`--allow-prebuilt-native` 通过

---

## v2.5 — lib pack + CLI 完善 + 迁移验证 `[Phase 2 — 暂缓]`

> 设计:[05-pack §lib pack](designs/05-pack.md)、[11-cli](designs/11-cli.md)、[10-dev-mode](designs/10-dev-mode.md)
>
> 目标:lib pack、CLI 全套、用 skiff-demo 验证端到端。
>
> **前置:** v2.4 完成

### lib pack

- [ ] **T6.1** 实现 `chandler pack --lib <name>`:无 envelope,只有 payload,`.chandler/pack.ss` 写 `(lib ...)`
  - 关联:[05-pack §lib pack](designs/05-pack.md)
- [ ] **T6.2** lib pack 的 source kind 反向:manifest 里 `(source (prebuilt <url>))` 直接拉 lib pack

### CLI 完善

- [ ] **T6.3** 完善 `chandler add --prebuilt <url> [--mt <mt>]`(11-cli §命令一览)
- [ ] **T6.4** 完善 `chandler list` / `tree` 显示新 layout(name+version+mt)
- [ ] **T6.5** 完善帮助文本 + `--version` 输出格式

### dev mode 微调

- [ ] **T6.6** dev 模式的全局兜底从单对 → list of per-version pairs(扫中央仓库 index.ss)
  - 关联:[10-dev-mode §库定位](designs/10-dev-mode.md)
- [ ] **T6.7** 验证 dev 模式下 `(import (chandler setup))` **不需要**(chandler run 实时算)

### 迁移验证

- [ ] **T6.8** skiff-demo 端到端迁移:init → add → deps → build → install → run → pack → 解包跑
- [ ] **T6.9** 性能基准:install/build/run/pack 各阶段时间
- [ ] **T6.10** 文档完善:README、用户指南

### v2.5 验收(= v2 整体验收)

- [ ] 全部 milestone 通过
- [ ] 三运行时(scheme/petite/skiff)全绿
- [ ] skiff-demo 完整流程跑通
- [ ] designs/ 文档与实现一致

---

## 决策记录

| # | 决策 | 文档参考 |
|---|------|---------|
| D1 | `.chandler/` 进 version 目录 | [00 §10](designs/00-design-principles.md#10-设计决策记录) |
| D2 | pack = install --prefix + envelope | [05-pack](designs/05-pack.md) |
| D3 | lib 可 pack | [05-pack §lib pack](designs/05-pack.md) |
| D4 | `(chandler setup)` Bundler 模型 | [07-chandler-setup](designs/07-chandler-setup.md) |
| D5 | pack bundle chandler-runtime | [08-launchers §bootstrap paradox](designs/08-launchers.md) |
| D6 | mt 嵌套(`<version>/<mt>/`),非复合 key | [00 §4.1](designs/00-design-principles.md) |
| D7 | 不考虑老版本兼容 | [00 §10](designs/00-design-principles.md) |

## 备注

- 每个 milestone 内部任务**可并行**,跨 milestone 必须顺序
- T1.x(schema)和 T2.x(pipeline)之间,v2.0 完成后 v2.1 才能开工
- v2.2(setup/launchers)依赖 v2.1 的 install 结果
- v2.3(pack 重构)依赖 v2.2 的 launcher 模板
- v2.4(prebuilt)依赖 v2.3 的 pack 流水线
- v2.5 是收尾,所有前置完成才能开工

工作量估计(粗):
- v2.0: 2-3 天(schema + layout)
- v2.1: 2-3 天(install pipeline 重构)
- v2.2: 2-3 天(setup + launchers)
- v2.3: 3-4 天(pack 重构)
- v2.4: 2-3 天(prebuilt + 安全)
- v2.5: 2-3 天(lib pack + 收尾)
- **总计: 13-19 天**
