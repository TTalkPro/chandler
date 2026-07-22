# 12 — chandler 分层:dev-time 工具 + runtime 公共基础设施

> 状态:**设计中(2026-07-23)**,N 标号见 §8。
> 前置:[11](11-runtime-paths.md)(runtime-paths 是本架构的**第一实例**——公共能力进 lib 的最小样板)· [09](09-pack.md)(pack producer,lib/app 进 pack 的搬运路径)· [10](10-deploy-loader.md)(deploy loader,lib 无 bootstrap 是本设计的根因)· [02](02-manifest-lock-spec.md)(manifest schema,本设计扩展 `(runtime-subset …)`)· [06](06-runtime-compat.md)(双 runtime 兼容约束)· [07](07-bake-integration.md)(bake 已跨用 `(chandler lock/registry/layout/sexp/util/fs)`,本设计的**前例**)。
> 上游规范:[chez-skiff-library-layout.md](../chez-skiff-library-layout.md) · [chez-chandler-git-lib-manager-design.md](../chez-chandler-git-lib-manager-design.md)。

## 一句话目标

把 chandler 内部组织为 **dev-time 工具集**(只在开发机用,负责 fetch/install/resolve/lock/build/pack/activate/CLI)与 **runtime 公共基础设施**(随 lib/app 一同进 pack,负责 hash/version/util/fs/sexp/layout/runtime 探测/runtime-paths)两层;**所有 chandler 管理的项目(app + lib)强制依赖 chandler runtime**,通过 `(import (chandler base))` 一行拿到(资源定位、hash、版本匹配、运行时探测等)统一公共能力。这彻底解决 [10](10-deploy-loader.md) §"lib 无 bootstrap" 的根本问题:lib 不需要 bootstrap,`(import (chandler base))` 拿到 `(chandler runtime-paths)` 与 `(chandler hash)` 后,资源定位/版本自检/完整性与应用完全同源。chandler 保持单一 git repo;区分靠 **manifest 字段**声明子库归属,install/pack 据此决定复制范围,而不是拆 repo。

## 1. 背景:为什么 chandler 需要分层

今天 chandler 是一个**纯 dev-time 工具**。run/install/pack/activate 那一整套在生产环境(pack 部署态)不在场,这是 [08](08-bootstrap-security.md) 的有意决定(部署机不依赖 chandler)。但这件事留了一个缺口,以 [11](11-runtime-paths.md) 的根因为最尖锐的体现:

| 场景 | 期望 | 现状 |
|---|---|---|
| lib 附 schema/template/fixture | 装到稳定位置,运行时定位得到 | bake install 搬 source、pack 搬 `.so`,资源**没有稳定落点** |
| lib 校验自己被加载的版本与声明一致 | 简单的 `(version-match? range actual)` | 没有 `(chandler version)` 公共消费面,lib 各自重写 |
| lib 算 hash 做内容寻址 | `(sha256-file path)` | 没有 `(chandler hash)` 公共消费面,lib 各自造 |
| lib 自检当前运行时(skiff / chez) | `(current-runtime)` | dev 项目用 `(activate)` 拿到;但 lib 没 `(activate)` |
| lib 知道自己被装在哪里 | `(lib-resource-path …)` | 没有 [11](11-runtime-paths.md) 之前彻底没有 |

任意一行,现行选项是:**在 lib 内部复制一个缩微实现**。结果是 (a) 代码重复,(b) 与 chandler dev-time 的版本漂移,[10](10-deploy-loader.md) §"为什么归 chandler" 表格里 "skiff 路径与 chandler 路径事实上漂移" 的同款诊断在 lib 侧更严重。

[11](11-runtime-paths.md) 引入 `(chandler runtime-paths)` 是这个方向上的**第一个实例**——它不是 runtime-paths 一个库的故事,而是**架构原则**:chandler 必须区分「dev-time 用」与「runtime 公共能力」,后者必须能跟 lib/app 一起进 pack。

### 1.1 与其他生态的对照

| 生态 | 等价分层 | 解决的本问题 |
|---|---|---|
| Python | stdlib + pip | 标准库随 binary wheel 走,用户不重写 `os.path` |
| Node | core modules + npm | `fs` / `path` 进 deploy,应用不另装 |
| Elixir | OTP + Mix | `:code.priv_dir/1` + `Logger` 随 release 走 |
| Rust | std + cargo | `std::path` 与 build-time `cargo` 区分清楚 |
| **chez/chandler(本设计)** | **(chandler base) + chandler CLI** | lib 公共能力与 dev 工具严格分离 |

