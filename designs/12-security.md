# 12 — 安全模型

> 状态: 设计中

## 1. 一句话目标

在 git-first + prebuilt 双源模型下,定义信任边界和强制授权点,确保任意代码执行风险始终显式可见。

## 2. 纯数据原则

所有 Chandler 管理的数据文件**只 `read` 不 `eval`**:

| 文件 | 处理方式 |
|------|---------|
| `manifest.ss` | `read` → datum → 校验 |
| `manifest.lock` | `read` → datum → 校验 |
| `registry.ss` | `read` → datum → 校验 |
| `source.ss` | `read` → datum → 校验 |
| `index.ss` | `read` → datum → 校验 |
| `pack.ss` | `read` → datum → 校验 |

**不接受外部输入的 `load` / `eval` / `read-expr`**。

### 2.1 数据校验

- 相对路径:manifest 的 path 字段拒绝 absolute path、`..` traversal
- libref 格式:symbol list,非空,首元素为 symbol
- mt 白名单:仅允许已知 machine-type 值

## 3. git 零执行

所有 git 调用带 `-c core.hooksPath=/dev/null`:

```sh
git clone -c core.hooksPath=/dev/null <url>
git checkout -c core.hooksPath=/dev/null <rev>
```

git clone / checkout **不执行任何 hook**。

## 4. native 构建 = RCE

依赖的 native build(别人的代码)属于任意代码执行,须显式授权:

1. 用户传 `--allow-build[=<libs>]`
2. 授权**绑构建描述哈希**写入 `.chandler-approvals`
3. 脚本掉包(描述变更)则授权失效,下次构建前重提示

## 5. prebuilt native = RCE(v2 新增,I5)

prebuilt 含 native = 任意代码执行风险,属于**更高风险**类别。

### 5.1 默认策略

- **默认拒绝**安装含 native 的 prebuilt
- 需显式传 `--allow-prebuilt-native` 旗标

### 5.2 信任分层

| 来源 | 默认信任 | 需要 flag |
|------|---------|---------|
| 官方 mirror 的 prebuilt | ✓(签名校验) | — |
| 三方 prebuilt 无 native | ✓(sha256 校验) | — |
| 三方 prebuilt 含 native | ✗ | `--allow-prebuilt-native` |
| git source + native build | ✗ | `--allow-build` |
| git source 纯 scheme | ✓ | — |

### 5.3 Provenance 记录

`.chandler/source.ss` 记录:
- URL
- sha256
- `(signature "<sig>")` 字段(v2 预留,schema 支持)

用于安全审计和复现。

## 6. sha256 完整性

### 6.1 prebuilt tarball

- 下载前 manifest 已记录期望 sha256
- 下载后校验,不匹配则拒绝安装

### 6.2 registry 审计

per-version `registry.ss` 记录每个文件的 sha256。`chandler doctor --global` 通过 sha256 比对检测篡改。

## 7. 签名(v2 不强制,留扩展点)

`.chandler/source.ss` 预留 `(signature "<sig>")` 字段:

```scheme
;; .chandler/source.ss
(source
  (git "<rev>")
  (signature "<gpg-signature>"))   ; v2 预留

(source
  (prebuilt (mt ta6le) (url "...") (sha256 "..."))
  (signature "<cosign-signature>")) ; v2 预留
```

- **v2 不实现**签名验证,但 schema 支持
- **v3 引入** GPG/cosign 签名

## 8. registry 防篡改

per-version `registry.ss` 是真相之源,但用户可手改。`doctor --global` 通过 sha256 比对检测:

```
$ chandler doctor --global
  sha256 mismatch: foo/1.0.0/src/foo.ss
  expected: abc123...
  actual:   def456...
```

不引入 GPG 签名 registry(v2 太重),靠 sha256 + 可重算兜底。

## 9. 路径安全

### 9.1 manifest path 字段

- 拒绝 absolute path(以 `/` 开头)
- 拒绝 `..` traversal
- 只允许相对路径

### 9.2 libref 校验

symbol list,非空,首元素为 symbol。

### 9.3 pack tarball 解包

解包前检查 path traversal(tar 炸弹防护):
- 拒绝绝对路径
- 拒绝 `..` 在路径组件中
- 拒绝 null byte

## 10. 跟原 design 08 的差异

| 维度 | 原 design 08 | v2 |
|------|-------------|-----|
| prebuilt native | 未明确处理 | 新增 `--allow-prebuilt-native` flag |
| 信任分层 | 未分层 | 三方 prebuilt 含 native 需显式授权 |
| 签名 | 未提及 | 预留 schema,v3 实现 |
| 官方 mirror | 未区分 | 签名校验通过则自动信任 |

## 11. 威胁模型

| 攻击向量 | 缓解措施 |
|---------|---------|
| malicious prebuilt tarball | sha256 校验 + `--allow-prebuilt-native` 显式授权 |
| malicious git hook | `-c core.hooksPath=/dev/null` |
| path traversal in manifest | 校验相对路径,拒绝 `..` |
| path traversal in pack tarball | 解包前检查,拒绝绝对路径和 `..` |
| tampered registry | sha256 比对 + `doctor --global` 检测 |
| tampered source.ss | GPG/cosign 签名(v3) |
| native build inject | `--allow-build` 绑哈希写 `.chandler-approvals` |
| arbitrary code exec via eval | 纯数据原则,只 read 不 eval |

## 相关文档

- [00-design-principles.md](00-design-principles.md) — 核心模型 + 术语表(宪法)
- [01-manifest-lock.md](01-manifest-lock.md) — manifest schema
- [06-prebuilt.md](06-prebuilt.md) — prebuilt 分发机制
- [11-cli.md](11-cli.md) — CLI 安全旗标
