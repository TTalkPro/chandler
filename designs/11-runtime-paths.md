# 11 — runtime-paths:统一的资源定位 API

> 状态:**设计中(2026-07-23)**,K 标号见 §8。
> 前置:[09](09-pack.md)(pack producer 已落地,APP_ROOT 唯一 env 约定)· [10](10-deploy-loader.md)(deploy loader 已统一)· [02](02-manifest-lock-spec.md)(manifest/lock schema,本设计扩展)。
> 上游规范:[chez-skiff-pack-spec.md](../../skiff/chez-skiff-pack-spec.md)(资源落点约定)。

## 一句话目标

新增 `(chandler runtime-paths)` 库,提供 `(app-resource-path ...)` 与 `(lib-resource-path 'libref ...)` 两个统一 API:app 资源继续走 [09](09-pack.md) 已钉死的 `APP_ROOT/resources/`,只是把裸 `getenv` API 化;lib 资源走 Chez `(library-object-filename)` 反推 install prefix,落在新增的 `<prefix>/share/<lib>/resources/`。同一套调用覆盖 source checkout、project install、pack、CI/run 四态,不加第二个 env,也不改变应用既有 `resources/` 约定。

## 1. 背景:今天的两个缺口

今天不是没有资源布局,而是 app 与 lib 各缺一半:

| 层 | 已有事实 | 缺口 | 直接后果 |
|---|---|---|---|
| app resources | [09](09-pack.md) K5 固定 `<pack>/resources/`;pack launcher 与 dev `chandler-setup.ss` 都设唯一 `APP_ROOT` | 没有公共 API | 每个应用手写 `getenv`、字符串拼接与 fallback |
| lib resources | bake install 只定义 `<prefix>/src/` 与 `<prefix>/<mt>/`;pack 只搬对象树 | 没有安装落点,也没有自定位 API | 库附带 schema、template、CA bundle、fixture 时会在 install/pack 链路丢失 |
| manifest/lock | `srcdir`、`deps`、`natives` 已快照 | 没有 `resources` 声明 | pack 无法按 lock 精确搬资源 |
| pack producer | `copy-resources!` 只复制项目根 `resources/` | 不区分 app 与 dep lib resources | 两类数据无法同时进入一个 pack |

真实的 before state 在 [`../../skiff-demo/mdserver/app.sls`](../../skiff-demo/mdserver/app.sls) 第 34 至 36 行:

```scheme
(define (docs-root)
  (or (getenv "MDSERVER_DOCS")
      (string-append (or (getenv "APP_ROOT") ".") "/resources")))
```

这段代码正确体现了 [09](09-pack.md) K5,但每个应用都要重新写一次。它还把「如何找 app root」泄漏到业务库。新 API 后,业务代码只表达资源相对路径,不再理解 launcher、setup file 或 pack layout。

lib 侧的问题更彻底。bake `run-install` 当前把 `<from>/<lib>/` 递归复制进 `<prefix>/src/`,所以放在库命名空间里的任意非 `.ss` 文件会暂时混进 source tree;对象侧则从 `_build/<mt>/` 搬 deliverable,排除 `.bake-manifest` 与 `*.wpo`。chandler pack 的 `copy-obj-tree!` / `copy-dep-trees!` 又只接受 Chez `.so` 与当前 machine-type 扩展,这些非代码文件不会进入 pack。结果是源码运行可能偶然可见,安装和打包却没有稳定契约。

因此本设计不把 source tree 的偶然复制当作资源支持。资源必须被声明、安装到独立 `share/` 层、写入 lock,再由 pack 按 lock 搬运。

## 2. 双层设计:app 走 env,lib 走 introspection

两类资源的所有者不同,定位手段也应不同:

| API | 所有者 | 权威锚点 | 根路径 | 为什么成立 |
|---|---|---|---|---|
| `(app-root)` | 当前启动目标 app | `APP_ROOT`,缺省由 `(car (command-line))` 推导 | project root 或 pack root | launcher/setup 知道应用从哪里启动 |
| `(app-resource-path . segs)` | app | `(app-root)` | `<app-root>/resources/` | [09](09-pack.md) 已固定目录名 |
| `(lib-resource-path libref . segs)` | 被 import 的 lib | `(library-object-filename libref)` | `<prefix>/share/<libpath>/resources/` | Chez loader 知道实际命中的 library object |
| `(find-lib-resource-path libref . segs)` | 被 import 的 lib | 同上,再走 source fallback | 同上 | 可选资源需要 `#f` 而非 exception |

