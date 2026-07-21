# 依赖解析设计:传递闭包、冲突规则、拓扑序

> 输入:根 `manifest.ss`(+ `overrides`);输出:平铺的 `manifest.lock`。git-first 意味着**没有全局版本空间可求解**——同名依赖的「版本」就是不同的 (URL, rev),解析器的职责是**收集闭包 + 裁决同名冲突 + 定序**,不是 SAT 求解。刻意选 rebar3 的**层序裁决**而非 cargo 的 SemVer 统一,因为 git pin 之间大多不可比。

## 1. 算法:BFS 层序收集

```
resolve(root-manifest):
  frontier ← root 的 deps(+ 非 --production 时 dev-deps,标 scope=dev)
  chosen   ← {}          ; name → (source pin rev depth …)
  depth    ← 1
  while frontier 非空:
    对 frontier 中每项(并行 fetch,见 04):
      解析 pin → rev(tag/branch → git ls-remote / 缓存;version 区间 → 列 tag 择优)
      读该 rev 下的 manifest.ss(无 → 三级来源兜底,见 02 §3;overrides 最高优先)
      若 name ∉ chosen → 记入 chosen(带 depth)
      若 name ∈ chosen → 冲突裁决(§2),胜者留任
    frontier ← 本层新进 chosen 者的 deps(去掉已定名);depth++
  按 chosen 的 deps 关系建图 → 环检测(§3)→ 拓扑序 → 写 lock(字典序平铺,deps 字段保图)
```

要点:

- **同名即同库**:库名是身份(它决定 `(import (<name> …))` 落哪个目录),同名不同 URL 也是冲突,进 §2 裁决——**绝不并存**(`lib/<name>/` 只有一个)。
- dev-deps 只在**根**收集;传递依赖的 dev-deps 一律忽略(rebar3/cargo 同)。
- `path` 依赖参与闭包计算(要读它的 manifest 收传递依赖)但自身不进 lock。

## 2. 冲突裁决:层近者胜 + 根强制 + 逐条报告

同名多来源/多 pin 时:

| 规则 | 内容 |
|------|------|
| R1 根覆盖 | 根 manifest 直接声明的,无条件胜(用户意图最高) |
| R2 层近者胜 | 否则 depth 小者胜;同 depth 按 BFS 先见者胜(rebar3 语义,确定性来自 deps 声明顺序) |
| R3 恒警告 | 任何裁决发生即打印:胜者/败者的 (URL, pin, 引入路径),提示可在根 manifest 显式声明或 `overrides` 定夺 |
| R4 硬错误 | 同名但 URL 完全不同域(疑似撞名两个库)→ 默认**错误**而非静默裁决;根 `overrides` 显式指定来源可放行 |

理由:git pin 间无全序,「取更高版本」无定义;层近者胜简单、可解释、可被根强制推翻。区间 pin(`version`)同名相遇时先尝试**区间求交**,交集内取最高 tag;交空 → 按 R1/R2 裁决并警告。

## 3. 环检测

R6RS 库不允许 import 环,但**仓库级**环可能出现(A 仓库依赖 B 仓库、B 又依赖 A——库级未必成环)。处置:

- 仓库级环:**警告**并以任意一致顺序断环进拓扑(checkout 无先后困难;仅 native 加载顺序受影响,断环点记录进警告);
- native 加载序仍按断环后的拓扑序;若运行时 dlopen 因此失败,用户可在根 manifest 用 `overrides` 调整或显式声明先后;
- 库级环:不归 Chandler 管,Chez 展开期自会报错。

## 4. 拓扑序的消费方

lock 的 `resolved` 平铺按**字典序**存(diff 稳定),各项 `deps` 字段保留图;消费方需要序时现算:

| 消费方 | 用途 |
|--------|------|
| `activate` | native `load-shared-object` 按依赖先行序(Windows DLL 导入解析需要,总设计既定) |
| `chandler build` → bake | 依赖编译顺序:被依赖者先编(展开期需要其 `.so`/源可见,见 [07](07-bake-integration.md)) |
| `bake pack` | 编译闭包完整性校验(所有 lock 项都有编译产物) |

## 5. `update` 的增量语义

| 命令 | 行为 |
|------|------|
| `chandler update` | 全量重解析:branch pin 重问远端 HEAD,version 区间重列 tag;tag/rev pin 结果不变但传递闭包可能变 |
| `chandler update json http` | 只重解析这两个名(及其传递闭包**新增**部分);其余 lock 项原样保留 |
| `chandler install`(manifest 变更后) | 等价于「最小 update」:仅 manifest 中变动的条目重解析 |

不可复现 pin(branch)在 lock 中标 `(pin (branch "main"))` 原样保留,`verify` 对其只查 rev 匹配、不查是否落后远端(落后与否是 `update` 的事)。

## 6. 与「难点 2:没有元数据标准」的对账

三级来源(overrides > 上游 manifest > 裸库默认,[02 §3](02-manifest-lock-spec.md))意味着:**上游零配合也能用**(消费方在 overrides 写全传递信息),上游肯放一个 manifest.ss 则体验更好。这是 git-first 不建中心 index 的代价与解法——把 Akku 的 curation 职责下放到每个消费方的 overrides,辅以生态内(Skiff 系库)统一守[布局规范](../chez-skiff-library-layout.md)把默认值做对。

## 相关文档

- [02-manifest-lock-spec.md](02-manifest-lock-spec.md) — lock 格式与 overrides
- [04-fetch-cache.md](04-fetch-cache.md) — 解析期的 ls-remote/tag 列取走缓存
