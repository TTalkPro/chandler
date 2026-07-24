# Chandler v2 设计文档索引

> 本目录是 Chandler v2 的完整设计。v2 是**重大架构升级**,不兼容老版本(layout v1)。阅读顺序:先读 [00](00-design-principles.md)(宪法),再按需读专项。

## 文档列表

| 文档 | 内容 | 优先级 |
|------|------|-------|
| [00-design-principles.md](00-design-principles.md) | **核心模型 + 5 不变量 + 术语表**(宪法) | 必读 |
| [01-manifest-lock.md](01-manifest-lock.md) | `manifest.ss` / `manifest.lock` schema + 新 source kind(prebuilt) | 数据 |
| [02-resolution.md](02-resolution.md) | 依赖解析:BFS 闭包 + 冲突裁决 + 多版本语义 | 数据 |
| [03-central-repo.md](03-central-repo.md) | 中央仓库布局 + 混合 registry + 卸载/升级 | 数据 |
| [04-install.md](04-install.md) | install 操作:从 git/prebuilt 到中央仓库 | 分发 |
| [05-pack.md](05-pack.md) | pack = install --prefix + envelope(payload 字节级统一) | 分发 |
| [06-prebuilt.md](06-prebuilt.md) | prebuilt 分发:source kind + mt-gate + native 安全 | 分发 |
| [07-chandler-setup.md](07-chandler-setup.md) | `(chandler setup)` 启动钩子(Bundler 模型) | 运行时 |
| [08-launchers.md](08-launchers.md) | 启动器生成:dev/install/pack 三态 + bootstrap paradox 解决 | 运行时 |
| [09-runtime-paths.md](09-runtime-paths.md) | 资源定位 API + native 加载 | 运行时 |
| [10-dev-mode.md](10-dev-mode.md) | dev 模式:`_vendor/` + `chandler run` + live edit | 辅助 |
| [11-cli.md](11-cli.md) | CLI 命令面 + 退出码 + 旗标 | 辅助 |
| [12-security.md](12-security.md) | 安全模型:纯数据 + prebuilt native + 签名 | 辅助 |

## 一句话定位

- **Skiff**(轻舟)= 运行时(Chez + libuv);**Chandler**(船具商)= 包管理器;**bake** = 编译引擎(被 chandler 内嵌消费)。
- **git-first + prebuilt 可选**:依赖默认从 git 获取,prebuilt 是加速/闭源/中央分发渠道。
- **版本化中央仓库**:`~/.local/share/chez/<name>/<version>/{src,<mt>}/`,多版本共存。
- **`(chandler setup)` 启动钩子**:每个 installed app 在 run.sps 里 import 它,动态读 lock 配置 library-directories(等价 Bundler 的 `require 'bundler/setup'`)。
- **pack = install --prefix + envelope**:app pack 多 `bin/`/`boot/`/`chandler-runtime/`;lib pack 只有 payload。
- **5 不变量**:Version 自包含 / Payload 字节级统一 / Registry 混合 / Envelope 仅 app pack / Provenance 记录。

## 与 v1 的差异(决策记录)

| 维度 | v1 | v2 |
|------|-----|-----|
| 中央仓库 | flat `<prefix>/{src,<mt>}/`,单版本 | `<name>/<version>/{src,<mt>}/`,多版本 |
| 路径组件 | name-only | name+version+mt 三层嵌套 |
| 启动机制 | 启动器硬编码 prefix | `(chandler setup)` 读 lock 动态构造 |
| pack 布局 | flat `<pack>/<mt>/`,跟 install 同构 | nested,跟 install **字节级一致** |
| pack 内部 | 独立 bootstrap.ss | run.sps + `(chandler setup)`(跟 install 同构) |
| lib pack | 不支持(K7 限制 app only) | 支持(lib pack = payload only) |
| prebuilt | 不支持 | 支持(`source (prebuilt ...)`,带 mt-gate) |
| registry | per-prefix 单文件 | per-version `.chandler/registry.ss` + 顶层 derived index |
| 老版本兼容 | — | **不考虑**(v2 是 breaking change) |

详见 [00 §10 决策记录](00-design-principles.md#10-设计决策记录)。

## 实现进度

见 [../TASK.md](../TASK.md)。