app 不用 `(library-object-filename)`。应用是 launch target,其入口 `.so` 只是应用闭包的一部分,无法单独代表 pack root。反过来,lib 不读 `APP_ROOT`:同一进程可从多个 prefix 加载库,只有 Chez 的实际 library resolution 能说明某个 lib 来自哪里。

这条边界保持唯一 env 不变量:

- `APP_ROOT` 只描述 app deployment root。
- lib resources 不引入 `LIB_ROOT`、`RESOURCE_ROOT` 或 per-library env。
- `library-directories` 与 `library-object-filename` 已是 Chez 的 library resolution 面,无需另建 registry。

## 3. App 资源(API 化已有约定)

### 3.1 API

```scheme
(app-root)                       ; -> string
(app-resource-path seg ...)      ; -> string,存在且在 resources/ 内
(find-app-resource-path seg ...) ; -> string | #f
```

`(app-root)` 的规则只有两级:

1. `APP_ROOT` 已设且非空,原样采用。pack launcher 是部署态权威,dev `chandler-setup.ss` 也遵守「已有值不覆盖」。
2. 否则从 `(car (command-line))` 取入口路径的 parent。没有可用 argv0 directory 时回落 `"."`。

`(app-resource-path "templates" "index.html")` 拼成 `<app-root>/resources/templates/index.html`。API 接受 path segment,不接受调用者预拼的绝对路径。

### 3.2 为什么 app 用 env

app 是进程的 launch target。launcher 在 `exec` 前已知道 pack root,`chandler-setup.ss` 在 load 时也知道 project root,因此 `APP_ROOT` 是天然的单点交接。它比从 library object 猜入口更准确,也满足 native loader 在 library invoke 期之前就需要 root 的时序约束。

### 3.3 四态一致

| 状态 | `APP_ROOT` 来源 | `(app-root)` 结果 | app resources |
|---|---|---|---|
| source checkout | 通常未设 | argv0 dirname,最差 `.` | `<project>/resources/` |
| project install/dev | `chandler-setup.ss` 在空值时设 project root | project root | `<project>/resources/` |
| pack | sh / PowerShell launcher 在 `exec` 前设 pack root | pack root | `<pack>/resources/` |
| CI/run | setup 自动设置,或用户显式设 `APP_ROOT` | 显式值优先 | `<APP_ROOT>/resources/` |

skiff-demo 的迁移只替换公共部分,应用自己的 `MDSERVER_DOCS` override 可继续保留:

```scheme
;; before
(or (getenv "MDSERVER_DOCS")
    (string-append (or (getenv "APP_ROOT") ".") "/resources"))

;; after
(or (getenv "MDSERVER_DOCS")
    (app-resource-path))
```

`(app-resource-path)` 零 segment 返回 resources directory 本身。这让现有 `docs-root` 保持原语义,但不再手写 `APP_ROOT` fallback。

## 4. Lib 资源(新机制,基于 library-object-filename)

Chez 在 [`../../skiff/deps/ChezScheme/s/primdata.ss`](../../skiff/deps/ChezScheme/s/primdata.ss) 第 991 至 999 行登记了 `library-directories` 与 `library-object-filename`;后者签名是 `sub-list -> maybe-string`。csug libraries chapter 也把它定义为 library object filename 查询面。它是本设计唯一采用的 lib self-location 机制。

### 4.1 五步 prefix 推导

以 `(lib-resource-path '(mylib sub) "schema.json")` 为例。当前实际 object 是:

```text
/abs/prefix/ta6le/mylib/sub.so
```

算法逐步执行(`N` = libref segment 数,本例 N=2):

1. 调 `(library-object-filename '(mylib sub))`,得到 `"/abs/prefix/ta6le/mylib/sub.so"`。
2. 对完整 `.so` 路径做 **N 次** `path-parent`,逐层去掉 `<libref-as-path>.so` 的所有组件:
   - 1 次: `…/ta6le/mylib/sub.so` → `…/ta6le/mylib`(去 `sub.so`)
   - 2 次: `…/ta6le/mylib` → `…/ta6le`(去 `mylib`)
   - 到达 `"/abs/prefix/ta6le"`,即 `<prefix>/<mt>`。
