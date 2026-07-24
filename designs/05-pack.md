# 05 — pack = install --prefix + envelope

> 状态: 设计中

## 1. 一句话目标

pack 把闭包物化为**自包含分发包**:payload 与 install 完全一致(I2 不变量),app pack 追加 envelope(启动器 + bundled runtime + chandler-runtime)。

## 2. 核心等式:D2 决策

```
pack = install --prefix=<tmp> + envelope
```

此决策将 pack 实现代码量从 ~1100 行压缩到 ~300 行,因为:
- install 的 materialize 逻辑被 pack 复用
- payload 字节级统一意味着 pack 解开就是 install 子树
- pack 不再需要独立的编译/构建逻辑

## 3. envelope 内容

app pack 根目录下追加:

```
<pack-root>/
  bin/
    <app>               ← POSIX 启动器(sh)
    <app>.ps1           ← Windows 启动器(PowerShell)
    <mt>/<runtime>       ← bundled skiff/scheme(ABI 绑定)
  boot/<mt>/*.boot       ← boot 文件(ABI 绑定)
  chandler-runtime/       ← bundled chandler runtime(解决 bootstrap paradox,D5)
    src/chandler/         ← runtime 子集源码
    <mt>/chandler/         ← runtime 子集编译产物
  .chandler/
    pack.ss              ← pack 元数据
  <name>/<version>/...   ← payload(同 §4.1 布局)
  <dep-name>/<dep-version>/...  ← 依赖闭包 payload
```

**lib pack 无 envelope**,只有 payload。

## 4. payload 与 install 完全一致(I2 不变量)

```
# payload(所有形态共享)
<name>/<version>/
  src/                   ← 源码 + 资源(ABI 中立)
    <name>.ss
    <name>/
    resources/<libpath>/
  <mt>/                  ← 编译产物 + native(ABI 绑定)
    <name>.so
    <name>/*.so
    <libpath>/native/<soname>
  .chandler/
    manifest.lock        ← 此 version 的 resolve 闭包
    registry.ss          ← 真相:exports、files+sha256
    source.ss            ← (git "<rev>") | (prebuilt ...)
    run.sps              ← 入口(仅 app 有)
```

pack 解开 → payload 字节级等同于 install 产出(00 §4.3 四态一致)。

## 5. pack 流水线

### 步骤 1: resolve closure

从 `manifest.lock` 读取完整依赖闭包(含传递依赖)。

### 步骤 2: `install --prefix=<tmp>`

将 payload 部分写入临时目录:
- 每个 dep 从 `_vendor/` 或 prebuilt tarball 复制到 `<tmp>/<name>/<version>/`
- payload 布局严格遵循 §4

### 步骤 3: copy envelope

对 app pack,追加 envelope:

1. `bin/<app>` + `bin/<app>.ps1`:启动器(详见 08-launchers.md)
2. `bin/<mt>/<runtime>`:从系统 runtime 复制(bundled skiff/scheme)
3. `boot/<mt>/*.boot`:从系统 boot 目录复制
4. `chandler-runtime/src/chandler/` 和 `<mt>/chandler/`:runtime 子集源码和编译产物

### 步骤 4: write `.chandler/pack.ss`

```scheme
;; app pack
(pack
  (format 1)
  (entry-app <name>)
  (entry-version "<version>")
  (mts <mt> ...)
  (runtime <runtime-kind>)   ; skiff | chez
  (chandler-version "<v>"))

;; lib pack
(lib-pack
  (format 1)
  (name <name>)
  (version "<version>")
  (mts <mt> ...))
```

### 步骤 5: tar 打包

```sh
tar -czf <name>-<version>-<mt>.tar.gz -C <tmp> .
```

## 6. pack 命名

app pack:`<name>-<version>-<mt>.tar.gz`
lib pack:`<name>-<version>-<mt>-lib.tar.gz`

## 7. lib pack(D3 决策)

无 envelope,只有 payload。`.chandler/pack.ss` 写:

```scheme
(lib-pack
  (format 1)
  (name <name>)
  (version "<version>")
  (mts <mt> ...))
```

