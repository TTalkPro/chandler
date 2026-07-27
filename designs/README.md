# Chandler 设计文档索引

> 阅读顺序:先读 [00](00-design-principles.md)(宪法:核心模型 + 不变量 + 术语),再按需读专项。
> 代码是最终权威;文档可能与实现有细微出入。

## 文档列表

| 文档 | 内容 |
|------|------|
| [00-design-principles.md](00-design-principles.md) | **宪法**:核心模型 + 6 不变量 + 术语表 + 决策记录(D1-D30) | **必读** |
| [04-install.md](04-install.md) | install 操作(中心 `.registry/` + shim launcher + per-prefix 锁 + 整目录 promote) | 分发 |
| [05-pack.md](05-pack.md) | pack = install --prefix + envelope(FHS 式:`share/chez/` 载荷 + `bin/`/`lib/chez/` envelope) | 分发 |
| [06-installed-layout.md](06-installed-layout.md) | v3 中心设计(历史基线):目录布局、中心 `.registry/`、资源 method B、lock 驱动、switch | 参考 |
| [08-launchers.md](08-launchers.md) | 启动器生成(稳定 shim,运行时读 `.registry/`) | 运行时 |
| [09-runtime-paths.md](09-runtime-paths.md) | 资源定位 API(method B:`<src>/<libpath>/resources/`) | 运行时 |
| [11-cli.md](11-cli.md) | CLI 命令面 + 退出码 + 旗标 | 辅助 |
| [13-library-source-layout.md](13-library-source-layout.md) | 单仓库**源码布局规范**(umbrella facade / 子库树镜像 / 搜索根=仓库根) | 辅助 |
| [14-windows-portability.md](14-windows-portability.md) | **Windows 可移植性**(设计中,未实现):cmd.exe 启动器 + 子进程引用层 + 路径层 | 平台 |

## 一句话定位

- **Skiff**(轻舟)= 运行时(Chez + libuv);**Chandler**(船具商)= 包管理器 + 构建器。
- **git-first**:依赖来源(URL + tag/rev/branch pin)写在 `chandler-manifest.ss`,无需中心 registry。
- **版本化中央仓库**:`~/.local/share/chez/<name>/<version>/{src,<mt>}/`,多版本共存。
- **中心 `.registry/<name>.ss`**(D16):管 name 的所有 versions + active;`list`/`switch`/`doctor` 单一真相源。
- **资源 method B**(D13):`<src>/<libpath>/resources/`,与库源码同居。
- **统一 runner `run.sps`**(D18 lock 驱动):读 `chandler-manifest.lock` 挂精确 dep 版本。
- **稳定 shim launcher**(D17):运行时读 `.registry/<name>.ss` 找 active。
- **pack = install --prefix + envelope**:载荷与 install 同管线 → `<pack>/share/chez/`。

## 已删除的设计文档

| 文档 | 原因 |
|------|------|
| `01-manifest-lock.md` | v2 schema,已被代码 + design 06 取代 |
| `02-resolution.md` | v2 设计,BFS 逻辑已在代码实现与注释中 |
| `03-central-repo.md` | 被废弃的 v2 混合 registry 设计 |
| `06-prebuilt.md` | D12 暂缓;prebuilt 仅保留 schema |
| `07-chandler-setup.md` | D4 取消;`run.sps` 取代 Bundler 启动钩子 |
| `10-dev-mode.md` | v2 dev 模式,引用已删文件,与当前代码矛盾 |
| `12-security.md` | 主要描述未实现的功能(prebuilt 信任链/签名等) |