3. 再做 **1 次** `path-parent`,得到 `"/abs/prefix"`,即 install prefix。
4. 用 `path-build` 拼 `prefix + "share" + libref-as-path + "resources" + segs`,结果为 `"/abs/prefix/share/mylib/sub/resources/schema.json"`。

总 path-parent 次数 = **N + 1**(N 次去 libref 路径,1 次去 `<mt>`)。

实现时不能靠删除固定字符串 `"ta6le"`,也不能假定 libref 只有一段。machine-type 目录只是 `<prefix>/<mt>` 的最后一层,libref 的每个 segment 都要参与回退计数与最终 `share/` 路径。

### 4.2 Chez 返回值的边界

`library-object-filename` 返回的是 `default-library-search-handler` 根据当前 `library-directories`、libref 与 extension 构造的 literal string。它不承诺 normalization,也不做 symlink resolution。

| 输入状态 | 返回形态 | 本设计处理 |
|---|---|---|
| absolute `library-directories` object side | absolute `.so` path | 正常反推 prefix,这是 skiff/chandler install 的实际主路径 |
| relative `library-directories` | relative `.so` path | 保留相对语义,对 `path-parent` 边界做校验;是否 normalize 见 §11 |
| built-in `(chezscheme)` / `(rnrs)` | `#f` | 进入 fallback,通常最终报「内置库无资源」 |
| 仅从 source 加载,没有 `.so` | `#f` | 进入 `library-directories` source-side fallback |
| libref 未解析或拼错 | `#f` 或查询失败 | 清晰错误,包含 libref 与已检查位置 |

库必须显式写自己的 libref,例如 `'(mylib sub)`。Chez 没有 `(current-library)` API,运行时也不能从调用栈可靠恢复 library identity。硬编码 libref 是库声明自身身份,不是使用方配置。

### 4.3 source-only fallback

当 `(library-object-filename libref)` 返回 `#f`,API 按以下顺序检查 `(library-directories)` alist:

1. 遍历每个 `(src-dir . obj-dir)` pair。
2. 检查 `<src-dir>/<libref-as-path>.ss`;实现可按 Chez 当前 library extension 集合检查 `.ss`、`.sls` 等实际候选,但必须与 library search 规则一致。
3. 若 source file 存在,把该 `src-dir` 视为 `<prefix>/src`,取它的 parent 得到 `<prefix>`。
4. 检查 `<prefix>/share/<libref-as-path>/resources/<segs>`。
5. 命中即返回。全部未命中则 raise,消息列出 libref、object query 为 `#f`、检查过的 source/share 候选。

fallback 只解决 dev source-only 与 built-in/#f 的可诊断性,不改变主算法。它也不从调用者 cwd 猜库根,更不退回 `APP_ROOT/share/`。lib 与 app 的 namespace 仍严格分离。

## 5. 安装布局:新加 share/ 层

新的 install prefix 有三层,分别承载 source、ABI-bound object 与 ABI-independent data:

```text
<prefix>/
├─ src/                                  portable Scheme source
│  ├─ mylib.ss
│  └─ mylib/sub.ss
├─ <mt>/                                 machine-type / Chez ABI bound
│  ├─ mylib.so
│  └─ mylib/sub.so
└─ share/                                ABI-independent resources
   └─ mylib/
      └─ sub/
         └─ resources/
            ├─ schema.json
            └─ templates/index.html
```

不把资源放在 `<prefix>/<mt>/<lib>/resources/`,理由如下:

| 选择 | 结果 |
|---|---|
| `<prefix>/<mt>/<lib>/resources/` | 同一资源按 mt 重复安装,误示它受 fasl ABI 约束 |
| `<prefix>/src/<lib>/resources/` | 与 source search tree 混合,source-only 的偶然可见继续污染契约 |
| `<prefix>/share/<lib>/resources/` | 一份跨 mt 共享,与 FHS 风格 data layer 对齐,library namespace 明确 |

bake install 在 M1 根据声明,把 lib source directory 下的资源递归复制到 `<prefix>/share/<libpath>/resources/`,并把文件记入现有 `.bake-install/<lib>.files`,使 uninstall 精确删除。对象侧 `_build/<mt>/` 的规则不变。

pack 同时保留两套 namespace:

```text
<pack>/
├─ resources/                            app 自己的数据,现有约定不变
└─ share/
   └─ mylib/sub/resources/               dependency lib 的数据,新增
```