python `importlib.resources` 与 elixir `:code.priv_dir/1` 是 [11](11-runtime-paths.md) §12 已对照过的最直接先例;本设计把这种"公共能力纳入运行时"从单点(runtime-paths)提升到架构层。

## 2. 两层模型

| 层 | 内容 | 部署态 | 谁用 |
|---|---|---|---|
| **dev-time 工具集** | `chandler` umbrella 全部 API + CLI/install/pack/build/fetch/resolve/lock/manifest/registry/activate | **不在场**——部署机不装 dev 工具 | 仅开发机跑 `chandler …` 时 |
| **runtime 公共基础设施** | `(chandler base)` umbrella re-export 的子库(runtime-paths/hash/version/util/fs/sexp/layout/runtime 探测等) | **随 lib/app 进 pack**——`<pack>/lib/<mt>/chandler/<sub>.so` | 所有 chandler 管理的 lib/app 在运行时 |
| **共享层** | runtime 子库**也**被 dev-time 工具内部使用(单一实现,避免双份) | 进 pack 也进 dev 安装 | 双方 |

`runtime-paths` 已经在 [11](11-runtime-paths.md) §1 表里出现,本设计把它纳入 umbrella。[09](09-pack.md) §"包布局" 让 `<pack>/lib/<mt>/` 已包含所有依赖的 `.so` —— chandler 作为 transitive dep 时,其 runtime 子库的 `.so` 进 pack 是 lock 驱动的副产物,**不需要新机制**,只需要 manifest 声明让 install 知道哪些要复制。

## 3. 子库归类(基于现有 17 个子库)

下表覆盖 chandler 当前全部子库 + [11](11-runtime-paths.md) 新增的 `runtime-paths`。归类基准:

- **runtime**:零依赖或仅依赖其他 runtime 子库、不引 dev-tool 子库、写在 `(chandler base)` umbrella 里进 pack。
- **dev-only**:CLI/install/pack/build 等只在开发机跑的工具,pack 后**不**应使用。
- **shared(runtime-safe)**:表面看 dev 用得多,但实现仅依赖 runtime 子库、runtime 引用也不破坏语义,故两者都可 import。

| 子库 | 归类 | 理由 | 进 pack? |
|---|---|---|---|
| `runtime-paths.ss` | **runtime** | [11](11-runtime-paths.md) 新增,lib/app 资源定位 | 是 |
| `hash.ss` | **runtime** | 纯 Scheme SHA-256,内容寻址通用底座 | 是 |
| `version.ss` | **runtime** | 版本区间匹配,lib 自检自己依赖 | 是 |
| `util.ss` | **runtime** | 字符串/格式/列表工具,通用基础 | 是 |
| `fs.ss` | **runtime** | 文件系统操作,通用基础 | 是 |
| `sexp.ss` | **runtime** | 安全 read/pretty-print,清单解析通用 | 是 |
| `layout.ss` | **runtime** | `mt` / `so-ext` / 路径常量,通用 | 是 |
| `runtime.ss` | **runtime** | `current-runtime` / `skiff-version` / `verify-runtime!` | 是 |
| `proc.ss` | **shared(runtime-safe)** | 子进程封装;dev 调 git/bake,lib 也可能(`run-capture`);依赖 `util`+`fs`,无 dev-only 反向依赖 | 进共享段 |
| `activate.ss` | **dev-only** | 挂 `library-directories` + native 兜底,本身是 dev 装机面 | 否 |
| `install.ss` | **dev-only** | 协调 fetch/vendor/lib/registry | 否 |
| `fetch.ss` | **dev-only** | git fetch | 否 |
| `resolve.ss` | **dev-only** | 依赖解析、冲突规则 | 否 |
| `lock.ss` | **dev-only** | lock 读写 | 否 |
| `manifest.ss` | **dev-only** | manifest 解析 | 否 |
| `build.ss` | **dev-only** | 编译协调(生成 recipe 跑 bake) | 否 |
| `pack.ss` | **dev-only** | pack 组装 | 否 |
| `registry.ss` | **dev-only** | 全局注册表 | 否 |
| `cli/*` | **dev-only** | CLI 入口 | 否 |

