# 02 — 依赖解析算法、冲突裁决、多版本语义

> 状态: 设计中

## 1. 一句话目标

定义 BFS 层序闭包收集算法、冲突裁决规则（R1-R4）、多版本语义，以及 prebuilt 路径的 resolve 行为。

## 2. 核心设计原则

### 2.1 git-first = 不可比版本空间

Chandler 是 **git-first** 包管理器：依赖的版本由 git tag/rev/branch 锚定，而非全局版本空间（如 crates.io 的 SemVer 求解）。这与 cargo 的 SemVer 求解有本质区别：

| 特性 | cargo | Chandler |
|------|-------|---------|
| 版本来源 | crates.io 索引 | git tag/rev/branch |
| 版本约束 | SemVer 区间 | tag / branch / rev / version 区间 |
| 求解目标 | 全局最优版本 | 满足约束的第一个有效锚点 |
| 可预测性 | 确定性求解 | 确定性 BFS 收集 |

**为什么选 rebar3 层序而非 cargo SemVer 求解**：

- cargo 需要全局版本空间来求解兼容区间，依赖中心索引服务
- Chandler 是 git-first，版本锚定在 git 而非 registry
- BFS 层序天然满足 Chandler 的需求：先到先得，层近者胜
- 无全局版本空间可供 SemVer 求解，故不适用

### 2.2 BFS 层序收集

算法继承自原 design 03 的 BFS 收集：

1. **初始 frontier**：root manifest 的 deps（深度=1）
2. **队列展开**：每层按入队顺序处理（先根后子树）
3. **首见即选**：BFS 保证先遍历到的路径具有最小深度
4. **层近者胜**：深度越小，越接近根，优先级越高

```
root
├── A (depth=1)  ← 先入队，先处理
│   └── C (depth=2)
└── B (depth=1)
    └── C (depth=2)  ← 已在 chosen，跳过
```

BFS 保证 C 的第一个到达者（来自 A）被选中，即使 B 的 pin 可能不同。

### 2.3 冲突裁决规则 R1-R4

当同一个依赖名从不同路径到达时，按以下规则裁决：

| 规则 | 条件 | 行为 |
|------|------|------|
| **R1** | 根 manifest 直接声明的依赖 | 根覆盖一切 |
| **R2** | 传递依赖，且 depth 更小 | 层近者胜 |
| **R3** | 同 host 不同 pin/url | 警告，保留首见 |
| **R4** | 不同 host（撞名两个库） | 硬错 |

#### R1: 根覆盖

Root manifest 直接声明的依赖具有最高优先级，无论深度：

```scheme
;; root manifest
(deps
  (A (source (git "...")) (pin (tag "v1.0")))
  (B (source (git "...")) (pin (tag "v2.0"))))

;; A's manifest
(deps
  (C (source (git "...")) (pin (version ">=1.0"))))

;; B's manifest
(deps
  (C (source (git "...")) (pin (version ">=2.0"))))
```

C 的两个可能版本（v1.x 和 v2.x）冲突——R1 不适用（都是传递依赖），R2 适用：两者 depth 相同（都是 2），R3 警告，保留首见（A 的 v1.x）。

#### R2: 层近者胜

当同一依赖从不同深度到达时，浅者优先：

```scheme
;; root → A → C@1.0 (depth=2)
;; root → B → C@2.0 (depth=2)
```

深度相同，R3 触发。若 B 的 depth=1（更近根），则 R2 触发，保留 B 的 C@2.0。

#### R3: 同 host 警告

```scheme
;; 来源 A: https://github.com/example/lib
;; 来源 B: https://github.com/example/lib  (same host, different pin)
```

同源不同 pin/url → 警告，保留首见。这捕获了传递依赖版本漂移问题。

#### R4: 跨域硬错

```scheme
;; 来源 A: https://github.com/example/lib
;; 来源 B: https://gitlab.com/example/lib  (different host)
```

不同 host 的同名依赖被判定为**两个不同的库**，拒绝隐式合并。用户需要通过 overrides 显式解决。

### 2.4 多版本语义

**每个 app 的 manifest.lock 独立 resolve，跨 app 不冲突。**

这是 Chandler 多版本语义的核心设计：

| 视角 | 多版本表现 |
|------|-----------|
| **中央仓库视角** | 多个 versioned package 共存：`http/1.2.0/` 和 `http/1.3.0/` 可同时存在 |
| **单 app 视角** | 单版本：app 的 lock 只引用一个 version，通过 `(chandler setup)` 锁定 |
| **跨 app 视角** | 无冲突：app A 用 http/1.2.0，app B 用 http/1.3.0，完全独立 |

**为什么选择跨 app 多版本共存**：

- R6RS 运行时是硬单版本约束（一个进程内每个 library name 只能加载一个 version）
- Chandler 在**文件系统层**支持多版本共存，每个 app 通过自己的 `(chandler setup)` 锁定到具体版本
- 两个 app 用同一 lib 的不同版本完全互不干扰

**实现机制**：

- 中央仓库按 `<name>/<version>/` 存储多个版本
- app 启动时，run.sps 的 `(chandler setup)` 读本 app 的 manifest.lock，动态构造 `(library-directories)`
- 不同 app 的 lock 指向不同 versioned package，进程级别隔离

