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

- 解释器定位:`--runtime-path` 旗标 > `CHANDLER_SCHEME` / `CHANDLER_SKIFF` 环境变量 > PATH。
- 版本探测:`scheme --version`(stderr)/ `skiff --version`;区间校验失败 fail fast,措辞同 pack 规范 `verify-target!` 风格(expected vs actual + 修复建议)。
- **依赖侧校验**:解析时对每个 dep 的 `chez`/`skiff` 声明同样求交——纯 Chez 项目引入「仅 skiff」的依赖(声明了 `(skiff …)` 且未声明 `chez`)→ 警告;运行 `scheme` 时该依赖 import `(skiff …)` 自会硬错,Chandler 提前把话说明白。

## 4. `activate` 的双运行时行为

`(chandler)` 库的 `activate` 在两种运行时下**代码路径完全相同**(挂 `library-directories` + topo 序 `load-shared-object` natives);差异只有一处版本门:

```scheme
(define (activate . maybe-root)
  (verify-runtime! (read-manifest …))   ; ① chez/skiff 区间门:探测当前运行时
  …)                                     ; ② 以下与总设计草案一致

(define (current-runtime)                ; 探测:skiff 存在性以其标志绑定为准
  (if (top-level-bound? 'skiff-version) 'skiff 'chez))
```

- Skiff 侧约定:运行时暴露顶层 `skiff-version`(字符串)。`current-runtime` 据此判别——**不**用可执行文件名猜(可能被符号链接/嵌入)。
- `verify-runtime!` 只在**根项目** manifest 有 `chez`/`skiff` 声明时启用;失败即抛,措辞含双边版本。
- Skiff 的 `--app` 部署态(pack)**不走 activate**(pack 规范 §4 自带加载逻辑),两者策略对齐(infra 统一载 native)但代码独立——部署态无 Chandler。

## 5. `chandler run` 全流程(双运行时)

```
chandler run app.ss:
  1. 读 manifest + lock;选解释器(§3 表)并版本校验
  2. 组装 CHEZSCHEMELIBDIRS = lib/<各依赖>/<srcdir> … : 既有值   ; 展开期即可解析,免脚本内 activate
  3. exec: <interp> --script app.ss <args…>
     ; 脚本内仍可写 (import (chandler)) (activate) —— 幂等,重复挂载无害
```

- `run` 用**环境变量前置**而非依赖脚本顶层 `(activate)`:这样 whole-program/编译型入口也能跑(总设计「expand-time 坑」的官方出口)。native 加载仍需运行期动作:`run` 注入 `--script` 前先 load 一段 preamble(`(import (chandler)) (activate-natives)`)——`activate-natives` 是 `activate` 的 native-only 子集,新增导出。
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
