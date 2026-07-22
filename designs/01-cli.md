# Chandler CLI 命令面设计

> 原则:命令少而正交;每条命令只动一类状态(manifest / lock / lib/ / 全局 libdir);**读多写少的操作不需要网络**。默认动作面向最高频工作流:`chandler install` 一步到位。

## 状态模型(命令怎么划分)

Chandler 全部状态就四块,每条命令声明自己读/写哪块:

| 状态 | 位置 | 权威性 |
|------|------|--------|
| 清单 | `./manifest.ss` | 用户手写(或 `add`/`remove` 代改),意图之源 |
| 锁 | `./manifest.lock` | 机器生成,可复现之源 |
| 依赖树 | `./lib/<name>/` | 可随时重建的缓存态(从 lock 物化) |
| 全局库 | `~/.local/share/chez` 前缀(含 `src/` + `<mt>/`,挂 `src::<mt>` 对)等 | 共享安装(见 [05](05-install-registry.md)) |

## 命令总表

| 命令 | 读 | 写 | 网络 | 说明 |
|------|----|----|------|------|
| `chandler init [name]` | — | manifest | 否 | 生成骨架 `manifest.ss`(可选 `--lib` 顺带按[库布局规范](../chez-skiff-library-layout.md)出目录骨架) |
| `chandler add <name> <git-url> [--tag/--rev/--branch/--path]` | manifest | manifest | 否 | 往 `deps` 追加一项(保留手写格式:整文件 `read` → 修改 → `pretty-print` 回写,或文本级追加,见下) |
| `chandler remove <name>` | manifest | manifest | 否 | 删除依赖项;`lib/<name>/` 下次 `install` 时清理 |
| `chandler install` | manifest, lock | lock, lib/ | 按需 | **主命令**:有 lock 且与 manifest 一致 → 按 lock 物化 `lib/`;无 lock 或 manifest 变了 → 解析([03](03-resolution.md))→ 写 lock → 物化 |
| `chandler update [name…]` | manifest | lock, lib/ | 是 | 忽略旧 lock(或仅指定名),重解析 branch/区间 pin,刷新 lock |
| `chandler build [--allow-build]` | lock, lib/ | lib/ 内产物 | 否 | 编译依赖闭包 + 跑 native 构建,**委托 bake**(见 [07](07-bake-integration.md)) |
| `chandler run <script.ss> [args…]` | lock | — | 否 | Bundler exec 模型:设好 `library-directories`(源目录 . 对象目录 成对,如 `lib/src::lib/<mt>`)后 `load` 脚本;native 由 bake 生成的 loader 自加载(该对的对象侧即其候选),preamble 只为无 loader 的第三方库兜底预载(见 [06](06-runtime-compat.md) 选择 runtime) |
| `chandler exec -- <cmd…>` | lock | — | 否 | 导出 `CHEZSCHEMELIBDIRS`(`::` 分隔源::对象、`:` 分隔条目)后 exec 任意命令(给编辑器/CI 用) |
| `chandler repl [--runtime R]` | lock, manifest | — | 否 | 交互 shell(skiff/chez):项目模式(lock 有依赖)挂 `lib/src::lib/<mt>` 对 + path 依赖源目录 + 项目库根 + 全局兜底对;非项目直接挂全局前缀对 `~/.local/share/chez/src::~/.local/share/chez/<mt>`(有 native 则预载) |
| `chandler list` / `chandler tree` | lock | — | 否 | 平铺 / 树形显示已锁定依赖(名、rev、来源) |
| `chandler verify` | lock, lib/ | — | 否 | 校验 `lib/` 与 lock 一致(rev 匹配、无脏改动),CI 用;不一致退出码非 0 |
| `chandler build [--allow-build[=a,b]]` | lock, lib/ | build/ 产物 | 否 | 排单 → bake 编译依赖闭包 + native(见 [07](07-bake-integration.md)) |
| `chandler install --global[=dir]` | — | 全局 libdir | 否 | 把一个库(默认当前仓库)装进全局目录,写卸载清单(见 [05](05-install-registry.md)) |
| `chandler uninstall --global --name=<n>` | 全局注册表 | 全局 libdir | 否 | 按已装文件清单干净删除 |
| `chandler list --global` / `doctor --global` | 全局注册表 | — | 否 | 列出 / 体检全局已装包(见 [05](05-install-registry.md)) |
| `chandler install-self [--prefix D] [--global]` | — | prefix | 否 | 自装 chandler 到 `~/.local`(bake 式,skiff 优先启动器,见 [08](08-bootstrap-security.md)) |
| `chandler uninstall-self [--prefix D]` | 自装清单 | prefix | 否 | 卸载自装的 chandler |
| `chandler cache <clean\|dir\|list>` | 缓存 | 缓存 | 否 | 管理 git 缓存(见 [04](04-fetch-cache.md))——**缓存层已实现,命令壳待补** |

