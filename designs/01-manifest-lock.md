# 01 — manifest.ss 与 manifest.lock schema

> 状态: 设计中

## 1. 一句话目标

定义 manifest.ss（项目清单）和 manifest.lock（已锁依赖闭包快照）的完整数据 schema，作为 v2 数据层的纯数据规范。

## 2. 设计原则

### 2.1 纯数据原则

manifest.ss / manifest.lock / registry.ss 一律是**纯数据**——只 `read` 不 `eval`，继承 design 08（安全模型）的纯数据原则。理由：

- 消除代码注入攻击面
- 确保跨运行时（Chez / Skiff）一致解析
- manifest.lock 可被非 Scheme 工具校验

所有字段值为 Scheme 原子（symbol、string、number、boolean）或嵌套 list/pair，不含函数对象或闭包。

### 2.2 字段验证规则

| 规则 | 说明 |
|------|------|
| 相对路径 | 所有文件路径字段（srcdir、resources 路径）必须为相对路径，不含 `/` 前缀 |
| 无 `..` traversal | 路径不得包含 `..` 组件，防止路径穿越攻击 |
| libref 格式 | R6RS library 引用格式为 `(name)` 或 `(name sub ...)`，逗号分隔组件 |
| semver 格式 | version 字段为 `"X.Y.Z"` 字符串，语义化版本 |
| 绝对路径禁止 | source url、install path 字段不得为绝对路径（除 prebuilt url） |
| sha256 格式 | 十六进制小写，长度 64 字符 |

## 3. manifest.ss schema

### 3.1 顶层结构

```scheme
(manifest
  (format <number>)                    ; 格式版本，当前为 2
  (name <symbol>)                      ; 包名，顶层 library 标识符
  (version <string>)                   ; semver 字符串，如 "1.2.0"
  (srcdir <string>)                    ; 源码根目录，默认 "."
  (deps <dep> ...)                     ; 运行时依赖列表
  (dev-deps <dep> ...)                ; 开发时依赖列表（仅 non-production 解析）
  (resources <resource> ...)           ; 资源声明列表
  (app (entry <libref>)               ; app 入口（仅 app 包有，使 pack 可执行）
       (main <string>))               ; 主脚本（相对路径，如 "main.ss"）
  (chandler <version-range>)          ; chandler 运行时版本约束
  (source <source>)                   ; 包来源声明
  (overrides <override> ...)          ; 依赖覆盖
  (allow-build (<lib> ...)))          ; native 构建授权列表
```

### 3.2 字段详细说明

#### format

格式版本号，当前为 `2`。v2 的 breaking change 体现在 layout（00 §10 D7），format 版本用于未来格式迁移。

#### name

包名，symbol 类型。对应 R6RS library 的顶层标识符，如 `http`、`json`、`myapp`。规则：

- 必须是有效的 Scheme identifier（不含空格、特殊字符）
- 全局唯一（跨中央仓库）
- 建议与 git 仓库名一致（便于人类阅读）

#### version

semver 字符串，格式 `"X.Y.Z"`：

- X: 主版本（breaking change）
- Y: 次版本（向后兼容功能添加）
- Z: 补丁版本（向后兼容缺陷修复）

预发布标识符（如 `"1.0.0-alpha"`)和构建元数据（如 `"1.0.0+build.123"`）在 v2 中**不支持**——version 必须是精确字符串或区间。

#### deps / dev-deps

依赖列表，每项为 `<dep>` 记录（见 §3.3）。

dev-deps 仅在 `chandler deps --production` 时排除，与 Bundler 的 `group :development` 机制同构。

#### resources

资源声明列表，定义运行时需要访问的静态文件。继承原 design 11 的资源声明格式：

```scheme
(resources
  (<libref> "path")                  ; simple: 单个 libref 对应单一路径
  ((<libref> ...) "path"))           ; multi-lib: 多个 libref 共享同一资源路径
```

**simple 形式**：单个 library 使用的资源目录。

```scheme
(resources (http "share/http"))
```

**multi-lib 形式**：多个 library 共享同一资源目录。