**`proc.ss` 边界**:**暂划 shared**,理由是 lib 调外部命令(`curl`、`ssh-keygen`、外部 codegen)是合法用例;且 `proc` 仅依赖 `(util)` + `(fs)`,无 dev-only 反向依赖,**没有技术阻碍**进 runtime。代价是包略微变大,收益是 lib 不用自带一份子进程封装。是否正式归 runtime 留 §11 open question;**短期按 shared 实现,正式打包时一次复制不 filter**。

### 3.1 闭包要求

runtime 子库**只能** import 其他 runtime 子库(或 (chezscheme))。例:`activation.ss` 显式 import `(chandler install)` 与 `(chandler manifest)`(见 [chandler/activate.ss](chandler/activate.ss) 第 19-21 行),所以它**不能**进 runtime umbrella。判定简单:**runtime umbrella 的每个成员的 import 闭包必须全部 ∈ runtime 子库集合**。`proc.ss` 已满足(只 import `util` + `fs`)。`runtime.ss` 也满足(只 import `util` + `version`)。

### 3.2 bake 已跨用的事实

[07 §5](07-bake-integration.md) 表格 6 个共享库都进 chandler 单 git repo,全部归 runtime(util/fs/lock/registry/layout/sexp)。这证明两件事:

1. chandler 单一 repo 内"部分子库被外部工具复用"已在生产中跑(`recipe.ss` 第 8 行注释同款)。
2. 跨工具共享必然要求 **runtime-safe 约束**(bake 自身可能成为 bootstrap 依赖,等同 lib)。

本设计把这条约束从"bake 复用的 6 个"扩展到"所有 lib/app 都能用 runtime subset"。

## 4. 物理组织:单 repo + 子集 umbrella

### 4.1 不拆 repo

**不**把 chandler 拆成 `chandler-dev` + `chandler-runtime` 两个 git 仓库。原因:

| 拆开 | 代价 |
|---|---|
| 版本对齐成本 | dev 与 runtime 要 atomic bump,跨 repo 漂移 |
| PR 协调 | runtime 改 API 时 dev 同步改,atom commit 落不下来 |
| 编译图分裂 | bake recipe、布局规范、CI 全部要双份 |
| 历史可读性 | 单一仓库的 git blame 跨子库,双 repo 失去 |

判据:**子库逻辑归类 ≠ 物理分仓**。所有生态对照都是 manifest-level 声明,不是 repo-level 拆分(Go 的 `internal/`、Rust 的 `[dev-dependencies]` 都是同仓机制)。

### 4.2 不动文件位置

**不**把 `chandler/<name>.ss` 移到 `chandler/dev/<name>.ss` 与 `chandler/runtime/<name>.ss` 分目录。理由:

- 现有 libref(`(chandler hash)` 等)已稳定,移动会产生 break 性 rename。
- 仓库根目录的扁平度与 [布局规范](../chez-skiff-library-layout.md) 的"仓库根 = 搜索根"约定一致。
- 归类由 manifest 字段声明,不由文件位置暗示。

### 4.3 新 umbrella:`(chandler base)`

当前 `chandler.ss` 是 dev 入口(`(export activate …)`),不外加"。现在引入 **`(library (chandler base))`** 作为 **runtime subset umbrella**,re-export 所有 runtime-safe 子库的公共 API:

```scheme
(library (chandler base)
  (export
    ;; runtime-paths (from design 11)
    app-root app-resource-path find-app-resource-path
    lib-resource-path find-lib-resource-path
    define-resource-path-resolver
    ;; hash
    sha256-bytevector sha256-string sha256-file
    ;; version
    version-match? version-parse version-range
    ;; util
    string-join plural alist-ref ignore-errors
    ;; fs
    path-build path-parent join-paths file-exists?* directory-list*
    ;; sexp
    read-data pretty-print-datum
    ;; layout
    native-collector-path so-ext mt-binding
    ;; runtime detector
    current-runtime runtime-version chez-version-string verify-runtime!
    ;; proc (shared; lib 调外部命令)
    run-capture run-check run-status shell-quote)
  (import (chezscheme)
          (chandler runtime-paths)
          (chandler hash)
          (chandler version)
          (chandler util)
          (chandler fs)
          (chandler sexp)
          (chandler layout)
          (chandler runtime)
          (chandler proc)))
```

lib 写 `(import (chandler base))` 一行拿到全部 runtime 公共能力。**`(chandler base)` 名字选定理由**:短、清晰、与 [11](11-runtime-paths.md) 收尾的 `(chandler runtime-paths)` 形成 "base" vs "领域的路径 API" 分层;且**不**与现有 `(chandler runtime)` 冲突,见下。

