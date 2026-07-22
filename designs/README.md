# Chandler 设计文档索引

> 本目录补齐 [chez-chandler-git-lib-manager-design.md](../chez-chandler-git-lib-manager-design.md)(下称「总设计」)遗留的各专项设计。总设计定方向与难点,本目录逐项落地。阅读顺序即编号顺序。

## 文档列表

| 文档 | 内容 | 对应总设计难点 |
|------|------|---------------|
| [01-cli.md](01-cli.md) | CLI 命令面与工作流 | — |
| [02-manifest-lock-spec.md](02-manifest-lock-spec.md) | `manifest.ss` / `manifest.lock` 完整规范 | 难点 2、6 |
| [03-resolution.md](03-resolution.md) | 依赖解析:传递闭包、冲突规则、拓扑序 | 难点 6、7 |
| [04-fetch-cache.md](04-fetch-cache.md) | git 获取、缓存、离线模式 | — |
| [05-install-registry.md](05-install-registry.md) | 全局安装/卸载的文件清单机制 | 难点 1(点名的下一步) |
| [06-runtime-compat.md](06-runtime-compat.md) | **标准 Chez 与 Skiff 双运行时兼容** | — |
| [07-bake-integration.md](07-bake-integration.md) | **与 bake 的协作接口**(依赖编译闭包/native) | 难点 4、5 |
| [08-bootstrap-security.md](08-bootstrap-security.md) | 自举、分发与信任模型 | 难点 5、8 |

## 定位回顾(一句话版)

- **Skiff**(轻舟)= 运行时(Chez + libuv);**Chandler**(船具商)= 包管理器,读 `manifest.ss`,管**依赖的获取与激活**;**bake** = 构建工具,读 `recipe.ss`,管**编译**。
- Chandler **不绑定 Skiff**:核心只依赖标准 Chez(`(chezscheme)` 可移植子集),Skiff 项目与纯 Chez 项目都能用(见 [06](06-runtime-compat.md))。
- 依赖 = 整仓 checkout 到项目 `vendor/<name>/`,再经 `bake install` 摊平进 `lib/{src,<mt>}`(src/mt 拆分;见[库布局规范](../chez-skiff-library-layout.md));
  `(activate)` / 生成的 `chandler-setup.ss` 挂 **(源 . 对象) 对** `lib/src::lib/<mt>`,native 由 bake 生成的 loader **自加载**,Chandler 仅为无 loader 的第三方库兜底(见 [07 §5b](07-bake-integration.md))。

## 与同类工具对比(设计参照系)

| | Chandler | Akku | Raven | rebar3 | cargo |
|---|---|---|---|---|---|
| 来源模型 | **git-first**(URL+pin 写在 manifest) | 中心化 curated index | 自建 registry | hex.pm + git | crates.io + git |
| 依赖落点 | 项目 `vendor/`(整仓)+ `lib/{src,<mt>}`(装好的库前缀) | `.akku/lib`(重写路径) | 全局 | `_build/` | `~/.cargo` + target |
| 版本模型 | git tag/rev/branch 为主,区间辅助 | SemVer 求解 | 简单版本 | SemVer + lock | SemVer + lock |
| 全局安装 | **可选**(`--global`,带卸载清单) | 无 | 有 | 无 | `cargo install` |
| 原生构建 | 显式声明 + `--allow-build` 授权 | 无统一契约 | 无 | port 编译 | `build.rs`(默认信任) |
| 激活方式 | `(activate)` 一行 / `chandler run` | 环境脚本 | — | rebar shell | — |

取舍:git-first 免去维护 index,代价是**上游须有 `manifest.ss` 或由消费方在自己 manifest 里补全元数据**(见 [03 §依赖元数据的三级来源](03-resolution.md))。

## 实现状态

**全部 8 篇设计已落地实现**(纯 Chez,113 个测试全绿;见仓库根 [README.md](../README.md)、[TASK.md](../TASK.md))。已实现命令:`init/add/remove/install/update/build/verify/list/tree/run/exec` + `install --global`/`uninstall`/`doctor` + `install-self`/`uninstall-self`。

与本目录设计的**已知偏差**(TASK.md 有完整记录):

- **依赖布局改为 Bundler 式**(与 [03](03-resolution.md)/[chandler 总设计](../chez-chandler-git-lib-manager-design.md)早期"整仓 checkout 到 `lib/<name>/`"不同):git 依赖整仓 checkout 到 **`vendor/<name>/`**,再由 **`bake install`** 装进**扁平 `lib/`**(结构同 `~/.local/share/chez/lib`);库搜索只挂 `lib/` 一个目录。install 依赖 bake。另生成 **`chandler-setup.ss`**(位置无关的一行激活文件,Bundler `bundler/setup` 式)。run/exec/repl/activate 库搜索规则统一。


- **`add`/`remove` 用 datum 级改写**而非 [01](01-cli.md) 倾向的文本级插入——对 `init` 生成的规范清单无损,代价是重排手写格式。
- **`chandler cache` 子命令未接入 CLI**:[04](04-fetch-cache.md) 的 git 镜像缓存层已实现并在 `install` 路径生效,但 `cache dir/list/clean` 的命令壳待补。
- 新增两个设计未列的基础库:`(chandler hash)`(纯 Scheme SHA-256,Chez 无内建)与 `(chandler proc)`(子进程封装)。

## 命名约定澄清

库构建描述文件统一为 **`recipe.ss`**(bake 读),依赖清单为 `manifest.ss`(chandler 读)。二者各自独立、互不共享。