```scheme
(resources ((json xml) "share/data"))
```

路径规则：
- 相对路径，相对于源码根（srcdir）
- 不得包含 `..` traversal
- 资源在 install/pack 时被映射到 `<prefix>/src/resources/<libpath>/`

#### app

仅 app 包有，声明可执行入口：

```scheme
(app
  (entry (myapp main))               ; R6RS library 引用
  (main "main.ss"))                  ; 启动脚本（相对路径）
```

app 字段使包可 pack（见 design 05），并生成 run.sps 启动器。

#### chandler

chandler 运行时版本约束，格式为 version-range 字符串：

```scheme
(chandler ">=0.1.4")                ; 至少 0.1.4
(chandler ">=0.1.4 <0.2.0")         ; 区间
```

version.ss 已有 semver matcher 实现区间求交。

运行时检测：app 启动时，`(chandler setup)` 读取此字段，校验当前运行的 chandler 版本是否满足约束。

#### source

包来源声明，定义依赖的获取渠道。有两种 source kind：

**git source**（默认）：

```scheme
(source (git "<url>"))
```

**prebuilt source**：

```scheme
(source (prebuilt
  (mt <mt> (url "<url>") (sha256 "<hex>"))  ; mt 绑定条目，可多个
  ...))
```

完整 BNF 见 §3.5。

#### overrides

依赖覆盖，用于重定向依赖的 source / pin / metadata：

```scheme
(overrides
  (<lib-name>
    (source (git "<url>"))
    (pin (tag "<tag>"))
    (srcdir <string>)
    (deps (<dep> ...))
    (natives (<symbol> ...))))
```

overrides 的优先级高于 manifest 内原始 dep 声明，用于：

- 锁定特定依赖到已知兼容版本
- 开发时替换为本地 path 依赖
- 修复有问题的传递依赖

#### allow-build

native 构建授权列表。native 构建是 RCE（远程代码执行）等价风险，需要显式授权：

```scheme
(allow-build (http) (json))         ; 授权 http 和 json 的 native 构建
```

未在 allow-build 中列出的库，其 native 构建请求将被拒绝。

### 3.3 dep 记录格式

dep 是 manifest 内描述依赖的基本单元：

```scheme
(<name>
  (source <source>)
  (pin <pin>)
  <optional-fields> ...)
```

#### source 字段

来源声明，与顶层 source 字段同构（见 §3.5）。

#### pin 字段

版本锁定方式：

```scheme
(pin (tag "<tag>"))                  ; 精确 tag
(pin (branch "<branch>"))            ; branch head
(pin (rev "<full-rev>"))            ; 精确 commit
(pin (version "<semver>"))           ; 语义化版本（支持区间）
(pin (version ">=1.0.0 <2.0.0"))    ; 版本区间
```

#### 可选字段

| 字段 | 类型 | 说明 |
|------|------|------|
| `srcdir` | string | 源码子目录，默认 `"."` |
| `scope` | symbol | `runtime`（默认）或 `dev` |
| `resources` | list | 该依赖的资源声明 |

### 3.4 runtime gates

manifest 可声明运行时约束，控制依赖解析和激活行为：

```scheme
(deps
  (<lib>
    (source (git "<url>"))
    (pin (version ">=1.0"))
    (gate chez ">=10.0")             ; 仅 Chez >= 10.0 时解析
    (gate skiff ">=0.1")            ; 仅 Skiff >= 0.1 时解析
    (gate chandler ">=0.1.4")))     ; 仅 chandler >= 0.1.4 时解析
```

gate 字段格式：`(gate <runtime> <version-range>)`

- `chez`：Chez Scheme 版本约束
- `skiff`：Skiff 运行时版本约束
- `chandler`： Chandler 包管理器版本约束

gate 在 resolve 阶段求值（由 version.ss 的 semver matcher 实现）——不满足 gate 的依赖被跳过，不进入 lock。

### 3.5 source BNF（完整）

#### git source

