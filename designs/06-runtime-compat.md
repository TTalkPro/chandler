# 双运行时兼容设计:标准 Chez 与 Skiff

> 需求:Chandler **不只服务 Skiff**——标准 Chez Scheme 项目同样是一等公民。本文定义兼容层:Chandler 自身的可移植性、项目如何声明目标运行时、`run`/`activate` 在两种运行时下的行为差异。

## 1. Skiff 与标准 Chez 的差异(与 Chandler 相关的部分)

从 **skiff 项目**的运行时设计提取对包管理有影响的差异:

| 维度 | 标准 Chez | Skiff | 对 Chandler 的影响 |
|------|-----------|-------|-------------------|
| 可执行文件 | `scheme` / `petite` | `skiff`(Chez + libuv + 调度器) | `run` 要选对解释器 |
| 库机制 | R6RS library,展开期解析 | **同一套**(Skiff 不改库机制;runtime resolver 是 Skiff 应用层的事) | `activate`/布局对两者完全一致 ★ |
| 异步/调度 | 无 | 续延调度器 + libuv loop | Chandler 不触碰;纯正交 |
| 内建库 | `(chezscheme)` `(rnrs …)` | 另加 `(skiff …)` 前缀族 | 依赖解析把 `(skiff …)` 也当内建排除 |
| 线程版要求 | 任意 | 非线程版(Swish 路线) | 只影响 native 的 ABI 标注(mt 里含 `t` 与否) |
| 部署态 | 源码或 `.so` | 另有 `skiff --app` + `pack.manifest` | pack 归 bake;Chandler 提供编译闭包即可 |

★ 是整个兼容设计的支点:**Skiff 不动 Chez 的库/展开机制**,所以 Chandler 的核心(fetch/lock/lib/ 布局/activate)天然双通,兼容层只需处理「选哪个可执行文件」和「版本门」。

## 2. Chandler 自身的可移植性约束

- Chandler 及 `(chandler)` 库**只 import `(chezscheme)`**,且限定在 Petite 也能跑的解释子集(布局规范「核心零依赖」同款约束)——保证在任何标准 Chez ≥ 声明下界上可运行,**不依赖 Skiff 的任何设施**(不用 libuv、不用调度器;子进程/文件操作用 Chez 原生 `process`/`system` 与文件系统原语)。
- 发布物:同一份 Chandler 源码,标准 Chez 与 Skiff 都能直接跑(Skiff 是 Chez 超集);自举见 [08](08-bootstrap-security.md)。

## 3. 项目声明:`chez` / `skiff` 双字段([02](02-manifest-lock-spec.md) 已定语法)

| manifest 写法 | 含义 | `run` 的解释器选择 |
|---------------|------|--------------------|
| 都缺省 | 纯库/不挑运行时 | `scheme`(PATH 中的标准 Chez) |
| 仅 `(chez ">=10.0")` | 标准 Chez 项目 | `scheme`,启动前校验版本区间 |
| 仅 `(skiff ">=0.3")` | Skiff 应用 | `skiff`,校验 skiff 版本区间 |
| 两者都写 | 双跑项目(如基础库的测试) | 默认 `scheme`;`chandler run --runtime skiff` 切换 |

- **选哪一种运行时**(`run`/`exec`/`repl` 与**启动器**共用一套优先级,2026-07-22 补 env 层):
  `--runtime` 旗标 > **`CHANDLER_RUNTIME=skiff|chez`** > manifest 声明(仅 `(skiff …)` → skiff)> 默认。
  非法 `CHANDLER_RUNTIME` 值即报错(启动器退出码 64 = EX_USAGE),不静默忽略。
- **选哪个可执行文件**:`CHANDLER_SKIFF` / `CHANDLER_SCHEME` 环境变量(名或路径)> PATH 上的默认名。
  显式指定即**照单执行**:找不到就失败(启动器 127),**不**静默回退到别的运行时,也不再跑能力探测——
  对显式覆盖再探测/再回退,等于否定了覆盖。
- 版本探测:`scheme --version`(stderr)/ `skiff --version`;区间校验失败 fail fast,措辞同 pack 规范 `verify-target!` 风格(expected vs actual + 修复建议)。
- **依赖侧校验**:解析时对每个 dep 的 `chez`/`skiff` 声明同样求交——纯 Chez 项目引入「仅 skiff」的依赖(声明了 `(skiff …)` 且未声明 `chez`)→ 警告;运行 `scheme` 时该依赖 import `(skiff …)` 自会硬错,Chandler 提前把话说明白。