`copy-resources!` 继续处理 app root `resources/`;M2 扩展 `copy-dep-trees!`,对每个 lock 中声明 resources 的 dep,从安装 prefix 的 `share/<libpath>/` 复制到 `<pack>/share/<libpath>/`。这条复制不能套 `.so` extension filter,资源文件按声明目录原样搬运。

## 6. Manifest / Lock 扩展

### 6.1 简单形式

大多数仓库的 package name、顶层 libref 与资源所有者一致:

```scheme
(manifest
  (format 1)
  (name "mylib")
  (version "1.2.0")
  (resources "resources")
  (deps ...))
```

`(resources "rel/path")` 是可选字段。字段缺省时,若安装流程需要探测资源,约定路径为 `"resources"`;目录不存在即表示该包没有资源,不是错误。这镜像 [09](09-pack.md) K5 的思路:名字固定优先于再加配置。显式值主要服务旧仓库或非标准 source layout。

### 6.2 multi-lib 形式

一个 repo 含多个 top-level library,且资源归属不同,可写精细形式:

```scheme
(manifest
  (format 1)
  (name "mylib-suite")
  (version "1.2.0")
  (resources
    ((mylib) "resources")
    ((mylib parser) "resources/parser"))
  (deps ...))
```

每项左侧是 libref,右侧是相对 repository/source root 的 resource directory。安装结果分别是 `<prefix>/share/mylib/resources/` 与 `<prefix>/share/mylib/parser/resources/`。这是 edge case,普通单库仓库优先用简单形式。

### 6.3 lock 快照

lock 的 resolved dep 项同步记录标准化后的声明:

```scheme
(http
  (source (git "https://github.com/x/http"))
  (rev "9f8e7d6c...")
  (srcdir ".")
  (deps (uri))
  (natives ())
  (resources (((http) "resources"))))
```

简单形式在 lock 中标准化成 list of `(libref path)`。这样 pack 只读 lock,不重新读取 `vendor/<dep>/manifest.ss` 或 installed dep 的 mutable manifest。策略与 [02](02-manifest-lock-spec.md) 对 `deps` / `natives` 的快照相同,也与 [09](09-pack.md) K2 的 lock-driven `copy-dep-trees!` 一致。

校验规则:

| 规则 | 违反时 |
|---|---|
| resource path 必须相对 repository root | EX_DATAERR |
| 不得含空 segment、`.` 或 `..` traversal | EX_DATAERR |
| multi-lib 的 libref 必须是非空 symbol list | EX_DATAERR |
| 同一 libref 只能声明一次 | EX_DATAERR |
| lock 只写标准化形式并固定排序 | 保证 byte-stable diff |
| 声明目录在 install 时不存在 | 明示 package/libref/path 后失败,避免产出残缺安装 |

## 7. API 形态: `(chandler runtime-paths)`

### 7.1 exports 与签名

```scheme
(library (chandler runtime-paths)
  (export app-root
          app-resource-path
          find-app-resource-path
          lib-resource-path
          find-lib-resource-path
          define-resource-path-resolver)
  ...)

(app-root)                                  ; -> string
(app-resource-path seg ...)                 ; -> string,不存在则 raise
(find-app-resource-path seg ...)            ; -> string | #f
(lib-resource-path libref seg ...)          ; -> string,不存在则 raise
(find-lib-resource-path libref seg ...)     ; -> string | #f
(define-resource-path-resolver name owner)  ; syntax,owner = app | quoted libref
```

`app-resource-path` 与 `lib-resource-path` 都验证最终目标存在。需要构造尚未创建的输出路径不属于 runtime resource lookup。`find-*` 只把「资源不存在」变成 `#f`;非法 segment、非法 libref 与路径逃逸仍 raise,不能被当作普通 miss 吞掉。

### 7.2 使用例

```scheme
(import (chezscheme)
        (chandler runtime-paths))

(app-resource-path "templates" "index.html")
(lib-resource-path '(mylib parser) "grammar.json")

(let ([p (find-lib-resource-path '(mylib) "optional.dat")])
  (and p (call-with-input-file p get-bytevector-all)))
```

库内推荐把 libref 封装一次:

```scheme
(define-resource-path-resolver mylib-resource '(mylib sub))

(mylib-resource "schema.json")
```

app 也可声明 resolver:

```scheme
(define-resource-path-resolver app-resource app)
(app-resource "docs" "index.md")
```

