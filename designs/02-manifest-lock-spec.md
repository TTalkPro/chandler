# `manifest.ss` / `manifest.lock` 完整规范

> 总设计已给出 `manifest.ss` 草案;本文把它规范化(字段的必选性、默认值、校验规则),并**首次定义 `manifest.lock` 的完整格式**。两份文件都是可 `read` 的单一 s-表达式,禁止读取时求值(纯数据,非代码——安全边界,见 [08](08-bootstrap-security.md))。

## 1. `manifest.ss` 规范

```scheme
(manifest
  (format 1)                          ; 必选:清单格式版本;高于工具支持即拒(前向兼容闸)
  (name    "my-app")                  ; 必选:项目名 = 仓库目录名 = 库名前缀(布局规范三合一)
  (version "0.1.0")                   ; 必选:本项目版本(SemVer 三段)
  (chez    ">=10.0")                  ; 可选:要求的 Chez 版本区间(标准 Chez 项目用这条)
  (skiff   ">=0.3")                   ; 可选:要求的 Skiff 版本区间;缺省 = 不要求 Skiff
  (chandler ">=0.1.4")                ; 可选:要求的 chandler 版本区间(运行时门,见下)
  (srcdir  ".")                       ; 可选:本仓库库搜索根,默认 "."(布局规范默认)
  (deps    …)                         ; 可选:运行时依赖
  (dev-deps …)                        ; 可选:开发/测试期依赖(解析规则见 03)
  (native  …)                         ; 可选:原生构建声明(契约归 bake 文档,此处只管语法)
  (overrides …)                       ; 可选:传递依赖元数据补全/覆盖(见 §3,新增)
  (scripts (postinstall "scripts/setup.ss")))  ; 可选:具名脚本别名
```

- `chez` 与 `skiff` **正交**:只写 `chez` = 纯 Chez 项目;只写 `skiff` = 只跑在 Skiff 上;都写 = 两边都可跑且各有下界;都不写 = 不设限(见 [06](06-runtime-compat.md))。
- `chandler` 与前两者**同类:运行时门,不是依赖**(2026-07-23,[12 §5](12-chandler-layering.md))。只有版本区间、没有来源:实体恒是全局前缀 `~/.local/share/chez` 里装好的那一份(`CHANDLER_PREFIX` 可覆盖)。`chandler deps` 校验装的版本合不合区间,并把它的 runtime 子集铺进 `vendor/` 与 `lib/{src,<mt>}`;`chandler pack` 从同一前缀取同一子集进包。**同时写 `(chandler …)` 与 `(deps (chandler …))` 直接拒**——后者意味着「去某个 URL 取一份」,而那份未必是本机正在跑的 chandler。
- 未知字段:**警告并忽略**(允许新工具字段渐进落地),但 `format` 高于支持版本则整体拒绝。

### dep 项语法(BNF 风格)

```
<dep>    ::= (<name> <source> <pin>? <opt>*)
<source> ::= (git <url-string>) | (path <relative-path>)
<pin>    ::= (tag <string>) | (rev <string>) | (branch <string>)
             | (version <range-string>)          ; 从 git tag 列表按区间择优(v 前缀自动剥)
<opt>    ::= (srcdir <string>)                   ; 覆盖该上游的库根(上游不守布局规范时)
```

- `git` 来源缺 pin = `(branch <默认分支>)`(警告:会漂移)。
- `(version "^1.2")` 是区间 pin 的显式形态:解析时列出上游 tag,取区间内最高者,**锁定为该 tag 的 commit rev**。
- `path` 来源不允许 pin。

### 版本区间语法(总设计既定,收录为规范)

`"1.2.0"` 精确 / `"^1.2.0"` 不破主版本 / `"~1.2.0"` 只放 patch / `">=0.3"` 下界 / `"*"` 任意;另支持空格连接的合取:`">=0.4 <0.5"`(pack 规范 `skiff-compat` 已用此形)。

### native 项语法

语法归此处、**语义契约归 **bake 项目**「自定义原生构建」**(后端、注入变量、落点不变量):

```
<native> ::= (<name> <source> <pin>? (build <backend>)? <nopt>*)
<backend>::= make | (cmake (targets <s>…)? (defines (<k> <v>)…)?) | (script <path>)
<nopt>   ::= (chez-api #t) | (produces <soname>…)
```

## 2. `manifest.lock` 规范(新定义)