## 3. prebuilt source 的 resolve

### 3.1 选本机 mt 对应条目

resolve 时，根据当前机器类型（`ta6le`、`a6le` 等）选择 prebuilt source 中对应的 mt-entry：

```scheme
(source (prebuilt
  (mt ta6le (url "https://example.com/http-1.2.0-ta6le.tar.gz")
              (sha256 "abc123..."))
  (mt a6le  (url "https://example.com/http-1.2.0-a6le.tar.gz")
              (sha256 "def456..."))
  (git-fallback "https://github.com/example/http")))
```

若当前机器类型为 `ta6le`，选择第一个 mt-entry。

### 3.2 mt-gate 失败处理

若无对应 mt-entry 且无 git-fallback：

1. mt-gate 失败
2. 依赖不满足
3. resolve 报错或跳过（取决于 gate 类型）

### 3.3 git-fallback 回退

若无对应 mt-entry**但有** git-fallback：

1. 切换到 git-fallback 的 URL
2. 执行 git clone + 本地编译
3. 生成编译产物

git-fallback 提供了跨 mt 分发的兼容性机制。

## 4. version 区间 pin 的求交

### 4.1 区间语义

version pin 支持区间格式：

```scheme
(pin (version ">=1.0.0 <2.0.0"))
```

### 4.2 求交规则

当多个路径引用同一依赖的 version 区间时，求交运算：

```
root deps:      C [>=1.0.0 <3.0.0]
A's transitive: C [>=1.5.0 <2.5.0]
B's transitive: C [>=2.0.0 <3.0.0]
───────────────────────────────────
交集:           C [>=2.0.0 <2.5.0]
```

若交集为空，R3 触发警告，保留首见。

version.ss 已有 semver matcher 实现区间求交。

## 5. 环检测

### 5.1 仓库级环

当依赖图存在环时（如 A→B→C→A）：

1. **检测**：DFS 访问中遇到已标记为 `active` 的节点
2. **处理**：断环（忽略回边），继续解析
3. **警告**：向用户报告检测到的环

### 5.2 库级环

库级环（如 `(library (foo) (import (foo)))`）由 Chez 运行时处理，不在 Chandler 解析层处理。

## 6. update 增量语义

### 6.1 branch pin 重问 HEAD

当 manifest 中的依赖声明为 `(pin (branch "main"))`：

- update 时重新询问远端 HEAD
- 若 HEAD 变化，更新 lock 中的 rev

### 6.2 version 区间重列 tag

当 manifest 中的依赖声明为 `(pin (version ">=1.0 <2.0"))`：

- update 时重新列出远端所有 tag
- 筛选满足区间的 tag
- 选择满足条件的最新 tag

### 6.3 行为对比

| pin 类型 | update 行为 |
|---------|------------|
| `(tag "v1.0")` | 不变（精确锚定） |
| `(branch "main")` | 重问 HEAD |
| `(rev "abc123")` | 不变（精确锚定） |
| `(version ">=1.0 <2.0")` | 重列 tag，求最新满足 |

## 7. 具体 resolve 示例

### 7.1 场景

```
root manifest:
  deps: A, B
  A → C@1.0
  B → C@2.0
```

### 7.2 BFS 执行过程

1. **初始队列**：`[A(depth=1), B(depth=1)]`
2. **处理 A**：
   - fetch A's manifest
   - chosen[A] = A@tag-v1.0
   - 入队 C(depth=2, from=A)
3. **处理 B**：
   - fetch B's manifest
   - C 已在 chosen（A 先入队，A 先处理）
   - 触发 `arbitrate!`
   - A 和 B 的 C 版本不同（同 host：来自不同 tag）
   - R3 警告，保留首见（A 的 C@1.0）
4. **处理 C(depth=2)**：
   - C 已在 chosen，跳过

### 7.3 结果

lock 中 C 的版本为 A 的 C@1.0，警告信息记录：

```
warning: dependency C conflict: using A@tag-v1.0 (depth 2), ignoring B@tag-v2.0
```

## 8. 与 design 03 的差异

本设计继承并扩展了原 design 03 的解析算法，主要差异：

| 维度 | 原 design 03 | v2 |
|------|-------------|-----|
| prebuilt 路径 | 不支持 | 支持：选本机 mt 对应条目，无则 git-fallback |
| 多版本语义 | 未明确 | 明确：单 app 单版本，跨 app 多版本共存 |
| version 区间求交 | 有 | 有（复用 version.ss） |
| R4 跨域硬错 | 有 | 有 |
| 环检测 | 仓库级断环警告 | 仓库级断环警告（不变） |

## 相关文档

- [00-design-principles.md](00-design-principles.md) — 宪法，定义了多版本语义的基础
- [01-manifest-lock.md](01-manifest-lock.md) — manifest.lock schema
- [03-central-repo.md](03-central-repo.md) — 中央仓库如何使用 resolve 结果
- [06-prebuilt.md](06-prebuilt.md) — prebuilt 分发机制
- [07-chandler-setup.md](07-chandler-setup.md) — `(chandler setup)` 如何使用 lock