宏只生成薄 wrapper,不缓存 prefix。`library-directories` 在进程中可被调用者调整,缓存会把旧 resolution 固化。ergonomic layer 只减少重复 libref,不改变查找算法。

### 7.3 错误与路径安全

| 输入/状态 | 行为 |
|---|---|
| 目标存在 | 返回 path string |
| 合法路径但目标不存在 | strict API raise;`find-*` 返回 `#f` |
| `segs` 含 absolute path | raise `runtime-paths: absolute resource segment rejected` |
| `segs` 含 `..` | raise `runtime-paths: parent traversal rejected` |
| `segs` 含 path separator 嵌入 | 拆分后逐段校验,或直接拒绝,实现须选一条并保持跨平台一致 |
| libref 非 symbol list | raise,打印收到的 datum |
| object 与 source fallback 都失败 | raise,打印 libref 与候选位置 |

安全边界是「结果必须仍在选定 resources root 内」。只做字符串 prefix check 不够,因为 `..`、空段、平台 separator 都可能绕过。API 应先校验 segment,再 `path-build`,最后确认 root containment。

## 8. 实现顺序(K 标号,对齐 09/10 风格)

[10](10-deploy-loader.md) 以 L0-L6 完成 deploy loader 迁移。本设计沿用同一表格与依赖说明,新工作编号为 M0-M6,避免和 [09](09-pack.md) 的 K0-K7、[10](10-deploy-loader.md) 的 L0-L6 混淆。

| # | 内容 |
|---|---|
| M0 | `(chandler runtime-paths)` 库骨架 + `app-root` / `app-resource-path` / `find-app-resource-path`。**独立、立即有价值、仅 app**,纯 env/argv0 路径,零 install/pack 改动,作为 Step 1 单独交付 |
| M1 | bake install:读取 lib 的 resources 声明,递归复制到 `<prefix>/share/<lib>/resources/`,纳入 installed-files manifest 与 uninstall |
| M2 | chandler pack:`copy-dep-trees!` 加 `share/` 复制,不套 `.so` filter;`copy-resources!` 明确 app/lib 分工,保持 `<pack>/resources/` 不变 |
| M3 | `lib-resource-path` / `find-lib-resource-path`:基于 `(library-object-filename)` 的五步 prefix 反推 + `library-directories` source fallback + 清晰诊断 |
| M4 | manifest/lock schema 加 `(resources ...)`,解析 simple/multi-lib 两形,lock 标准化快照,pack 只消费 lock |
| M5 | `define-resource-path-resolver` 宏,提供 app 与 quoted libref 两种声明式 wrapper,不缓存 resolution |
| M6 | 文档 + skiff-demo 迁移示范:把 `mdserver/app.sls` 裸 `getenv "APP_ROOT"` 改为 `app-resource-path`;补 simple/multi-lib、source/install/pack 用例 |

**依赖序**:M0 可独立落地,它只把已有 app 约定 API 化。M1-M4 必须作为 lib resources 全链路协同设计:先有 schema/lock 才能精确安装与 pack,先有 `share/` 落点,M3 才有稳定目标。实现提交可按 M4 → M1 → M2 → M3 排,但发布门必须同时覆盖四项。M5-M6 后置。

M2 完成后,按 [10](10-deploy-loader.md) L5 的 precedent 更新 [`../../skiff/chez-skiff-pack-spec.md`](../../skiff/chez-skiff-pack-spec.md),把 `<pack>/share/` 与 lib resource copying 写入上游 pack contract。

## 9. 失败模式 / 陷阱