> **caveat — export 列表是提议形态**:上表的具体 symbol(`string-join`、`path-build`、`native-collector-path` 等)是设计期示意,N2 实施时必须对照各子库实际的 `(export …)` 列表校准(如 `(chandler util)` 实际 export 的是 `string-split`/`string-trim`/`string-prefix?` 等,`(chandler fs)` 实际 export 的是 `parent-dir`/`base-name`/`path-join*` 等)。`(chandler base)` 的 export 是各子库 export 的**并集**,不是重新设计;N2 时枚举每个 runtime subset 子库的 export 拼接即可。

### 4.4 命名冲突:`(chandler runtime)` 是 skiff/chez 探测器

当前 `chandler/runtime.ss` 第 7 行 `(library (chandler runtime))` 导出 `current-runtime` / `runtime-version` / `chez-version-string` / `verify-runtime!` 等**运行时探测** API。**新 umbrella 不能也叫 `(chandler runtime)`**,否则语义冲突:

- "import (chandler runtime)" — 旧意:探测器
- "import (chandler runtime)" — 若改作 umbrella:整套公共设施

保留 `(chandler runtime)` 给探测器(与 [09](10-deploy-loader.md) §3 `bootstrap-source` 复用 `current-runtime` / `skiff-version-string` 一致),新 umbrella 叫 `(chandler base)`。

### 4.5 既有 `chandler.ss`(dev umbrella)继续

dev 入口 `(library (chandler))` 保留 `activate` / `current-runtime` / `chandler-version` 全部 dev API,**加** `(import (chandler base))` 让 dev 工具也能用 runtime subset。这样 `activate` 实现里原本直接用 `(chandler fs)` / `(chandler manifest)` 等显式 import 可保持不变(`(chandler base)` re-export 已覆盖),dev 内部代码不改。

## 5. 强制依赖机制

### 5.1 三档强度

| 档 | 机制 | 阻塞? | 适用 |
|---|---|---|---|
| **soft(默认)** | `chandler init` 生成的 manifest 模板默认含 `(deps (chandler "^<current>"))` | 不阻塞 | 99% 项目 |
| **diagnostic** | `chandler install` 检测无 chandler 依赖则 stderr warning | 不阻塞 | 提醒忘记加 |
| **hard(可选)** | `chandler install --strict` 拒绝无 chandler 依赖 | 阻塞 | CI / 严格仓库 |

**推荐组合**:soft + diagnostic,不引入 hard 默认(理由见 §5.2)。

### 5.2 自举的例外

**chandler 自身的 manifest 必须保持零 deps**(见 [manifest.ss](../manifest.ss))。理由是循环依赖:`chandler install` 自己 → 谁提供 chandler runtime?答:dev 机一次性 `bake install` 装完整 chandler(包含 dev + runtime),自举 OK。运行时(`chandler run` 期间)chandler 自己也**不** import `(chandler base)`——它本身**就是**`(chandler base)` 的来源。

此例外在 `chandler init` 模板里**不加**——chandler 自身是顶层工具,不是项目。详见 §9 表第一行。

### 5.3 模板注入

`chandler init` 生成的 `manifest.ss` 默认包含:

```scheme
(deps
  (chandler
    (git "https://github.com/skiffos/chandler")   ; 待定 URL
    (version "^<current>"))                       ; 与 chandler 同版本号
  ;;; ← 后续由 `chandler add` 追加
)
```

