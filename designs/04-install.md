# 04 — install 操作流水线

> 状态: 设计中

## 1. 一句话目标

把 `manifest.lock` 里的依赖闭包**物化**(materialize)为版本化中央仓库里的 `<name>/<version>/{src,<mt>,.chandler/}`子树,支持 git 和 prebuilt 两种 source,按 I2 不变量字节级统一产出。

## 2. install 命令的两种形态

### 2.1 `chandler install`(项目根,从 manifest.lock 装到中央仓库)

默认行为。从项目根的 `manifest.lock` 读取已解析的依赖闭包,将每个 versioned package 装入中央仓库(`~/.local/share/chez/<name>/<version>/`),并为 app 形态生成命令行入口。

### 2.2 `chandler install --prefix=<dir>`(装到任意目录,pack 用)

不写中央仓库,而是写到指定前缀。常用于 pack 流水线的临时暂存阶段(`<tmp>`),pack 随后在该树基础上追加 envelope。

### 2.3 `chandler install <pack.tar.gz>`(从 pack 直接解包,prebuilt install)

传入一个 tarball 路径,跳过 resolve 和 build 阶段,直接校验 sha256、 解包到中央仓库。prebuilt 源的标准消费方式。

## 3. git source 流水线

当 lock 里的 dep 是 `(source (git "<url>"))` 时:

### 3.1 resolve(已完成)

由 01/02 文档定义,输出 `manifest.lock`,含每个 dep 的 `source`、`rev`、`version`。

### 3.2 fetch(git clone to _vendor)

对每个 git dep:
1. 若本地无 `_vendor/<name>/`,执行 `git clone -c core.hooksPath=/dev/null <url> _vendor/<name>/`
2. `git fetch origin` 更新 remote ref
3. `git checkout <rev>` 切到锁定 commit(detach 状态)
4. 脏目录 → 报错,除非 `--force`

### 3.3 build(in-process compile)

git source 的编译产物不在 fetch 阶段产生,而是由后续的 `chandler build` 命令在 `_vendor/<name>/` 树内就地编译。install 本身不触发编译。

### 3.4 materialize 到 `<name>/<version>/{src,<mt>}/`

在目标前缀(如中央仓库根)里:

1. 创建 `<name>/<version>/` 目录结构
2. 从 `_vendor/<name>/` 复制源码(`src/`)到目标
3. 从 `_vendor/<name>/_build/<mt>/` 复制编译产物(`<mt>/`)到目标
4. 写 `.chandler/manifest.lock`(此 version 的闭包快照)
5. 写 `.chandler/registry.ss`(name、version、exports、files+sha256)
6. 写 `.chandler/source.ss` 记录 `(git "<rev>")`

## 4. prebuilt source 流水线

当 lock 里的 dep 是 `(source (prebuilt ...))` 时:

### 4.1 resolve

同 §3.1,输出含 prebuilt 条目的 lock。

### 4.2 fetch(download + sha256 校验)

1. 从 lock 读取本机 mt 对应的 `(url "<url>")` 和 `(sha256 "<hex>")`
2. `curl` 下载 tarball 到临时文件
3. 计算 sha256,比对 hex — 不等则报错
4. 解包到 `<name>/<version>/`

### 4.3 materialize

prebuilt 的 materialize 比 git 简单(无 build 步骤):

1. 解包 tarball 到 `<name>/<version>/`
2. 校验 payload 结构符合 §4.1 布局
3. 写 `.chandler/source.ss` 记录 `(prebuilt (mt <mt> (url ...) (sha256 ...)))`
4. 写 `.chandler/registry.ss`

## 5. materialize 阶段详解

### 5.1 staging → atomic promote

materialize 分两阶段:

1. **staging**:所有文件先写进 `<root>/.chandler/staging/<name>-<version>-<mt>/`
2. **promote**:staging 完成后,逐文件 move 到最终位置

失败时逐文件反向删除 staging 目录,不留残留。

### 5.2 写 per-version registry.ss

每个 `<name>/<version>/.chandler/registry.ss` 包含:

```scheme
(registry
  (format 1)
  (name <name>)
  (version "<version>")
  (mt <mt>)
  (exports <exposed-libraries>)
  (files (<relpath> (sha256 <hex>)) ...))
```

### 5.3 update index.ss

`<root>/.chandler/registry/index.ss` 是 derived 缓存,由所有 version 的 registry.ss 扫描得到。install 完成后触发增量更新(新增 entry)。

## 6. build 何时介入