| 场景 | 期望行为 | 诊断 / 缓解 |
|---|---|---|
| `(library-object-filename libref)` 对 built-in lib 返回 `#f` | 走 source fallback,仍无资源则失败 | 明示 built-in/source-only 两种常见原因;built-in 通常不需要资源 |
| source-loaded lib 没有 `.so`,object query 返回 `#f` | 遍历 `library-directories` 的 source side | 命中 `<src-dir>/<libref>.ss` 后反推 `<prefix>/share/` |
| relative `library-directories` 返回 relative object string | 允许相对推导,但逐层检查 parent 不得坍缩 | 诊断打印原始 literal path;是否 normalize 见 §11 |
| whole-program-compiled binary 不保留 per-library filename | 不把行为写成保证 | 当前列为风险,M3 前做实验;失败时走 fallback 或明确报错 |
| 同一 lib 多版本同时出现在 `library-directories` | 以 Chez 对实际 loaded library 的 object query 为准 | 不自行选择 first directory,避免资源与已载代码版本错配 |
| `<prefix>/share/<lib>/resources/` 未安装 | strict API raise,find API 返回 `#f` | 提示该安装可能来自 M1 前的旧 bake,建议重装 |
| resources directory 存在,具体 `<segs>` 文件缺失 | strict API raise,find API 返回 `#f` | 区分 root missing 与 leaf missing |
| app 未设 `APP_ROOT`,且 argv0 不是位于 project root 的入口 | argv0 fallback 可能得到错误 root | 诊断打印 derived root;推荐 load `chandler-setup.ss` 或显式设唯一 `APP_ROOT` |
| app 从 REPL 启动,`(car (command-line))` 只给 runtime 名 | fallback 可能落到 `.` | REPL/CI 可显式设 `APP_ROOT`,不新增 env |
| libref typo,如库写 `'(mylib)` 而真实库是 `'(mylib core)` | object 与 source lookup 都 miss | 错误完整打印 libref 与检查候选 |
| multi-segment libref 回退层数算错 | 可能把 `<mt>` 或 prefix 识别成 lib directory | 测试 1/2/3 segment,按 libref 长度计数,禁止硬编码 |
| `segs` 含 `..` traversal | 无条件拒绝 | 在 path-build 前逐段校验,防止逃出 resources root |
| `segs` 含 absolute path | 无条件拒绝 | absolute segment 不能覆盖 prefix/root |
| Windows separator 与 POSIX `/` 混用 | 不能靠单一字符 prefix check | 统一 path abstraction 与 segment validation |
| symlink 位于 resources tree 内并指向外部 | 本 API 不做 symlink resolution,与 Chez literal path 语义一致 | integrity/trust 是否限制 symlink 交给 pack policy,见 §11 |
| 把 lib resources 放进 `<mt>/<lib>/resources/` | 视为布局 bug | resources ABI-independent,必须只落 `<prefix>/share/` |
| pack 由旧 install prefix 组装,没有 lib resources | pack preflight 在 lock 声明与 source share 缺失时失败 | 不产出「能启动但运行时缺数据」的残包 |
| pack 搬 `share/` 时沿用 `.so` filter | 所有资源会被静默丢弃 | M2 使用独立递归复制路径,不复用 object deliverable predicate |
| lock 没快照 resources,pack 又回读 dep manifest | mutable dep metadata 可能漂移 | M4 后 pack 只读 lock,对齐 deps/natives 策略 |
| share 中同 libref 被两个 package 声明 | install 冲突,不能后写覆盖 | 解析/安装阶段按 libref ownership 报冲突 |

## 10. 与其他设计的关系

| 文档 | 关系 |
|---|---|
| [09-pack.md](09-pack.md) | 权威定义 `APP_ROOT` 是唯一 env、app `resources/` 名字固定、launcher 与 `chandler-setup.ss` 四态读同一值。本设计只加 API,不改这些结论;M2 添加并列的 lib `share/` namespace |
| [10-deploy-loader.md](10-deploy-loader.md) | deploy loader 已统一为 `bootstrap.ss`,但不向应用库暴露 `%root`;`runtime-paths` 填上业务代码的公开定位面。L0-L6 的 milestone 样式是 M0-M6 的 precedent |
| [06-runtime-compat.md](06-runtime-compat.md) | skiff 与 stock Chez 共用 library mechanism。两边都通过 `library-directories` 挂 source/object pair,因此 lib introspection 不分 runtime |
| [02-manifest-lock-spec.md](02-manifest-lock-spec.md) | M4 扩展 manifest/lock schema。resources 与 deps/natives 一样快照进 lock,pack 不读 mutable dep manifests |
| [07-bake-integration.md](07-bake-integration.md) | M1 改 bake install handoff,在现有 `<prefix>/{src,<mt>}` 外加 `share/`;编译仍归 bake,组装仍归 chandler |
| [08-bootstrap-security.md](08-bootstrap-security.md) | manifest/lock 仍只 `read` 不求值。`share/` 是否进入 pack integrity files、symlink 信任边界留在 §11 |
| [../../skiff/designs/architecture.md](../../skiff/designs/architecture.md) | skiff 是 Chez library/runtime 超集。main.cpp 建立 runtime,library search 仍沿 Chez `library-directories`;本 API 不依赖 libuv 或 skiff-only binding |
| [../../skiff/chez-skiff-pack-spec.md](../../skiff/chez-skiff-pack-spec.md) | 当前 pack contract 只有 app `resources/`;M2 后需按 [10](10-deploy-loader.md) L5 风格更新布局、copy contract 与 integrity 说明 |