全局旗标:`--offline`(禁网,缓存未命中即错,见 [04](04-fetch-cache.md))、`--allow-build[=a,b]`(授权 native 构建,见 [08](08-bootstrap-security.md))、`--production`、`--force`、`--keep-extra`、`-C <dir>`(切工作目录)、`--verbose`。

## `install` 的判定逻辑(核心路径)

```
chandler install:
  1. read manifest.ss;无 → 报错「先 chandler init」
  2. lock 存在且 lock 内记录的 manifest 内容哈希 == 当前 manifest 哈希?
       是 → 跳过解析,直接进 3
       否 → 解析(03)→ 写 manifest.lock(内含 manifest 哈希)
  3. 物化:对 lock 中每个依赖
       lib/<name> 已存在且 HEAD == 锁定 rev → 跳过(幂等)
       不存在 → 从缓存 checkout(04)
       存在但 rev 不符 → fetch + checkout 到锁定 rev
       存在但有本地脏改动 → 默认报错拒动(--force 覆盖);path 依赖不物化、不检查
  4. 清理:lib/ 下有、lock 中无的目录 → 提示并删除(--keep-extra 保留)
```

- **manifest 哈希入 lock** 是「lock 是否过期」的判定依据,避免比对语义等价性;格式化改动也会触发重解析,可接受(解析在 pin 未变时结果幂等)。
- `path` 依赖不进 lock、不物化(总设计既有决定),`activate`/`run` 时直接挂声明路径。

## `add` 的回写策略

**已实现:datum 级改写**——`read` 整个 `manifest.ss` datum,往 `(deps …)` 追加一项(无 deps 则新建),`canonical` 写回。对 `init` 生成的规范清单无损;代价是会**重排手写格式与注释**。`remove` 同理按名过滤 deps/dev-deps。

> 设计初衷倾向文本级插入(保留手写排版),但 Chandler 生态里清单多由 `init` 生成,datum 级改写更简单可靠,作 v0.1 取舍。若需保留手写注释,v0.2 再换文本级。

## 错误与退出码

沿用 sysexits 风格(与 bake 项目 pack 规范的退出码约定一致):

| 码 | 场景 |
|----|------|
| `64` (EX_USAGE) | 参数错误 |
| `65` (EX_DATAERR) | manifest/lock 解析失败、verify 不一致 |
| `69` (EX_UNAVAILABLE) | 网络/git 失败、`--offline` 缓存未命中 |
| `73` (EX_CANTCREAT) | 全局安装文件冲突(见 [05](05-install-registry.md)) |
| `77` (EX_NOPERM) | 系统级安装无 root / 未授权 native 构建 |

所有错误消息:病因 + 期望 vs 实际 + 修复建议(与 `verify-target!` 同风格);`--porcelain` 时以 s-表达式输出到 stderr 供工具消费。

## 相关文档

- [02-manifest-lock-spec.md](02-manifest-lock-spec.md) — 两份文件的格式权威
- [03-resolution.md](03-resolution.md) — `install`/`update` 第 2 步的解析算法
- [06-runtime-compat.md](06-runtime-compat.md) — `run`/`exec` 如何选 scheme/skiff