```bnf
<git-source> ::= (source (git <url>))
<url> ::= "<git-url>"                 ; https://github.com/x/foo 或 git@github.com:x/foo
```

#### prebuilt source

```bnf
<prebuilt-source> ::= (source (prebuilt <mt-entry> ... [<fallback>]))
<mt-entry> ::= (mt <mt> (url <url>) (sha256 <hex>))
<mt> ::= <chez-machine-type>         ; 如 ta6le、a6le、i3le
<url> ::= "<prebuilt-tarball-url>"   ; HTTPS URL，指向 .tar.gz 或 .zip
<hex> ::= "<64-char-hex-string>"    ; sha256 校验和，小写十六进制
<fallback> ::= (git-fallback "<url>")
```

**示例**：

```scheme
(source (prebuilt
  (mt ta6le (url "https://example.com/http-1.2.0-ta6le.tar.gz")
               (sha256 "abc123..."))
  (mt a6le  (url "https://example.com/http-1.2.0-a6le.tar.gz")
               (sha256 "def456..."))
  (git-fallback "https://github.com/example/http")))
```

**语义**：

1. resolve 时，根据当前机器类型（`ta6le`、`a6le` 等）选择对应 mt-entry
2. 若无对应 mt-entry 且有 git-fallback：回退到 git clone + 本地编译
3. 若无对应 mt-entry 且无 git-fallback：mt-gate 失败，依赖不满足

**为什么用 tarball 而非 direct file**：

- tarball 是自包含的（payload 子树），解压即等于 install
- 便于做 content-addressed 校验（sha256）
- 支持离线分发（下载一次，多次验证）

#### allow-build BNF

```bnf
<allow-build> ::= (allow-build (<lib> ...))
<lib> ::= <symbol>                    ; library name，如 http、json
```

授权该库（或其任何传递依赖）的 native 构建。未列出的库的 native 构建请求将被拒绝。

## 4. manifest.lock schema

### 4.1 顶层结构

```scheme
(lock
  (format <number>)                   ; 格式版本，当前为 2
  (manifest-sha256 <hex>)            ; 对应 manifest.ss 的 sha256，用于新鲜度判定
  (chandler <version-string>)         ; 解析时使用的 chandler 版本
  (resolved
    <locked-dep> ...))               ; 已锁依赖列表
```

### 4.2 locked-dep 记录

每条已锁依赖的完整记录：

```scheme
(<name>
  (source (<kind> <loc>))            ; 来源 kind + location
  (pin (<pin-kind> <pin-val>))       ; pin 方式 + 值
  (rev <string>)                     ; 确定性 revision（git sha 或 #f for path）
  (srcdir <string>)                  ; 源码子目录
  (deps <name> ...)                  ; 直接依赖名列表
  (natives <symbol> ...)             ; 含 native 的 library 列表
  (scope <scope>)                    ; runtime 或 dev
  (resources <resource>)            ; 资源声明快照
  [name → {source, pin, rev, srcdir, deps, natives, scope, resources}])
```

### 4.3 prebuilt dep 在 lock 里的记录

prebuilt 依赖的 lock 记录与 git 依赖的关键区别：

| 字段 | git | prebuilt |
|------|-----|----------|
| `rev` | git commit SHA | `#f`（无 git revision） |
| `source-loc` | git URL | prebuilt tarball URL |
| `source-kind` | `git` | `prebuilt` |
| `pin-val` | tag/rev/branch | mt-specific URL |

**示例**（prebuilt http 依赖）：

```scheme
(http
  (source (prebuilt "https://example.com/http-1.2.0-ta6le.tar.gz"))
  (pin (mt ta6le))
  (rev #f)
  (srcdir ".")
  (deps (uri))
  (natives ())
  (scope runtime)
  (resources #f))
```

**provenance 追踪**：

- git 依赖的 provenance 是 `(git "<rev>")`
- prebuilt 依赖的 provenance 是 `(prebuilt (mt <mt> (url "<url>") (sha256 "<hex>")))`
- provenance 记录在 `.chandler/source.ss`（每个 versioned package 的 I5 不变量）