## 11. 开放问题

1. **lib resources ownership**:简单形式按 package name 映射一个 libref,还是要求每项都写 arbitrary libref?一个 repo 含多个 top-level libs 时,package name 与 library identity 不一定一致。当前设计保留 simple + multi-lib 两形,最终 parser 的歧义规则需在 M4 钉死。
2. **whole-program compilation**:whole-program-compiled binary 中 `(library-object-filename)` 是否仍能返回每个 library 的 object filename?这必须在 stock Chez 与 skiff 上实测,不能从 per-module 行为外推。
3. **read helpers**:是否在 v1 同时提供 `(lib-resource-bytes ...)`、`(lib-resource-open-input-port ...)` 与 app 对称版本?当前 M0/M3 只返回 path,避免把 bytevector、port lifetime 与 encoding policy塞进基础定位 API。可在 v2 添加薄 helper。
4. **pack integrity**:`<pack>/share/**` 是否必须列入 `pack.manifest` 的 `(files ...)` 并参与 `chandler verify-pack` sha256/size 校验?安全上倾向必须,M2 与上游 spec 更新时决定。
5. **relative library-directories**:`library-object-filename` 返回 relative literal path 时,API 应保持相对,还是先按当前 directory 变成 absolute path?normalize 会冻结 cwd 时点,保持 relative 又使调用后 `current-directory` 变化有风险。
6. **default resources semantics**:`(resources ...)` 缺省为 `"resources"` 时,install 是静默跳过不存在目录,还是只有目录存在才自动声明进 lock?当前倾向不存在即无资源,但 lock 是否记录空声明需确定。
7. **symlink policy**:复制 `share/` 时是否允许 symlink,若允许,pack integrity 与 root containment 如何定义?Chez 返回值本身不做 symlink resolution,但资源树的交付策略可以更严格。
8. **multi-version coexistence**:同一 libref 的两个版本若通过不同 object roots 被不同 compilation instance 使用,resources 应严格跟随 `library-object-filename` 命中的 loaded object。需要测试 Chez 在加载后调整 `library-directories` 时的返回稳定性。

## 12. 参考

- [09-pack.md](09-pack.md) K5 与「env:去两个,留一个,换中性前缀」,`APP_ROOT`、`resources/` 及四态同构的权威。
- [10-deploy-loader.md](10-deploy-loader.md) L0-L6,统一 bootstrap 与上游 spec 更新流程的 precedent。
- [02-manifest-lock-spec.md](02-manifest-lock-spec.md) `manifest.ss` / `manifest.lock` 纯数据 schema 与 lock snapshot 规则。
- [`../../skiff-demo/mdserver/app.sls`](../../skiff-demo/mdserver/app.sls) 第 34 至 36 行,现有手写 `APP_ROOT/resources` before state。
- [`../../skiff/deps/ChezScheme/s/primdata.ss`](../../skiff/deps/ChezScheme/s/primdata.ss) 第 991 至 999 行,`library-directories` 与 `library-object-filename : sub-list -> maybe-string`。
- [Chez Scheme User's Guide, Libraries](https://cisco.github.io/ChezScheme/csug10.0/libraries.html),`library-object-filename`、`library-directories` 与 default library search handler。
- [Python `importlib.resources`](https://docs.python.org/3/library/importlib.resources.html),以 module/package 为 anchor 的 runtime resource API。
- [Elixir `:code.priv_dir/1`](https://www.erlang.org/doc/apps/kernel/code.html#priv_dir/1),按 application 定位 `priv/` data directory。
- [Node.js `__dirname`](https://nodejs.org/api/modules.html#__dirname),以 loaded module filename 为定位锚点的对照。
- [Rust `include_str!`](https://doc.rust-lang.org/std/macro.include_str.html),compile-time embedding 的对照。本设计不采用,因为它会把资源固化进 artifact,不适合 install/pack 独立数据层。
- [RFC sysexits.h](https://man.openbsd.org/sysexits),manifest/path validation 使用 EX_DATAERR 等 exit code 的语义来源。
