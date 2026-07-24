# 03 — 中央仓库布局、混合 registry、卸载/升级

> 状态: 设计中

## 1. 一句话目标

定义中央仓库的完整目录结构、混合 registry 机制（per-version 真相 + 顶层 derived 缓存）、install/uninstall/upgrade 操作语义。

## 2. 中央仓库默认位置

### 2.1 用户级 vs 系统级

| 级别 | POSIX | Windows |
|------|-------|---------|
| **用户级** | `~/.local/share/chez/` | `%LOCALAPPDATA%\chez\` |
| **系统级** | `/usr/local/share/chez/` | `%ProgramData%\chez\` |

**系统级安装需要 root 权限**（POSIX）或管理员权限（Windows）。

### 2.2 路径约定

- **POSIX**：使用 `/` 作为路径分隔符
- **Windows**：使用 `\` 作为路径分隔符
- **library-directories**：Chez 的 library 路径使用 `::` 分隔（跨平台），格式为 `src::obj`

## 3. 完整目录树

### 3.1 根布局（引用 00 §4.1）

```
<root>/                              ← ~/.local/share/chez/ 或 /usr/local/share/chez/
  .chandler/
    format.ss                        ← (= 2)，版本号
    registry/
      index.ss                       ← DERIVED 缓存：name → [(version, mt, path) ...]
  <name>/
    <version>/                       ← 一个 self-contained mini-prefix
      src/                           ← ABI 中立：源码 + 资源
        <name>.ss                    ← umbrella
        <name>/                      ← sub-lib tree
        resources/<libpath>/         ← 资源
      <mt>/                          ← ABI 绑定：编译产物 + native
        <name>.so
        <name>/*.so
        <libpath>/native/<soname>    ← per-lib native
      .chandler/
        manifest.lock                ← 此 version 的 resolve 闭包
        registry.ss                  ← 真相：name, version, exports, files+sha256
        source.ss                    ← (git "<rev>") | (prebuilt (mt ...) ...)
        run.sps                      ← 入口（仅 app 有）
  ...
```

### 3.2 .chandler/ 子目录

```
<root>/.chandler/
  format.ss            ; (= 2)
  registry/
    index.ss           ; name → [(version, mt, path) ...]
```

### 3.3 per-version .chandler/

```
<name>/<version>/.chandler/
  manifest.lock        ; resolve 闭包快照
  registry.ss          ; 完整 metadata
  source.ss            ; provenance
  run.sps              ; app 入口（仅 app）
```

## 4. 混合 registry 机制

这是 I3 不变量（00 §5）的具体实现。

### 4.1 per-version registry.ss（真相之源）

每个 `<name>/<version>/.chandler/registry.ss` 是**真相之源**：

```scheme
(registry
  (format 1)
  (name <symbol>)
  (version <string>)
  (mt <mt>)
  (exports (<libref> ...))           ; 导出的 library 列表
  (files
    ("src/<name>.ss" (sha256 "<hex>"))
    ("src/<name>/foo.ss" (sha256 "<hex>"))
    ("ta6le/<name>.so" (sha256 "<hex>"))
    ...))                            ; 所有文件路径 + sha256
  (installed-at <timestamp>)
  (source <source-datum>)            ; 原始 source 声明
  (provenance <provenance-datum>))   ; git rev 或 prebuilt URL+sha256
```

**I3.1 不变量**：per-version registry.ss 是 self-contained 的——卸载 `<name>/<version>/` 即删除其 registry.ss，不留孤儿。

### 4.2 顶层 index.ss（DERIVED 缓存）

`<root>/.chandler/registry/index.ss` 是**DERIVED 缓存**：

```scheme
(index
  (http
    ("1.2.0" ta6le "/home/user/.local/share/chez/http/1.2.0")
    ("1.3.0" ta6le "/home/user/.local/share/chez/http/1.3.0"))
  (json
    ("0.9.1" ta6le "/home/user/.local/share/chez/json/0.9.1")
    ("0.9.1" a6le  "/home/user/.local/share/chez/json/0.9.1")))
```

**I3.2 不变量**：index.ss 是从各 version 的 registry.ss 扫描得到的派生缓存，**永不手动编辑**。

### 4.3 混合机制的设计理由

| 特性 | per-version registry.ss | 顶层 index.ss |
|------|------------------------|--------------|
| **用途** | 唯一真相（卸载依据） | 快速查询（哪些包已安装） |
| **更新时机** | install/uninstall 时写入 | install/uninstall 时重建，或 lazy on read with mtime check |
| **扫描成本** | O(1)（直接读取） | O(N) N=version 数（N+1 扫描） |
| **适用场景** | 精确 metadata、卸载 | 列表、查询 |

**为什么需要 index.ss**：

- 用户想知道「已安装哪些包」时，不需要遍历所有 `<name>/<version>/.chandler/registry.ss`
- index.ss 提供 O(1) 查询能力
- 但 index.ss 是派生的——若与 registry.ss 不一致，以 registry.ss 为准

### 4.4 index.ss 重建时机

| 触发 | 行为 |
|------|------|
| `install` | 安装完成后重建 index |
| `uninstall` | 卸载完成后重建 index |
| `chandler list --global`（lazy） | 若 index.ss mtime < 任何 registry.ss mtime，触发重建 |

lazy 重建确保：即使 index 被误删，下次 read 时自动恢复。

## 5. format.ss

`<root>/.chandler/format.ss` 内容：

```scheme
(format 2)
```

值为格式版本号。当前为 `2`（对应 v2 layout）。

**用途**：

- 检测中央仓库是否需要迁移
- 拒绝解析 format 版本不兼容的仓库

## 6. install 操作

### 6.1 install 语义

`chandler install` 将项目的依赖安装到中央仓库：

1. 读取项目的 `chandler-manifest.ss`
2. 执行 resolve（见 design 02），生成 `manifest.lock`
3. 对每个依赖：
   - **git source**：git clone/checkout + 本地编译
   - **prebuilt source**：下载 tarball + 解压
4. 安装到 `<name>/<version>/`（按 00 §4.1 layout）
5. 写入 per-version `registry.ss`
6. 更新 `index.ss`
7. 若为 app：生成启动器到 `~/.local/bin/`（POSIX）或 `bin/`（Windows）

### 6.2 install 路径选择

| 旗标 | 行为 |
|------|------|
| `--user`（默认） | 安装到用户级 `~/.local/share/chez/` |
| `--system` | 安装到系统级 `/usr/local/share/chez/`（需 root） |
| `--prefix=DIR` | 安装到指定目录 |

## 7. uninstall 操作

### 7.1 卸载流程

1. 读取 `<name>/<version>/.chandler/registry.ss`
2. 逐文件验证 sha256（确保文件未被篡改）
3. 删除所有文件
4. 删除空的 `<name>/<version>/` 目录
5. 删除 per-version registry.ss
6. 更新 `index.ss`
7. 若为 app：删除启动器

### 7.2 修改文件的处理

| 情况 | 行为 |
|------|------|
| sha256 匹配 | 正常删除 |
| sha256 不匹配（已修改） | 保留文件，向用户警告 |

理由：用户可能有意修改了文件（如配置），不应强制删除。

### 7.3 引用计数（可选）

若同一 versioned package 被多个 app 引用：

- 引用计数记录在某个共享位置
- uninstall 仅在引用计数归零时删除文件
- 否则只删除 app 的启动器

v2 暂不实现引用计数，简化模型。

## 8. upgrade 操作

### 8.1 升级语义

`chandler upgrade` 的语义：

1. 安装新 version（install 新版本到中央仓库）
2. （可选）删除旧 version
3. **拒绝 auto-upgrade**：用户的 app lock 不自动更新，需要显式 `chandler deps --update`

### 8.2 拒绝 auto-upgrade 的理由

继承 00 §11（不在本设计范围）：

- **可预测性**：auto-upgrade 会导致依赖版本意外变化
- **显式优于隐式**：用户应显式决定何时升级
- **CI 友好**：CI 构建需要确定性依赖，auto-upgrade 破坏可复现性

### 8.3 upgrade 命令行为

```sh
chandler upgrade <name>              ; 升级到最新满足约束的版本
chandler upgrade <name>@<version>    ; 升级到指定版本
```

upgrade 只安装新版本，不自动修改依赖该包的 app 的 lock。

## 9. 路径约定

### 9.1 POSIX vs Windows

| 场景 | POSIX | Windows |
|------|-------|---------|
| 目录分隔符 | `/` | `\` |
| library-directories 分隔符 | `::` | `::`（跨平台） |
| 启动器目录 | `~/.local/bin/` | `%LOCALAPPDATA%\chez\bin\` |

### 9.2 library-directories 格式

```scheme
;; POSIX: "~/.local/share/chez/src::~/.local/share/chez/ta6le"
;; Windows: "C:/Users/user/.local/share/chez/src::C:/Users/user/.local/share/chez/ta6le"
```

`::` 是 Chez Scheme 的路径分隔符，跨平台一致。

## 10. CLI 命令行为

### 10.1 `chandler list --global`

列出中央仓库中所有已安装的包：

```sh
chandler list --global
# 输出：
# http      1.2.0  (ta6le)
# http      1.3.0  (ta6le)
# json      0.9.1  (ta6le, a6le)
# myapp     1.0.0  (ta6le)
```

实现：从 `index.ss` 读取包列表，若 index 过期则触发重建。

### 10.2 `chandler doctor --global`

体检中央仓库：

- 缺失文件检测
- sha256 漂移检测
- 残留 staging 目录检测

### 10.3 `chandler init --global`

初始化中央仓库：

1. 创建 `<root>/.chandler/` 目录
2. 写入 `format.ss`（值为 2）
3. 创建 `registry/` 目录
4. 写入空的 `index.ss`

```sh
chandler init --global           ; 用户级
chandler init --global --system  ; 系统级（需 root）
```

## 11. 中央仓库完整示例

### 11.1 目录结构

```
~/.local/share/chez/
├── .chandler/
│   ├── format.ss                ; (format 2)
│   └── registry/
│       └── index.ss
├── myapp/
│   └── 1.0.0/
│       ├── src/
│       │   ├── myapp.ss
│       │   ├── myapp/
│       │   │   ├── main.ss
│       │   │   └── utils.ss
│       │   └── resources/
│       │       └── myapp/
│       │           └── config.json
│       ├── ta6le/
│       │   ├── myapp.so
│       │   └── myapp/
│       │       ├── main.so
│       │       └── utils.so
│       └── .chandler/
│           ├── manifest.lock
│           ├── registry.ss
│           ├── source.ss
│           └── run.sps
├── http/
│   ├── 1.2.0/
│   │   ├── src/
│   │   ├── ta6le/
│   │   └── .chandler/
│   │       ├── registry.ss
│   │       └── source.ss
│   └── 1.3.0/
│       ├── src/
│       ├── ta6le/
│       └── .chandler/
│           ├── registry.ss
│           └── source.ss
└── json/
    └── 0.9.1/
        ├── src/
        ├── ta6le/
        ├── a6le/
        └── .chandler/
            ├── registry.ss
            └── source.ss
```

### 11.2 index.ss 内容

对应上述示例：

```scheme
(index
  (myapp
    ("1.0.0" ta6le "/home/user/.local/share/chez/myapp/1.0.0"))
  (http
    ("1.2.0" ta6le "/home/user/.local/share/chez/http/1.2.0")
    ("1.3.0" ta6le "/home/user/.local/share/chez/http/1.3.0"))
  (json
    ("0.9.1" ta6le "/home/user/.local/share/chez/json/0.9.1")
    ("0.9.1" a6le  "/home/user/.local/share/chez/json/0.9.1")))
```

## 12. 与原 design 05 的差异

本设计继承并扩展了原 design 05 的 registry 机制：

| 维度 | 原 design 05 | v2 |
|------|-------------|-----|
| registry 结构 | per-prefix 单文件 | per-version `.chandler/registry.ss` + 顶层 derived index |
| 多版本支持 | 单版本 | 多 version 共存 |
| uninstall | 依赖 registry 文件列表 | 直接 `rm -rf <name>/<version>/` |
| mt 支持 | 不支持 | 支持 `<mt>/` 嵌套 |

## 相关文档

- [00-design-principles.md](00-design-principles.md) — 宪法，定义了 I3 不变量和 Unified Layout v2
- [01-manifest-lock.md](01-manifest-lock.md) — manifest.lock schema
- [02-resolution.md](02-resolution.md) — 依赖解析算法
- [04-install.md](04-install.md) — install 操作细节
- [06-prebuilt.md](06-prebuilt.md) — prebuilt 分发机制
- [07-chandler-setup.md](07-chandler-setup.md) — `(chandler setup)` 如何使用中央仓库
