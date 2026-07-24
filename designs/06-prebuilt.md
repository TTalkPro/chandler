# 06 — prebuilt 分发模型

> 状态: 设计中

## 1. 一句话目标

prebuilt 让中央仓库 server 端为每个 mt 单独构建,client 直接下载校验解包,免本地编译;通过 mt-gate 保证本机 ABI 匹配,通过 I5 不变量(native=任意代码执行)强制 native 安全。

## 2. prebuilt 的目的

| 目的 | 说明 |
|------|------|
| 加速 | 免本地编译,下载即用 |
| 闭源分发 | 源码不公开,只发二进制 |
| 中央仓库批量分发 | registry server 为每个 mt 预构建,client 按需拉取 |

## 3. prebuilt source kind 完整 BNF

交叉引用 01-manifest-lock.md:

```scheme
(source
  (prebuilt
    (mt <mt> (url "<url>") (sha256 "<hex>"))
    (mt <mt> (url "<url>") (sha256 "<hex>"))  ; 多个 mt,client 按本机选
    (git-fallback "<git-url>")))                   ; 可选,本机 mt 无 prebuilt 时回退
```

示例:

```scheme
(source
  (prebuilt
    (mt ta6le
      (url "https://mirror/http/1.2.0/ta6le.tar.gz")
      (sha256 "abc123def456..."))
    (mt a6le
      (url "https://mirror/http/1.2.0/a6le.tar.gz")
      (sha256 "789xyz..."))
    (git-fallback "https://github.com/x/http")))
```

## 4. prebuilt pack 文件结构

prebuilt pack = lib pack(无 envelope):

```
<name>-<version>-<mt>.tar.gz   或   <name>-<version>-<mt>-lib.tar.gz
  <name>/<version>/
    src/
    <mt>/
    .chandler/
      manifest.lock
      registry.ss
      source.ss        ← (prebuilt (mt <mt> (url ...) (sha256 ...)))
```

解包后直接可 install 到中央仓库,或直接作为 _vendor 消费。

## 5. prebuilt 中央仓库 fetch 流水线

### 步骤 1: resolve 时选本机 mt 条目

manifest.lock 里同一个 dep 可能含多个 mt 的 prebuilt 条目,resolve 时根据本机 `(current-machine-type)` 选对应条目。

### 步骤 2: 下载 tarball

```sh
curl -L -o <tmpfile> <url>
```

### 步骤 3: sha256 校验

```scheme
(let ([expected (lock-dep-sha256 dep)]
      [actual   (sha256-file tmpfile)])
  (unless (string=? expected actual)
    (error 'install "sha256 mismatch for ~a~%  expected: ~a~%  actual:   ~a"
           name expected actual)))
```

校验失败 → install 失败,不写入任何文件。

### 步骤 4: 解包到 `<name>/<version>/`

```sh
tar -xzf <tmpfile> -C <prefix>
```

### 步骤 5: 写 `.chandler/source.ss`

```scheme
(prebuilt
  (mt <mt>)
  (url "<url>")
  (sha256 "<hex>"))
```

此文件用于审计和复现。

## 6. mt-gate

本机 mt 不在 prebuilt 的 mt 列表 → 安装失败,提示:

```
error: package http 1.2.0 has no prebuilt for this machine-type (ta6le)
  available: a6le
  hint: use --git-fallback to build from source
```

若 dep 含 `git-fallback`,提示可加 `--git-fallback` 旗标回退到 git clone + 本地编译。

## 7. native 安全(I5 不变量 + design 08)

**prebuilt 含 native = 任意代码执行**。这是 I5 不变量的核心约束:

> native 编译产物(.so)是机器码,执行它相当于执行任意代码。中央仓库 server 端 build 出来的 .so 与客户端直接执行 `curl | sh` 的风险同级。

### 安全策略

| 情形 | 默认行为 | 授权旗标 |
|------|----------|----------|
| prebuilt 无 native | ✅ 允许 | — |
| prebuilt 含 native | ❌ 拒绝 | `--allow-prebuilt-native` |
| git build | ❌ 拒绝(需源码编译) | `--allow-build` |