```scheme
(lock
  (format 1)
  (manifest-sha256 "e3b0c4…")         ; 生成时 manifest.ss 的内容哈希 → install 判 lock 是否过期
  (chandler "0.2.0")                  ; 生成工具版本(诊断用,不参与判定)
  (resolved
    ;; 每依赖一项,按名字典序(diff 友好);含传递依赖,树已平铺
    (http
      (source (git "https://github.com/x/http"))
      (pin    (tag "v1.2.0"))         ; manifest 里的原始 pin(诊断/update 判定用)
      (rev    "9f8e7d6c…")            ; ★ 解析到的确切 commit,物化唯一依据
      (srcdir ".")
      (deps   (json uri))             ; 它的直接依赖名(拓扑排序依据)
      (natives (llhttp)))             ; 它声明的 native 名(build 排 native-task + activate 兜底加载依据)
    (json
      (source (git "https://github.com/x/json"))
      (pin    (rev "a1b2c3d"))
      (rev    "a1b2c3d4…")            ; rev pin 展开为全长
      (srcdir "src")                  ; 来自该 dep 自己的 manifest(或 overrides)
      (deps   ())
      (natives ()))))
```

规则:

- **`rev` 是唯一物化依据**;`source`+`pin` 仅供诊断与 `update` 增量判定。rev 一律展开为全长 40/64 位。
- `deps`/`natives` 冗余自各 dep 的 manifest **快照进 lock**——`activate` 与拓扑排序**只读 lock**,不再碰各 dep 的 manifest.ss(部署/CI 稳定,dep 后改 manifest 不影响已锁项目)。
- `path` 依赖与 `dev-deps` 的处置:`path` 不进 lock(总设计既定);`dev-deps` 进 lock 但标 `(scope dev)`,`chandler install --production` 跳过。
- 排序字典序 + 固定缩进 pretty-print:**同输入必出字节相同的 lock**(diff/review 友好)。

## 3. `overrides`:传递依赖的元数据补全(新增)

git-first 最大的现实缺口:**上游仓库可能没有 `manifest.ss`**(存量 Chez 库)。三级来源兜底(优先级从高到低):

1. 消费方 `manifest.ss` 的 `(overrides …)`:为**任意传递依赖**补/改元数据;
2. 依赖仓库自己的 `manifest.ss`;
3. 探测默认:`srcdir "."`、无 deps、无 natives(裸库假定)。

```scheme
(overrides
  ;; 上游 thunderchez 没有 manifest:补 srcdir 与它的间接依赖
  (thunderchez (srcdir ".") (deps ()))
  ;; 上游声明的依赖 URL 已失效:重定向来源
  (uri (source (git "https://github.com/fork/uri")) (pin (tag "v2.0"))))
```

overrides 只在**根项目** manifest 生效(传递依赖的 overrides 忽略——避免深层覆盖不可审计,与 cargo `[patch]` 同理)。

## 4. 校验规则汇总(读入即校验,fail fast)

| 规则 | 违反时 |
|------|--------|
| `format` ≤ 工具支持版本 | 拒绝(EX_DATAERR) |
| `name` 与目录名一致(布局规范三合一) | 警告(全局安装时升级为错误,见 [05](05-install-registry.md)) |
| dep 名唯一;不与内建库名(`chezscheme`/`rnrs`/`skiff` 前缀)冲突 | 错误 |
| pin 三选一,不可并存 | 错误 |
| `path` 必须相对路径且存在 | 错误 |
| 版本区间可解析 | 错误 |
| lock `format`/`manifest-sha256` 有效 | 过期 → 重解析;损坏 → 报错建议 `update` |

## 相关文档

- [03-resolution.md](03-resolution.md) — lock 如何生成(解析算法)
- [07-bake-integration.md](07-bake-integration.md) — `natives` 快照如何被 bake 消费


## `(app …)`:可分发应用的入口(2026-07-22,designs/09)

```scheme
(app (entry (mdserver))    ; 入口库名;必填(声明了 app 就必须给)
     (main main))          ; 入口过程,缺省 `main`
```

包**是不是应用**由有没有这一段决定;库包不写。`chandler pack` 据此确定入口,无需每次传 `--entry`。两条写入路径:

- `chandler init --app [--entry='(<lib>')] [--main=<sym>]` —— 初始化时选定(默认 entry 取 `name`)
- 手写到 `manifest.ss` —— 任何时候都可以;lib → app 的演化只此一步

声明了 app 的包才能 `chandler pack`;没声明(默认 lib 形态)的包 pack 会**显式拒绝**,错误消息指引:`(app …)` 声明、`--entry` 临时覆盖、或改走 `chandler add` 分发。详见 [09 §CLI](09-pack.md)。

**为什么不复用 `name`**:`name` 是**包名**,未必等于入口库名 —— skiff-demo 的包名是 `skiff-demo`,入口库是 `(mdserver)`。早期把两者当同一个,结果是打包"成功"、跑起来才 `library (skiff-demo) not found`(pack 现已在打包期硬校验入口对象,见 [09](09-pack.md))。

`main` 的契约见 [09](09-pack.md):stock 启动器调 `(main <args-list>)`,`skiff --app` 零参调 `(main)`(args 走 `command-line-arguments`);两者通吃的库导出 case-lambda。