lib pack 用途:支持中央仓库 prebuilt 分发。解包后直接可 install 到中央仓库。

## 8. 不再需要独立的 bootstrap.ss

v1 pack 有一个独立的 `bootstrap.ss` 启动脚本。v2 改为:

```scheme
;; run.sps(同 install 模式)
(import (chezscheme)
        (chandler setup)
        (myapp main))
(main (cdr (command-line)))
```

启动时:
1. `bin/<app>` launcher 指向 bundled runtime
2. `bin/<app> --libdirs <pack-root>/src::<pack-root>/<mt> --program <pack-root>/<name>/<version>/.chandler/run.sps`
3. `(chandler setup)` 接管 library-directories(与 install 模式完全同构)

**bootstrap paradox 解决**:launcher 用 `--libdirs` 指向 bundled `chandler-runtime/`,让 `(chandler setup)` 在接管前先能被找到(D5 决策)。

## 9. pack verify(`chandler verify-pack <dir>`)

校验 pack 完整性:

1. `.chandler/pack.ss` 存在且格式合法
2. per-version `.chandler/registry.ss` 存在
3. registry.ss 里每个文件的 sha256 与磁盘实际 sha256 比对
4. source.ss 记录与 pack.ss 声明的 mt 一致

## 10. pack vs install 启动器差异

| 维度 | pack | install |
|------|------|---------|
| runtime 来源 | bundled `bin/<mt>/<runtime>` | 系统 runtime(PATH 发现) |
| chandler-runtime | envelope 里那份 | 系统中央仓库那份 |
| library-directories | `bin/<app> --libdirs ...` | launcher 指向系统前缀 |
| 启动路径 | `run.sps` + `(chandler setup)` | 同 pack |

## 11. 完整 pack 目录树示例

### 11.1 app pack(myapp 1.0.0,ta6le)

```
myapp-1.0.0-ta6le/
  bin/
    myapp                ← sh 启动器
    myapp.ps1            ← Windows 启动器
    ta6le/skiff          ← bundled skiff
    ta6le/scheme         ← bundled chez
  boot/
    ta6le/
      skiff.boot
      petite.boot
      scheme.boot
  chandler-runtime/
    src/chandler/
      base.ss
      runtime-paths.ss
      hash.ss
      version.ss
      util.ss
      fs.ss
      sexp.ss
      layout.ss
      runtime-detector.ss
      proc.ss
    ta6le/chandler/
      base.so
      runtime-paths.so
      ...
  .chandler/
    pack.ss              ← (entry-app myapp)(entry-version "1.0.0")(mts ta6le)
  myapp/1.0.0/
    src/
      myapp.ss
      myapp/
        core.ss
        resources/
    ta6le/
      myapp.so
      myapp/core.so
    .chandler/
      manifest.lock
      registry.ss
      source.ss
      run.sps
  http/1.2.0/            ← 依赖闭包
    src/http.ss
    ta6le/http.so
    .chandler/
      manifest.lock
      registry.ss
      source.ss
```

### 11.2 lib pack(http 1.2.0,ta6le)

```
http-1.2.0-ta6le-lib/
  http/1.2.0/
    src/http.ss
    src/http/
      client.ss
      resources/
    ta6le/http.so
    ta6le/http/
      client.so
    .chandler/
      manifest.lock
      registry.ss
      source.ss
  .chandler/
    pack.ss              ← (lib-pack (name http)(version "1.2.0")(mts ta6le))
```

## 相关文档

- [00-design-principles.md](00-design-principles.md) — D2/D3/D5 决策、I2/I4 不变量、payload/envelope 定义
- [04-install.md](04-install.md) — install 流水线(被 pack 复用)
- [06-prebuilt.md](06-prebuilt.md) — prebuilt 分发(lib pack 主要用途)
- [07-chandler-setup.md](07-chandler-setup.md) — `(chandler setup)` 启动钩子
- [08-launchers.md](08-launchers.md) — 启动器生成、bootstrap paradox 解决
- [09-runtime-paths.md](09-runtime-paths.md) — 资源定位 API
