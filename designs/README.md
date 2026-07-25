# Chandler v2 设计文档索引

> 本目录是 Chandler v2 的完整设计。v2 是**重大架构升级**,不兼容老版本(layout v1)。阅读顺序:先读 [00](00-design-principles.md)(宪法),再按需读专项。

## 文档列表

| 文档 | 内容 | 优先级 |
|------|------|-------|
| [06-installed-layout.md](06-installed-layout.md) | **v3 中心设计**:目录布局、中心 `.registry/`、资源 method B、lock 驱动、switch | **必读(v3 权威)** |
| [00-design-principles.md](00-design-principles.md) | 核心模型 + 5 不变量 + 术语表(宪法,部分待重写以对齐 06) | 必读 |
| [01-manifest-lock.md](01-manifest-lock.md) | `chandler-manifest.ss` schema(待重写:删 resources、改名 chandler-manifest.lock) | 数据 |
| [02-resolution.md](02-resolution.md) | 依赖解析:BFS 闭包 + 冲突裁决 + 多版本语义 | 数据 |
| [03-central-repo.md](03-central-repo.md) | 中央仓库布局(待重写:中心 `.registry/` 取代 per-version registry) | 数据 |
| [04-install.md](04-install.md) | install 操作(待重写:走 `.registry/` + shim launcher) | 分发 |
| [05-pack.md](05-pack.md) | pack = install --prefix + envelope(待重写:删 resource copy) | 分发 |
| [08-launchers.md](08-launchers.md) | 启动器生成(待重写:稳定 shim,读 `.registry/`) | 运行时 |
| [09-runtime-paths.md](09-runtime-paths.md) | 资源定位 API(method B:`<src>/<libpath>/resources/`) | 运行时 |
| [10-dev-mode.md](10-dev-mode.md) | dev 模式:`_vendor/` + `chandler run` + live edit | 辅助 |
| [11-cli.md](11-cli.md) | CLI 命令面 + 退出码 + 旗标(待重写:加 switch、改 list/doctor) | 辅助 |
| [12-security.md](12-security.md) | 安全模型:纯数据 + prebuilt native + 签名 | 辅助 |

## 一句话定位

- **Skiff**(轻舟)= 运行时(Chez + libuv);**Chandler**(船具商)= 包管理器 + 构建器。
- **git-first**:依赖来源(URL + tag/rev/branch pin)写在 `chandler-manifest.ss`,无需中心 registry。prebuilt 是 schema-允许但实现暂缓的备选(D12)。
- **版本化中央仓库**:`~/.local/share/chez/<name>/<version>/{src,<mt>}/`,多版本共存。
- **统一 runner `run.sps`**:install 和 pack 都生成同一份 `<root>/<name>/<version>/.chandler/run.sps`,内联 scan-libdirs + 动态 import 入口库(原 D4 `(chandler setup)` Bundler 模型已取消;改成 launcher `--program` + generated runner scan)。
- **pack = install --prefix + envelope**:app pack 多 `bin/<mt>/<runtime>` / `boot/<mt>/*.boot` / `chandler/<version>/`(自带 chandler 运行时);lib pack 只有 payload。
- **5 不变量**:Version 自包含 / Payload 字节级统一 / Registry 混合 / Envelope 仅 app pack / Provenance 记录。

## 与 v1 的差异(决策记录)

| 维度 | v1 | v2 |
|------|-----|-----|
| 中央仓库 | flat `<prefix>/{src,<mt>}/`,单版本 | `<name>/<version>/{src,<mt>}/`,多版本 |
| 路径组件 | name-only | name+version+mt 三层嵌套 |
| 启动机制 | 启动器硬编码 prefix | launcher `--program` + 生成的 `run.sps` 自己 `scan-libdirs` |
| pack 布局 | flat `<pack>/<mt>/`,跟 install 同构 | nested,跟 install **字节级一致** |
| pack 内部 | 独立 bootstrap.ss | 共用 `run.sps`(pack 模式追加 verifier + native 加载) |
| lib pack | 不支持 | 支持(lib pack = payload only) |
| prebuilt | 不支持 | schema-允许(`source (prebuilt ...)`),实现暂缓(D12) |
| registry | per-prefix 单文件 | per-version `.chandler/registry/<name>.ss`(扫目录) |
| 老版本兼容 | — | **不考虑**(v2 是 breaking change) |

详见 [00 §10 决策记录](00-design-principles.md#10-设计决策记录)。

## 实现偏差(实际 vs 设计)

| 项 | 设计文档 | 实际实现 | 原因 |
|----|---------|---------|------|
| `(chandler setup)` 库 | Bundler 模型,import 即接管 library-directories | ❌ 取消;改用生成的 `run.sps` 内联 `scan-libdirs` | Chez import 在编译时处理,setup 的 top-level 来不及影响展开 |
| install 旗标 | `--global` | `--user`(默认) / `--system` / `--prefix` | 更清晰的语义 |
| system 路径 | `/usr/local/share/chez` | `/usr/local/chez` | 更简洁 |
| APP_ROOT | 去 D8 | ✅ 完全去除 | 统一到 `(library-directories)` |
| dev 全局兜底 | 单对 `(src . obj)` | list of per-version pairs | 扫中央仓库的 nested layout |
| prebuilt 分发 | v2.4 完整实现 | ⏸️ 备选(schema 已定义,实现暂缓) | 中央仓库暂缓 |

## 已删除的设计文档

| 文档 | 原因 |
|------|------|
| `06-prebuilt.md` | D12 暂缓;prebuilt 仅保留 schema,实现待 v2.4 重启时再设计 |
| `07-chandler-setup.md` | D4 取消;生成的 `run.sps` 取代 Bundler 启动钩子 |

## 实现进度

见 [../TASK.md](../TASK.md)。