version caret( `^` )约束表达 [07 §1](#7-版本兼容承诺) 兼容承诺。用户可删;**删了 install 时 warning**。

### 5.4 依赖分支路径

也存在 path 依赖与 git 依赖两种进口路径:`(path "../chandler")` 给 monorepo 开发用,`(git …)` 给跨仓应用用。**两种都接受**,install 时识别 "name 与 chandler 自身一致" 仍走 runtime 路径。

## 6. chandler 自身 manifest:扩展 `(runtime-subset …)`

[02](02-manifest-lock-spec.md) 的 manifest schema 加新字段:

```scheme
(manifest
  (format 1)
  (name "chandler")
  (version "0.2.0")              ; minor bump:runtime subset 是 backward-compat additive
  (chez ">=10.0")
  (srcdir ".")
  ;; 新增:声明 runtime-safe 子库清单
  (runtime-subset
    runtime-paths hash version util fs sexp layout runtime proc)
  (deps))                       ; 仍零 deps,自举例外
```

`runtime-subset` 是子库名(`(chandler runtime-paths)` → `runtime-paths`)的列表。**缺省** = 全部子库均 runtime-safe(只对 chandler 自己这么做合理;其他 lib 应显式声明)。

### 6.1 解析规则

| 规则 | 违反时 |
|---|---|
| 项是 symbol,匹配 `chandler/<name>.ss` 存在 | EX_DATAERR |
| 同一 name 不可重复 | EX_DATAERR |
| 至少 1 项 | warning,但允许(等于全子库) |
| 集合**必须**对 §3 表格的 runtime + shared 子库是超集 | EX_DATAERR,msg 引导添加 |
| 集合**不应**包含 dev-only 子库 | EX_DATAERR,msg 引导移除 |

### 6.2 lock 同步

`manifest.lock` 的 resolved dep 项同步记录标准化后的声明:

```scheme
(chandler
  (source (git "https://github.com/skiffos/chandler"))
  (pin (tag "v0.2.0"))
  (rev "abc123...")
  (srcdir ".")
  (deps ())
  (natives ())
  (runtime-subset (runtime-paths hash version util fs sexp layout runtime proc)))
```

与 [02](02-manifest-lock-spec.md) §2 的 `deps` / `natives` 快照策略一致 —— pack 只读 lock,不重读 dep mutable manifest。M4 同步落地 lock 扩展。

### 6.3 bake install / chandler pack 的两种 mode

| mode | 触发 | 行为 |
|---|---|---|
| **full install** | dev 机 `bake install` 或 `chandler install` | 复制所有 `chandler/<name>.ss` + `.so` |
| **runtime-only install** | pack 时作为 transitive dep | 只复制 `runtime-subset` 声明的子库 |

**短期(M4 落地)**:两种都**全复制**,不 filter。理由:十来个 `.so` 体积小,filter 复杂度不值;先 correctness 后 optimization。**M6 后**:pack 启用 runtime-only filter,lock 已有 `runtime-subset` 字段,直接读。

## 7. 版本兼容承诺

runtime subset 的公共 API 承诺 semver:

| 变更类型 | bump | lib 影响 |
|---|---|---|
| 新增 runtime 子库(如未来加 `(chandler base64)`) | minor | 完全兼容,lib 入口无感 |
| 新增已有子库的 export | minor | 完全兼容 |
| runtime 子库内 API 重新实现(语义不变) | minor | 完全兼容 |
| 删除 runtime 子库 | **major** | break;lib import 失败 |
| 删除已有子库的 export | **major** | break |
| 改运行时 subset 子库归属(dev-only → runtime-only) | minor(major if reverse) | 兼容或 break |

lib 用 `(version "^0.2")` caret 区间自动跟 minor。chandler 升级路径:

- `0.1.x → 0.2.x`:加 `runtime-paths` 与 `base` umbrella,lib 不改即可升级(deps 范围 `^0.1` 自动容纳 `0.2`)。
- `0.x → 1.0`:允许 break,例如删除 `proc.ss` 或重排 `(chandler base)` 的 export 表。
- `0.x → 0.(x+1)` 同步:重排 dev-only 子库、删 `cli/*` 旧命令——**不影响** runtime subset。

这是 [02](02-manifest-lock-spec.md) §1 版本区间语法("^1.2" 不破主版本)的镜像。

## 8. 实施顺序(N 标号,接续 K/L/M)

| # | 内容 |
|---|---|
| N0 | 文档:本设计本身(架构原则 + §3 子库归类表 + §4 命名冲突消解) |
| N1 | **rename** `chandler/runtime.ss` 文件不动 / libref 改为 `(chandler runtime-detector)`;`chandler.ss` dev umbrella 的 `(import (chandler runtime))` 改为 `(import (chandler runtime-detector))`;同时扫所有 dev-time 文件的 `(import (chandler runtime))` 改写 |
| N2 | 新建 `chandler/base.ss` 是 `(library (chandler base))` umbrella,re-export §4.3 列表;`chandler.ss` 加 `(import (chandler base))` 让 dev 工具内部统一用 base |
| N3 | chandler 自身 manifest 加 `(runtime-subset …)` 字段(§6 形态);`manifest.ss` parser 支持;lock 同步 |
| N4 | `chandler init` 生成的 manifest 模板默认含 `(deps (chandler "^<current>"))`(soft 强制,自举例外不动) |
| N5 | `chandler install` 检测无 chandler 依赖时 stderr warning(diagnostic);可选 `--strict` 拒绝 |
| N6 | `bake install` / `chandler pack` 支持 runtime-only install filter(读 lock 的 `runtime-subset`);M4 阶段先全复制,N6 启用 filter |
| N7 | 文档 + skiff-demo 迁移示范:加 chandler dep,用 `(chandler base)` 替代裸 `getenv "APP_ROOT"`、裸 sha256 计算等 |

**依赖序**:

- N1 **必须**先于 N2(rename 后才能加 base,否则 `(chandler runtime)` 既是旧探测器又是新 umbrella 必崩)。
- N3 独立(单独 schema 变更,不动代码)。
- N4 / N5 独立(各自 user-facing 改动)。
- N6 后置(filter 是优化,不影响 correctness)。
- N7 最后(规范全绿后才迁移示范)。

发布门:N0–N5 一组,建立架构;N6–N7 优化 + 文档。

## 9. 失败模式 / 陷阱

| # | 场景 | 期望行为 | 诊断 / 缓解 |
|---|---|---|---|
| 1 | **chandler 自举**(`chandler install` 它自己时) | 不因缺 chandler runtime 依赖而失败 | exception 明确写"self-bootstrap exception";dev 机一次性 `bake install` 装完整 chandler 即可 |
| 2 | lib 用 `(import (chandler base))` 但**没**声明 chandler dep | `chandler install` warning(§5.1 diagnostic);pack 时 lock 缺 chandler → preflight 失败 | 错误信息:"declared importers require runtime-subset, but no chandler dep in manifest.ss — add `(deps (chandler …))`" |
| 3 | runtime 子库内部 import dev-only 子库(如 `install.ss` import `hash.ss`) | 物理复制时**不能**漏 | 全复制或闭包计算;N1 严格按 §3.1 校验每个成员 import 闭包 ∈ runtime ∪ shared |
| 4 | `(chandler runtime)` → `(chandler runtime-detector)` rename 漏改一处 | compile-time 立即报 "library not found" | CI 跑 `grep -rn '(chandler runtime)'` 必须除 `runtime-detector.ss` 内 0 命中 |
| 5 | `(chandler base)` vs `(chandler runtime)` 命名混淆 | 文档与命名保持清晰 | N1 实施时**强制** grep 全仓库 0 处遗留 `(chandler runtime)` libref;命名选定 `(chandler base)` 避免与探测器重名 |
| 6 | chandler major bump break 所有 lib | semver 承诺 + lock 锁版 + deprecation 周期 | 1.0 之前所有 bump 在文档说明;lock 锁 0.x.x 精确,upgrade 显式 |
| 7 | lib 锁的 chandler 版本太老,还没 `runtime-paths` | 运行时 import `(chandler runtime-paths)` 找不到 | 错误清晰包含 libref + chandler 锁版本;引导 upgrade |
| 8 | pack runtime-only filter 失误,删了一个 lib 实际 import 的子库 | pack preflight 检测 import 闭包越界 | 显式报"import (chandler proc) but not in runtime-subset",而非运行时炸 |
| 9 | 双 runtime 下 runtime subset 在 skiff 跑 / stock 跑行为不一致 | 沿用 [06](06-runtime-compat.md) 约束,subsubset 只用 `(chezscheme)` API | CI 矩阵 `petite --libdirs . --program tests/run-subset.sps` 跑 subset 各子库 |
| 10 | pack 包含 dev-only `.so`(浪费空间) | 中期可接受,短期正确性优先 | M4 阶段不必处理;M6 启用 runtime-only filter |
| 11 | lib 声明 chandler dep 但 version 上界过窄(锁了未来 chandler) | version 解析失败 | [03](03-resolution.md) 已有规则;提示 "lock 锁了 N,最近发布 N+1,降上界或 update" |
| 12 | transitive dep 冲突:两个 lib 要不同 chandler major | 走 [03](03-resolution.md) §冲突规则的"fail fast" | 报"transitive conflict: libA needs ^0.2, libB needs ^1.0" |
| 13 | `runtime-subset` 字段声明 dev-only 子库 | install 拒绝 | EX_DATAERR,msg 引导移除 |
| 14 | `runtime-subset` 字段未声明 runtime-范围子库 | install 拒绝 | EX_DATAERR,msg 引导添加 |
| 15 | `chandler init` 生成的 manifest 模板带 chandler dep,user 删后 lib 实际 import `(chandler base)` | install warning;pack 失败(同 #2) | warning 不变,pack hard fail 不变 |
| 16 | chandler 升级到新版本,旧 lock 仍有 runtime-subset 字段(向后兼容) | 旧 lock 缺字段 → 用 runtime-subset 全子库 fallback | 读 lock 时 `runtime-subset` 缺省 = "all chandler/<name>.so",全复制 |
| 17 | skiff 自身 (skiff) lib 想要 import `(chandler base)` | skiff 仍是 runtime;若依赖 chandler runtime 须显式 dep | 与普通 lib 一视同仁;skiff 不豁免 |
| 18 | `(chandler base)` umbrella 的 export 列表与子库不一致(漏/多) | 编译期报"export not defined"或"export not declared" | export 列表 = §4.3 模板;drift 立即 fix |

## 10. 与其他设计的关系

| 文档 | 关系 |
|---|---|
| [11-runtime-paths.md](11-runtime-paths.md) | **第一实例**:`(chandler runtime-paths)` 已经演示"公共能力进 lib"的最小样板;本设计把它提升到架构层,加 hash / version / util / fs / sexp / layout / runtime / proc 同时进 runtime umbrella |
| [09-pack.md](09-pack.md) | pack producer 把 chandler 子库 `.so` 随 lib 进 pack 的搬运路径已就位;N6 启用 runtime-only filter,lock `runtime-subset` 字段驱动 |
| [10-deploy-loader.md](10-deploy-loader.md) | deploy loader 不需要 chandler 在场,但 **lib** 缺公共能力是本设计的根因;`bootstrap.ss` 用 `(import (chandler version))` 已是 dev-time 之外第一个跨进程引用 chandler runtime subset 的实例 |
| [06-runtime-compat.md](06-runtime-compat.md) | runtime subset 必须满足 [06 §2](06-runtime-compat.md) 约束(只用 `(chezscheme)` 可移植子集);`current-runtime` / `skiff-version-string` 探测逻辑直接被 `(chandler base)` re-export |
| [02-manifest-lock-spec.md](02-manifest-lock-spec.md) | M3 扩展 manifest schema:加 `(runtime-subset …)`;lock 同步快照;与 `deps` / `natives` 策略一致 |
| [07-bake-integration.md](07-bake-integration.md) | bake 已跨用 `(chandler lock/registry/layout/sexp/util/fs)`——本设计**前例**;N6 跑通后,bake 与 lib 共享同一 runtime subset,约束自然一致 |
| [08-bootstrap-security.md](08-bootstrap-security.md) | 信任模型不变:清单只 `read` 不求值;`runtime-subset` 是新字段,parser 仍纯数据 |
| [../../skiff/designs/architecture.md](../../skiff/designs/architecture.md) | skiff runtime 是否豁免"强制依赖 chandler runtime"——§11 open question;短期与普通 lib 一视同仁 |
| [../chez-skiff-library-layout.md](../chez-skiff-library-layout.md) | 库布局规范:仓库根 = 搜索根,umbrella 在根;本设计不破坏 |
| [../chez-chandler-git-lib-manager-design.md](../chez-chandler-git-lib-manager-design.md) | 总设计:git-first + manifest-driven;runtime subset 是 manifest 的扩展,无冲突 |

## 11. 开放问题

1. **`proc.ss` 正式归类**:前期 shared 实现,正式打包时是否复制给 lib?Lib 调外部命令是合法用例;但 `proc.ss` 现有 sh quoting 是 POSIX-only,Windows 适配需要 `system` vs `CreateProcess` 改造。短期按 shared 全复制,Windows 跨平台阶段决定是否 runtime。
2. **`(chandler base)` re-export 粒度**:全 re-export 是否过度?例如 `(chandler shell-quote)`(来自 proc)lib 可能用不上却拖进 binary。**全 re-export** 简单,选择性 re-export 要求 lib 写 `(import (chandler proc) (shell-quote))` 反而绕。本设计选全 re-export,半年后看 lib 实际 import 模式再决定。
3. **单进程单 chandler 版本**:Chez 进程内 `library-directories` 同一 libref 只能解析一个版本。两个 lib 各自 dep 不同 chandler major 怎么办?**答:fail fast 早于进程**(lock 解析阶段就报 [#12](#9-失败模式--陷阱)),不试图运行时双版本共存。
4. **skiff 自身是否豁免**:`(skiff)` lib 是运行时本体,可能不需要 `(chandler base)`。**短期**:与普通 lib 一视同仁,谁 import 谁声明 dep;**长期**:若 skiff 内部某子库要 `current-runtime` 检测,自动 dep 即可,豁免不必要。
5. **`(runtime-subset …)` 字段通用化**:是否允许任何 lib 声明 `runtime-subset`(自报"我的某些子库在 runtime 安全")?本设计仅在 chandler 自身 manifest 用;通用化需要 parser 之外加 transitive 计算,**复杂度上升显著**。短期不通用,个案特殊处理。
6. **whole-program compilation 交互**:`(library-object-filename)` 在 whole-program compilation 语义下能否仍返回每个 lib 的 object filename?[11](11-runtime-paths.md) §11 已标注;本设计 N1–N5 不解决,N6 评估期或更后。
7. **影响范围与回滚**:N1 rename `(chandler runtime)` → `(chandler runtime-detector)` 是破坏性变更,需要 minor bump 提醒;若 lock 锁了 0.1.x 的项目,`bake install` 旧 chandler 不受影响,但 0.2.x 的 chandler 编译这些老 lock 仍 OK(因为 0.2.x 提供**两套** libref?答:不,rename 后老 libref 不存在)。决定:**0.2.0 直接 rename,文档说明;0.1.x 维护分支不 rename**。
8. **`chandler init` 是否区分 lib/app 模板**:app 模板的 `manifest.ss` 与 lib 模板是否不同?`app` 字段已经在 [02](02-manifest-lock-spec.md) §`(app …)` 段定义;init 模板统一加 chandler dep,app 模板额外加 `(app …)`。

## 12. 参考

- [11-runtime-paths.md](11-runtime-paths.md) §1 缺口表 / §7 API 形态 / §9 失败模式 / §11 open questions——本设计的多处延伸都直接引用。
- [09-pack.md](09-pack.md) K5–K7 · [10-deploy-loader.md](10-deploy-loader.md) L0–L6 · [02-manifest-lock-spec.md](02-manifest-lock-spec.md) schema · [06-runtime-compat.md](06-runtime-compat.md) 双 runtime 约束 · [07-bake-integration.md](07-bake-integration.md) §5 共享实现——前因与约束。
- [`../recipe.ss`](../recipe.ss) 第 8 行注释("bake 自身依赖 `(chandler lock/registry/…)`")——跨工具共享 chandler 子库的**前例**。
- [`../manifest.ss`](../manifest.ss) — chandler 自身零 deps 自举的现状。
- [`../chandler/runtime.ss`](../chandler/runtime.ss) 第 7 行 `(library (chandler runtime))` — 命名冲突的根源;N1 rename 为 `(chandler runtime-detector)`。
- [`../chandler/activate.ss`](../chandler/activate.ss) 第 19-21 行 — dev-only 边界样本(import 了 `install` + `manifest`,故不进 runtime)。
- [`../chandler/hash.ss`](../chandler/hash.ss) — 纯 Scheme SHA-256,典型的"runtime-safe 通用底座"样本。
- [`../chez-skiff-library-layout.md`](../chez-skiff-library-layout.md) — 仓库根 = 搜索根的布局不变量。
- [`../chez-chandler-git-lib-manager-design.md`](../chez-chandler-git-lib-manager-design.md) — 总设计:git-first + manifest-driven。

生态对照:

- [Python `importlib.resources`](https://docs.python.org/3/library/importlib.resources.html),[Elixir `:code.priv_dir/1`](https://www.erlang.org/doc/apps/kernel/code.html#priv_dir/1),[Node `__dirname`](https://nodejs.org/api/modules.html#__dirname) — [11](11-runtime-paths.md) §12 已引;本设计把这种"以 loaded module 为锚点的公共能力" 提升到 chandler 整体层级。
- [Rust `[dev-dependencies]`](https://doc.rust-lang.org/cargo/reference/specifying-dependencies.html#dev-dependencies) — manifest 字段区分编译期 / 运行期的对应范例(本设计用 `(runtime-subset …)` 字段达成同款区分,但反向:运行时白名单)。
- [Go `internal/`](https://go.dev/ref/spec#Internal_packages) — 物理隔离的对应范例;本设计**不**用物理隔离,理由见 §4.1。
- [GNU `intltool`](https://developer.gnome.org/documentation/tutorials/tech-docs/Translation) — 共享 library 集合被多种工具共同消费的 precedent。
- [semver 2.0.0](https://semver.org/) — 版本承诺的权威。
