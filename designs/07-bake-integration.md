# Chandler × bake 协作接口设计

> 总原则(两份总设计既定):**chandler 供货、bake 烘焙**——`chandler` 读 `manifest.ss` 管依赖获取,`bake` 读 `recipe.ss` 管编译,两份清单互不共享。但 [pack 规范 §10](../chez-skiff-pack-spec.md) 把「各依赖 `.so` 树」记为「Chandler 编译闭包」,而编译能力在 bake——本文把这条协作边界定成**显式接口**,消除职责悬空。

## 1. 职责矩阵(裁决悬空点)

| 事项 | 归属 | 接口形态 |
|------|------|----------|
| 依赖获取/锁定/物化 `lib/` | chandler | `manifest.ss` → `manifest.lock` |
| 应用自身编译 | bake | `recipe.ss` |
| **依赖闭包编译**(pack 需要) | **bake 执行,chandler 排单** | `chandler build` = 按 lock 拓扑序逐依赖调 bake(§2) |
| **native 构建**(依赖声明的) | **bake 执行,chandler 授权+排单** | 同上;`--allow-build` 由 chandler 透传(§3) |
| 全局安装注册表 | 共享库 `(chandler registry)` | bake install 复用([05 §6](05-install-registry.md)) |
| pack 组装 | bake | 消费 chandler 的编译闭包产物(§4) |

裁决:pack 规范里的「Chandler 编译闭包」理解为**「chandler 负责让闭包处于已编译状态」**——编译动作本身永远是 bake 的;chandler 只知道「闭包有哪些、顺序如何」,不知道「如何编译一个库」。

## 2. `chandler build`:排单协议

```
chandler build [--allow-build] [--production]:
  1. 读 lock,取拓扑序(被依赖者先)
  2. 对每个 dep(依序;独立子树可并行,进程级):
     a. native 声明非空? → 交 bake 跑 native 后端(§3)
     b. 调 bake 编译该库树:
        bake compile-tree --dir lib/<dep>/<srcdir> --dest build/<mt>/lib/<dep>
                          --libdirs <已编译依赖的 build 树 + 各依赖 srcdir>
  3. 应用自身:提示用户跑 bake(或 --with-app 顺带调 bake build)
```

- **`bake compile-tree` 是新增的 bake 子命令**(接口属于 bake,消费者是 chandler):遍历 `<name>.ss` + `<name>/**/*.ss` 逐个 `compile-library`,吃 bake 已有的指纹增量(内容哈希+flags+Chez 版本+mt,bake 难点 4)与 WPO 统一注入(难点 6)。它不需要该依赖有 `recipe.ss`——**布局规范就是隐式构建描述**(这正是规范存在的意义);依赖带 `recipe.ss` 也**不执行**(别人的代码,信任模型见 §3)。
- `--libdirs` 由 chandler 组装:编译第 N 个依赖时,前 N-1 个的产物树与源码根都可见(展开期宏依赖要 import 上游)。
- 产物落**消费方项目**的 `build/<mt>/lib/<dep>/…`,不写回 `lib/<dep>/`(依赖 checkout 保持只读干净,`verify` 不受扰;native 产物是唯一例外,落点契约 `lib/<dep>/native/<mt>/`,bake 总设计既定)。

## 3. native 构建:授权与执行的分工

- **授权在 chandler**:`--allow-build` 是 chandler 旗标;缺省时遇到 native 声明即停,列出「哪些包、哪个后端、什么命令」供审计后重跑。授权范围可细化:`--allow-build=sqlite,osi` 白名单。
- **执行在 bake**:chandler 对每个获批 native 项调 `bake native --pkg lib/<dep> --spec <native项s表达式>`;bake 按其总设计跑后端(make/cmake/script、`chez-api` 注入、落点校验)。
- 信任判定始终是「**谁写的**」:依赖的 native 构建 = 别人的代码 → 须授权;根项目自己 manifest 里 `(path …)` 的 native = 自己的代码 → `chandler build` 默认放行(与 recipe.ss 的 `run`/`sh` 同级信任)。

## 4. pack 时序(全链路)

```
chandler install          ; 闭包锁定+物化
chandler build --allow-build   ; 依赖闭包编译 + native(bake 执行)
bake build                ; 应用自身编译(recipe.ss)
bake pack --mode modules --target <mt>   ; 组装:build/<mt>/ 应用树 + build/<mt>/lib/ 依赖树
                                          ;      + lib/*/native/<mt>/ + skiff 运行时 + pack.manifest
```

`bake pack` 开始前校验闭包完整:lock 每项在 `build/<mt>/lib/` 有对应产物树,缺 → 报「先跑 chandler build」。

## 5. 共享实现:`(chandler …)` 库族给 bake 复用

bake 是独立工具,但按依赖方向 **bake → chandler 库**(反向禁止,chandler 不 import bake):

| 库 | 导出 | bake 用途 |
|----|------|-----------|
| `(chandler lock)` | lock 读取/拓扑序 | pack 校验闭包、排 native |
| `(chandler registry)` | 注册表事务([05](05-install-registry.md)) | `bake install`/`uninstall` |
| `(chandler layout)` | 布局规范路径推导(库名↔路径、native 落点、`so-ext`) | compile-tree 遍历、pack 组装 |
| `(chandler sexp)` | manifest/lock/pack.manifest 的 read/pretty-print(禁求值) | 三份清单一个解析器 |

两工具各自独立分发,但 bake 的 manifest 依赖里有 chandler(自举顺序:先 chandler 后 bake,见 [08](08-bootstrap-security.md))。

## 6. 失败与幂等约定

- chandler 调 bake 一律子进程 + `--porcelain`(s-表达式结果落 stderr),失败带包名上下文重新报出;
- 任一依赖编译失败即停(拓扑序保证下游未开工),重跑从指纹增量续起;
- `chandler build` 幂等:全部命中指纹时是 no-op(秒回)。

## 相关文档

- [../chez-bake-build-tool-design.md](../chez-bake-build-tool-design.md) — 编译语义(指纹/WPO/并行)与 native 后端权威
- [../chez-skiff-pack-spec.md](../chez-skiff-pack-spec.md) — pack 消费本接口的产物
- [05-install-registry.md](05-install-registry.md) — 共享注册表