| source | build 需要? | 说明 |
|--------|-------------|------|
| git | ✅ 需要 | 本地编译,产物从 `_vendor/<name>/_build/<mt>/` 来 |
| prebuilt | ❌ 不需要 | 中央仓库已编译好,client 只解包 |

**build 触发时机**:git install 的 materialize 在 `chandler build` 之后进行,install 命令本身只负责把已编译产物从 `_vendor/` 复制到目标前缀。

## 7. `--allow-build` 何时需要

当依赖含 native 代码(Foreign Function Interface)时,Chez 编译器需要执行编译步骤,这是任意代码执行(I5 不变量)。默认拒绝。

- **git source**:native 构建需要 `--allow-build`(已编译产物里含 native)
- **prebuilt source**:native 在 tarball 里 → 默认拒绝,需 `--allow-prebuilt-native`

两个 flag 都需要时,chandler 给出清晰错误提示。

## 8. I2 不变量:嵌套而非 flatten

install 不再"flatten 进单一 prefix",而是严格按 `<name>/<version>/` 嵌套:

```
# v2(正确)
~/.local/share/chez/
  http/1.2.0/src/http.ss
  http/1.2.0/ta6le/http.so
  http/1.2.0/.chandler/registry.ss
  http/1.3.0/src/http.ss
  http/1.3.0/ta6le/http.so
  http/1.3.0/.chandler/registry.ss

# v1(已废弃)
~/.local/share/chez/src/http.ss   # flatten,单版本
~/.local/share/chez/ta6le/http.so
```

每个 version 自包含(I1),卸载 `http/1.2.0` 即 `rm -rf`,不留孤儿文件。

## 9. 跟 install-global 的差异

| 维度 | v1 install-global | v2 install |
|------|-------------------|------------|
| 布局 | flat `<prefix>/{src,<mt>}/` | nested `<prefix>/<name>/<version>/{src,<mt>}/` |
| registry | per-prefix 单文件 | per-version `.chandler/registry.ss` |
| 入口 | 无 | app 自动生成 `~/.local/bin/<app>` launcher |
| 事务 | 覆盖写 | staging + atomic promote + rollback |

## 10. staging 目录与回滚

```
<root>/.chandler/staging/<name>-<version>-<mt>/
  src/...
  <mt>/...
  .chandler/...
```

成功:staging 逐文件 promote 到最终位置后删除 staging 目录。
失败:逐文件反向删除 staging 目录,已 promote 的部分按同法回滚。

## 11. 完整示例:git install(myapp 装 http 1.2.0)

```
1. myapp/manifest.lock:
   (deps
     (http (source (git "https://github.com/x/http"))
           (version "1.2.0")
           (rev "abc123")
           ...))

2. chandler install(myapp 项目根)
   ├─ resolve: 读取 lock
   ├─ fetch: git clone https://github.com/x/http → _vendor/http/
   │          git checkout abc123
   ├─ (chandler build): 编译 _vendor/http/_build/ta6le/http.so
   └─ materialize:
       ~/.local/share/chez/http/1.2.0/
         src/http.ss
         ta6le/http.so
         .chandler/
           manifest.lock    ← 此 version 的闭包
           registry.ss     ← (name http)(version 1.2.0)...
           source.ss      ← (git "abc123")
```

## 12. 完整示例:prebuilt install

```
1. myapp/manifest.lock:
   (deps
     (http (source (prebuilt
                    (mt ta6le (url "https://mirror/http/1.2.0/ta6le.tar.gz")
                           (sha256 "abc..."))
                    (git-fallback "https://github.com/x/http")))
           (version "1.2.0")))

2. chandler install(myapp 项目根)
   ├─ resolve: 读取 lock,选本机 mt=ta6le 条目
   ├─ fetch: curl 下载 ta6le.tar.gz
   │          sha256 校验
   └─ materialize:
       ~/.local/share/chez/http/1.2.0/
         src/http.ss
         ta6le/http.so
         .chandler/
           manifest.lock    ← 此 version 的闭包
           registry.ss
           source.ss      ← (prebuilt (mt ta6le (url ...) (sha256 ...)))
```

## 相关文档

- [00-design-principles.md](00-design-principles.md) — 5 不变量、Unified Layout v2、术语表
- [01-manifest-lock.md](01-manifest-lock.md) — manifest.lock schema、prebuilt source kind
- [02-resolution.md](02-resolution.md) — resolve 过程
- [03-central-repo.md](03-central-repo.md) — 中央仓库布局、registry 混合
- [06-prebuilt.md](06-prebuilt.md) — prebuilt source 完整 BNF、mt-gate、native 安全
- [05-pack.md](05-pack.md) — pack 流水线(install --prefix + envelope)