### 4.4 lock 新鲜度判定

lock 文件包含 `manifest-sha256` 字段，值为对应 manifest.ss 的 sha256 哈希。

判定流程（继承 design 01 §install 判定）：

1. 读取 manifest.ss，计算其 sha256
2. 与 lock 中的 manifest-sha256 比较
3. 不一致 → lock 陈旧，需要 re-resolve

这确保了：当 manifest.ss 变化（如新增依赖、修改版本约束）时，lock 不会意外被复用。

## 5. 完整示例

### 5.1 manifest.ss 示例

```scheme
(manifest
  (format 2)
  (name myapp)
  (version "1.0.0")
  (srcdir ".")
  (deps
    (http
      (source (git "https://github.com/example/http"))
      (pin (tag "v1.2.0")))
    (json
      (source (prebuilt
        (mt ta6le (url "https://example.com/json-0.9.1-ta6le.tar.gz")
                    (sha256 "abc123def456..."))
        (mt a6le  (url "https://example.com/json-0.9.1-a6le.tar.gz")
                    (sha256 "789ghi..."))
        (git-fallback "https://github.com/example/json")))
      (pin (version "0.9.x"))
      (gate skiff ">=0.1"))          ; 仅 Skiff 运行时解析
    (uri
      (source (git "https://github.com/example/uri"))
      (pin (branch "main"))))
  (dev-deps
    (test
      (source (git "https://github.com/example/test"))
      (pin (rev "abc123def456..."))))
  (resources
    (myapp "resources/"))
  (app
    (entry (myapp main))
    (main "main.ss"))
  (chandler ">=0.1.4")
  (allow-build (http))))             ; http 的 native 构建已授权
```

### 5.2 manifest.lock 示例

对应上述 manifest.ss 的 lock：

```scheme
(lock
  (format 2)
  (manifest-sha256 "1234567890abcdef...")
  (chandler "0.1.4")
  (resolved
    (http
      (source (git "https://github.com/example/http"))
      (pin (tag "v1.2.0"))
      (rev "f1a2b3c4d5e6...")
      (srcdir ".")
      (deps (uri))
      (natives ())
      (scope runtime)
      (resources #f))
    (uri
      (source (git "https://github.com/example/uri"))
      (pin (branch "main"))
      (rev "a1b2c3d4e5f6...")
      (srcdir ".")
      (deps ())
      (natives ())
      (scope runtime)
      (resources #f))
    (json
      (source (prebuilt "https://example.com/json-0.9.1-ta6le.tar.gz"))
      (pin (mt ta6le))
      (rev #f)
      (srcdir ".")
      (deps ())
      (natives ())
      (scope runtime)
      (resources #f))
    (test
      (source (git "https://github.com/example/test"))
      (pin (rev "z9y8x7w6v5u4..."))
      (srcdir ".")
      (deps ())
      (natives ())
      (scope dev)
      (resources #f))))
```

## 6. 验证规则总结

| 场景 | 验证规则 |
|------|---------|
| 路径字段 | 相对路径，无 `..` traversal |
| libref | `(name)` 或 `(name sub ...)` 格式 |
| version | `"X.Y.Z"` 字符串，semver 格式 |
| sha256 | 64 字符小写十六进制 |
| source url | 有效 URL 格式（https:// 或 git@） |
| prebuilt url | 有效 HTTPS URL |
| gate version | version-range 字符串，可被 version.ss 解析 |
| manifest-sha256 | 64 字符十六进制 |
| allow-build | symbol 列表，每个为 library name |

## 相关文档

- [00-design-principles.md](00-design-principles.md) — 宪法，定义了 Unified Layout v2、术语表
- [02-resolution.md](02-resolution.md) — 依赖解析算法如何使用 manifest.lock
- [03-central-repo.md](03-central-repo.md) — 中央仓库如何使用 manifest.lock
- [06-prebuilt.md](06-prebuilt.md) — prebuilt 分发的完整设计
- [08-launchers.md](08-launchers.md) — run.sps 如何读取 manifest.lock
