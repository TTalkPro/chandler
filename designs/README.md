# Chandler v3 设计文档索引

> 本目录是 Chandler 的完整设计。**v3 是当前权威版本**(D13-D19),v2 是历史(D1-D12)。
> 阅读顺序:先读 [06](06-installed-layout.md)(v3 中心设计),再按需读专项。

## 文档列表

| 文档 | 内容 | 优先级 |
|------|------|-------|
| [06-installed-layout.md](06-installed-layout.md) | **v3 中心设计**:目录布局、中心 `.registry/`、资源 method B、lock 驱动、switch | **必读(v3 权威)** |
| [00-design-principles.md](00-design-principles.md) | 核心模型 + 5 不变量 + 术语表(v2 宪法,部分待重写以对齐 06) | 必读 |
| [01-manifest-lock.md](01-manifest-lock.md) | `chandler-manifest.ss` / `chandler-manifest.lock` schema(部分待重写) | 数据 |
| [02-resolution.md](02-resolution.md) | 依赖解析:BFS 闭包 + 冲突裁决 + 多版本语义 | 数据 |
| [03-central-repo.md](03-central-repo.md) | 中央仓库布局(部分待重写:中心 `.registry/` 取代 per-version registry) | 数据 |
| [04-install.md](04-install.md) | install 操作(部分待重写:走 `.registry/` + shim launcher) | 分发 |
| [05-pack.md](05-pack.md) | pack = install --prefix + envelope(FHS 式:`share/chez/` 载荷 + `bin/`/`lib/chez/` envelope) | 分发 |
| [08-launchers.md](08-launchers.md) | 启动器生成(部分待重写:稳定 shim,读 `.registry/`) | 运行时 |
| [09-runtime-paths.md](09-runtime-paths.md) | 资源定位 API(method B:`<src>/<libpath>/resources/`) | 运行时 |
| [10-dev-mode.md](10-dev-mode.md) | dev 模式:`_vendor/` + `chandler run` + live edit | 辅助 |
| [11-cli.md](11-cli.md) | CLI 命令面 + 退出码 + 旗标(部分待重写:加 switch、改 list/doctor) | 辅助 |
| [12-security.md](12-security.md) | 安全模型:纯数据 + prebuilt native + 签名 | 辅助 |

## v3 一句话定位

- **Skiff**(轻舟)= 运行时(Chez + libuv);**Chandler**(船具商)= 包管理器 + 构建器。
- **git-first**:依赖来源(URL + tag/rev/branch pin)写在 `chandler-manifest.ss`,无需中心 registry。prebuilt 是 schema-允许但实现暂缓的备选(D12)。
- **版本化中央仓库**:`~/.local/share/chez/<name>/<version>/{src,<mt>}/`,多版本共存。
- **中心 `.registry/<name>.ss`**(D16):管 name 的所有 versions + active;`list`/`switch`/`doctor` 单一真相源。
- **资源 method B**(D13):`<src>/<libpath>/resources/`,与库源码同居;manifest 删 `(resources ...)` 字段。
- **统一 runner `run.sps`**(D18 lock 驱动):读 `chandler-manifest.lock` 挂精确 dep 版本,多版本 lib 共存不冲突。
- **稳定 shim launcher**(D17):运行时读 `.registry/<name>.ss` 找 active;`chandler switch` 瞬时生效,launcher 永不重写。
- **pack = install --prefix + envelope**:载荷与 install 同管线 → `<pack>/share/chez/`;app pack 多 `bin/<app>` 启动器 + `bin/<runtime>` + `lib/chez/*.boot`;lib pack 只有 payload。
- **5 不变量**:Version 自包含 / Payload 字节级统一(I2 v3 真正成立)/ Registry 中心化 / Envelope 仅 app pack / Provenance 记录。

## v3 决策记录(D13-D19)

| # | 决策 | 状态 |
|---|------|------|
| D13 | 资源 method B:`<src>/<libpath>/resources/`(与库源码同居) | ✅ |
| D14 | 文件命名统一 `chandler-` 前缀(`chandler-manifest.lock`) | ✅ |
| D15 | lock 吸收 registry 的 `files+sha256`(Method Y) | ✅ |
| D16 | 中心 `.registry/<name>.ss` 管 versions + active | ✅ |
| D17 | 启动器 = 稳定 shim,运行时读 `.registry/` | ✅ |
| D18 | `run.sps` lock 驱动 library-directories | ✅ |
| D19 | `chandler switch` 命令(版本切换) | ✅ |

详见 [06 决策记录](06-installed-layout.md#2-决策记录v3-增量)。

## v2 → v3 差异

| 维度 | v2 | v3 |
|------|----|----|
| lock 文件名 | `manifest.lock` | `chandler-manifest.lock`(D14) |
| lock 字段 | `(resolved ...)` | 加 `(files ...)` 字段(D15) |
| manifest 字段 | `(resources ...)` 声明 | 删,静默忽略(D13) |
| 资源路径 | `<src>/resources/<libpath>/` | `<src>/<libpath>/resources/`(method B) |
| `<vroot>/.chandler/registry/` | per-version 文件清单 | **删**,lock 取代 |
| `<libdir>/.registry/` | — | **新**:中心注册表(D16) |
| 启动器 | 生成式,embed VERSION | 稳定 shim,读 `.registry/`(D17) |
| run.sps | scan-libdirs 全扫 | lock 驱动精确挂(D18) |
| switch 命令 | — | **新**(D19) |
| doctor | sha256 漂移(per-version registry) | missing-vroot/active/staging(lock sha256 待补) |

## 已删除的设计文档

| 文档 | 原因 |
|------|------|
| `06-prebuilt.md` | D12 暂缓;prebuilt 仅保留 schema,实现待重启时再设计 |
| `07-chandler-setup.md` | D4 取消;生成的 `run.sps` 取代 Bundler 启动钩子 |

## 实现进度

见 [../TASK.md](../TASK.md)。