### 信任模型

- **官方 mirror**:默认信任(URL 域名白名单)
- **三方 prebuilt**:需显式 `--allow-prebuilt-native`

### provenance 审计

`.chandler/source.ss` 记录完整 provenance:

```scheme
(prebuilt
  (mt ta6le)
  (url "https://mirror/http/1.2.0/ta6le.tar.gz")
  (sha256 "abc...")
  (built-at "2026-07-20T12:00:00Z")     ; 可选,server 提供
  (builder "https://github.com/x/http"))  ; 可选,指向源码 repo
```

安装时 `--verbose` 输出 provenance 信息。

## 8. 跨平台 CI 假设

v2 **不在 client 做跨编译**。假设:

1. 中央仓库 server 端为**每个 mt** 单独 CI job
2. 每个 job 产出对应 mt 的 prebuilt tarball
3. client 按本机 mt 拉取对应 tarball

未来可能的 registry server(00 §11 提到的远程索引)可自动处理多平台构建。

## 9. prebuilt vs git 的字节级一致性

两者产出相同的 `<name>/<version>/{src,<mt>,.chandler/}` 结构,只 `.chandler/source.ss` 不同:

| 字段 | git | prebuilt |
|------|-----|----------|
| payload | ✅ | ✅ |
| `.chandler/manifest.lock` | ✅ | ✅ |
| `.chandler/registry.ss` | ✅ | ✅ |
| `.chandler/source.ss` | `(git "<rev>")` | `(prebuilt (mt ...) ...)` |

这保证了 I2 不变量:无论 git 还是 prebuilt 安装,后续 Chandler 操作(activate、uninstall、pack)逻辑完全一致。

## 10. prebuilt URL 模板约定

为未来 registry server 留余地,约定 URL 模板:

```
https://<mirror>/<name>/<version>/<mt>.tar.gz
```

示例:
```
https://mirror.example.com/http/1.2.0/ta6le.tar.gz
https://mirror.example.com/http/1.2.0/a6le.tar.gz
```

client 不解释 URL 语义,只按 lock 里的确切 URL 下载。

## 11. 完整示例:prebuilt 消费(myapp 用 http prebuilt)

### myapp 的 chandler-manifest.ss

```scheme
(manifest
  (format 1)
  (name myapp)
  (version "0.1.0")
  (deps
    (http (source (prebuilt
                    (mt ta6le (url "https://mirror/http/1.2.0/ta6le.tar.gz")
                           (sha256 "abc..."))
                    (git-fallback "https://github.com/x/http"))))))
```

### 安装过程

```
$ chandler install
  ├─ resolve: 选 mt=ta6le 条目
  ├─ fetch:
  │    curl https://mirror/http/1.2.0/ta6le.tar.gz
  │    sha256 校验 → abc... 比对
  │    tar -xzf → ~/.local/share/chez/http/1.2.0/
  └─ materialize:
      ~/.local/share/chez/http/1.2.0/
        src/http.ss
        ta6le/http.so
        .chandler/
          manifest.lock
          registry.ss
          source.ss     ← (prebuilt (mt ta6le) ...)
```

### http 库提供 prebuilt

http 库的 CI/CD pipeline:
1. 源码 push 到 github
2. CI 为每个 mt(ta6le、a6le)单独 job
3. job:编译 → 打包 → 上传 `https://mirror/http/<version>/<mt>.tar.gz`
4. 同时生成 sha256 文件或内嵌在 release 元数据里

## 相关文档

- [00-design-principles.md](00-design-principles.md) — I2/I5 不变量、payload 定义、术语表
- [01-manifest-lock.md](01-manifest-lock.md) — manifest.lock schema、prebuilt source BNF
- [04-install.md](04-install.md) — install 流水线(本机 mt prebuilt 解包流程)
- [05-pack.md](05-pack.md) — lib pack = prebuilt 分发载体
- [08-launchers.md](08-launchers.md) — native 安全、bootstrap paradox
- [12-security.md](12-security.md) — 安全模型、签名