## 4. `activate` 的双运行时行为

`(chandler)` 库的 `activate` 在两种运行时下**代码路径完全相同**(挂 `library-directories` 的 (源 . 对象) 对 + 为无自加载能力的库兜底 `load-shared-object` natives,见 [07 §5b](07-bake-integration.md));差异只有一处版本门:

```scheme
(define (activate . maybe-root)
  (verify-runtime! (read-manifest …))   ; ① chez/skiff 区间门:探测当前运行时
  …)                                     ; ② 以下与总设计草案一致

(define (current-runtime)                ; 探测:skiff 存在性以其标志绑定为准
  (if (skiff-version-string) 'skiff 'chez))   ; 取到字符串版本才算 skiff
```

- Skiff 侧约定:运行时暴露顶层 `skiff-version`。`current-runtime` 据此判别——**不**用可执行文件名猜(可能被符号链接/嵌入)。
  > **2026-07-22 修订**:skiff 自 0.1.1 起把它绑为**内置过程**(更早可能是字符串),**两种绑法都须认**(bake 同款容忍)。
  > 只认字符串会把 skiff 误判成 Chez —— 连带 `(skiff …)` 版本门形同虚设(且冒出「要求 skiff 却跑在 Chez 上」的假警告)、
  > `runtime-version` 回落成 Chez 版本、repl 兜底选错运行时。
  >
  > 另一个坑:取值必须走**反射** `(top-level-value (string->symbol "skiff-version"))`,
  > **不能**直接写 `(skiff-version)` —— 后者在 `--program` 模式下是展开期未绑定标识符,直接报错,
  > 而 chandler 的 CLI 与启动器探测正是以 `--program` 跑的。
- `verify-runtime!` 只在**根项目** manifest 有 `chez`/`skiff` 声明时启用;失败即抛,措辞含双边版本。
- Skiff 的 `--app` 部署态(pack)**不走 activate**(pack 规范 §4 自带加载逻辑),两者策略对齐(infra 兜底载 native)但代码独立——部署态无 Chandler。bake 生成的 `(<lib> native-loader)` 在两态下都先行自加载,infra 侧只是兜底(幂等)。

## 5. `chandler run` 全流程(双运行时)

```
chandler run app.ss:
  1. 读 manifest + lock;选解释器(§3 表)并版本校验
  2. 组装 CHEZSCHEMELIBDIRS = lib/<各依赖>/<srcdir> … : 既有值   ; 展开期即可解析,免脚本内 activate
  3. exec: <interp> --script app.ss <args…>
     ; 脚本内仍可写 (import (chandler)) (activate) —— 幂等,重复挂载无害
```

- `run` 用**环境变量前置**而非依赖脚本顶层 `(activate)`:这样 whole-program/编译型入口也能跑(总设计「expand-time 坑」的官方出口)。native 侧:bake 生成的 loader 已能自加载(其候选序含 `library-directories` 的对象侧,而 `run` 设的正是 `lib/src::lib/<mt>` 对),故 `run` 注入的 preamble 只为**无生成 loader 的第三方库**兜底 `load-shared-object`——`activate-natives` 即这一兜底子集。
- `chandler exec -- <cmd>` 只做第 2 步后 exec,给编辑器 LSP、CI、REPL(`chandler exec -- scheme`)用。

## 6. 兼容性测试矩阵(CI 约定)

| 轴 | 取值 |
|----|------|
| 运行时 | 标准 Chez(声明下界版 + 最新版)× Skiff(最新) |
| 场景 | init→add→install→run 冒烟;activate 双运行时;`(skiff …)` 依赖在纯 Chez 下的警告路径 |
| 平台 | ta6le 常跑;ta6osx/ta6nt 发版前 |

## 相关文档

- **skiff 项目**(独立仓库)— Skiff 运行时本体(Chez + libuv)
- [02-manifest-lock-spec.md](02-manifest-lock-spec.md) — `chez`/`skiff` 字段语法
- [08-bootstrap-security.md](08-bootstrap-security.md) — Chandler 自身在两种运行时下的分发
