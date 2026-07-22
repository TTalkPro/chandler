# Chandler × bake 协作接口设计

> 总原则(两份总设计既定):**chandler 供货、bake 烘焙**——`chandler` 读 `manifest.ss` 管依赖获取,`bake` 读 `recipe.ss` 管编译,两份清单互不共享。但 **bake 项目**的 pack 规范 §10 把「各依赖 `.so` 树」记为「Chandler 编译闭包」,而编译能力在 bake——本文把这条协作边界定成**显式接口**,消除职责悬空。

> **2026-07-22 对齐真实 bake 能力(重要修订)**:早期设计假定 bake 提供 `compile-tree` / `native` **子命令**(porcelain + `--dir`/`--dest`/`--pkg`/`--spec`)。**真实 bake 无这些子命令**——它只吃 `recipe.ss` 里的任务(`library-task`/`native-task`/`install-task` 等,`bake [-f <recipe>] <task>`)。故协作面改为:**chandler 生成一份临时 recipe,跑真实 bake 任务**。这与 `chandler install` 早已采用的做法(生成含 `install-task` 的 recipe 跑 `bake install-all`)一致。同时 `bake install` 落点改 **src/mt 拆分**(见 [bake designs/21],本仓 [01](01-cli.md)/[05](05-install-registry.md)),native 收进所属库 `<prefix>/<mt>/<lib>/native/`。

## 1. 职责矩阵(裁决悬空点)

| 事项 | 归属 | 接口形态 |
|------|------|----------|
| 依赖获取/锁定/物化 `lib/` | chandler | `manifest.ss` → `manifest.lock` |
| 应用自身编译 | bake | `recipe.ss` |
| **依赖闭包编译**(pack 需要) | **bake 执行,chandler 排单** | `chandler build` = 生成 recipe(单根 lib/src + 逐依赖 library-task)跑真实 bake(§2) |
| **native 构建**(依赖声明的) | **bake 执行,chandler 授权+排单** | 同上;授权的 native 落成生成 recipe 里的 native-task(§3) |
| 全局安装注册表 | 共享库 `(chandler registry)` | bake install 复用([05 §6](05-install-registry.md)) |
| pack 组装 | bake | 消费 chandler 的编译闭包产物(§4) |

裁决:pack 规范里的「Chandler 编译闭包」理解为**「chandler 负责让闭包处于已编译状态」**——编译动作本身永远是 bake 的;chandler 只知道「闭包有哪些、顺序如何」,不知道「如何编译一个库」。

## 2. `chandler build`:排单协议(生成 recipe → 真实 bake)

```
chandler build [--allow-build] [--production]:
  1. 读 lock,取拓扑序;要求 lib/src 已在(install 已把各依赖源摊平进 lib/src/)
  2. 收集 native 声明并校验授权(§3);未授权即停
  3. 于**项目根**生成一份临时 recipe(.chandler-build.ss):
       (define-lib-roots "lib/src")                 ; 单根即含全部依赖源 → 跨依赖 import 自然解析
       (native-task '<soname> (lib <dep>)           ; 每个已授权 native 项(§3)
         (dir "vendor/<dep>/<path>") (build <后端>))
       (library-task 'c-<dep> '(<dep>)) …           ; 逐依赖编译(bake DAG 自排 import 序)
       (task 'build-all '(<native…> c-<dep>…) …)
       (default-task 'build-all)
     跑 `bake -f .chandler-build.ss build-all`(cwd=根)→ 产物落根的 _build/<mt>/
  4. 把 _build/<mt>/ 整棵拷进 lib/<mt>/(排除 .bake-manifest / *.wpo),补齐 src/mt 对
  5. 应用自身:用户另跑 bake build(recipe.ss)
```

- **为何单根 `lib/src`**:`chandler install` 已用 `bake install` 把**全部** git 依赖的源码摊平并存进 `lib/src/`(结构同全局前缀 `<prefix>/src`)。故编译时只需一个搜索根即可解析所有跨依赖 import(展开期宏依赖上游亦然)——**无需**逐依赖组装 `--libdirs`(真实 bake 的 `library-task` 也不认 `CHEZSCHEMELIBDIRS`,只认 recipe 的 `define-lib-roots`)。bake 的 DAG 按 import 图自排编译序,吃其指纹增量(内容哈希+flags+Chez 版本+mt)与 WPO 统一注入。
- **不需要依赖带 `recipe.ss`**——**布局规范就是隐式构建描述**;依赖带 `recipe.ss` 也**不执行**(别人的代码,信任模型见 §3)。
- 产物先落根的 `_build/<mt>/`(源码树 `lib/src` 不被写入 `.so`,保持干净),chandler 再拷进 `lib/<mt>/`,与源码 `lib/src/` 成 src/mt 对;native 收进所属库 `lib/<mt>/<dep>/native/`(bake native-task 的落点不变量)。

## 3. native 构建:授权与执行的分工

- **授权在 chandler**:`--allow-build` 是 chandler 旗标;缺省时遇到 native 声明即停,列出「哪些包」供审计后重跑。授权范围可细化:`--allow-build=sqlite,osi` 白名单;授权**绑构建描述哈希**写 `.chandler-approvals`,脚本掉包则失效重提示([08 §3](08-bootstrap-security.md))。
- **执行在 bake**:chandler 把每个获批 native 项落成生成 recipe 里的一条 `(native-task '<soname> (lib <dep>) (dir "vendor/<dep>/<path>") (build <后端>))`(后端 = 依赖 manifest 里的 `(build …)` 原样透传:`make` / `(script …)` / `(cmake …)`);bake 按其总设计跑后端(`chez-api` 注入、落点 `_build/<mt>/<dep>/native/<soname>.<ext>` 校验)。native 源在依赖 checkout 的 `vendor/<dep>/<path>`(默认 `native/<soname>`)。
- 信任判定始终是「**谁写的**」:依赖的 native 构建 = 别人的代码 → 须授权;根项目自己 manifest 里 `(path …)` 的 native = 自己的代码 → `chandler build` 默认放行(与 recipe.ss 的 `run`/`sh` 同级信任)。

## 4. pack 时序(全链路)

```
chandler install               ; 闭包锁定+物化 → lib/{src,<mt>}(只发源码)
chandler build --allow-build   ; 依赖闭包编译 + native(生成 recipe,真实 bake 执行)→ lib/<mt>/
bake build                     ; 应用自身编译(recipe.ss)
bake pack --mode modules       ; 组装:应用 _build/<mt>/ + 依赖 lib/<mt>/(含各库 native/)
                               ;      + skiff 运行时 + pack.manifest
```

`bake pack` 开始前校验闭包完整:lock 每项在 `lib/<mt>/` 有对应产物,缺 → 报「先跑 chandler build」。

## 5. 共享实现:`(chandler …)` 库族给 bake 复用

bake 是独立工具,但按依赖方向 **bake → chandler 库**(反向禁止,chandler 不 import bake):

| 库 | 导出 | bake 用途 |
|----|------|-----------|
| `(chandler util)` | 字符串工具、`alist-ref`、`ignore-errors` 宏 | 通用底座 |
| `(chandler fs)` | 原生文件系统操作(枚举/拷贝/删除/递归) | compile-tree 遍历、产物拷贝 |
| `(chandler lock)` | lock 读取/拓扑序 | pack 校验闭包、排 native |
| `(chandler registry)` | 注册表事务([05](05-install-registry.md)) | `bake install`/`uninstall` |
| `(chandler layout)` | 布局规范路径推导(库名↔路径、native 落点、`so-ext`) | compile-tree 遍历、pack 组装 |
| `(chandler sexp)` | manifest/lock/pack.manifest 的 read/pretty-print(禁求值) | 三份清单一个解析器 |

两工具各自独立分发,但 bake 的 manifest 依赖里有 chandler(自举顺序:先 chandler 后 bake,见 [08](08-bootstrap-security.md))。

## 6. 失败与幂等约定

- chandler 调 bake 一律子进程(生成 recipe + `bake -f <recipe> <task>`),非零退出即带上下文报出;临时 recipe 用毕即删(失败亦删)。
- bake DAG 保证依赖序;任一依赖编译失败即停,重跑从 bake 指纹增量续起;
- `chandler build` 幂等:全部命中指纹时 bake 是 no-op(秒回),chandler 再幂等拷 `_build/<mt>/` → `lib/<mt>/`。

## 相关文档

- **bake 项目**(独立仓库)— 编译语义(指纹/WPO/并行)与 native 后端权威、`bake pack` / pack 规范
- [05-install-registry.md](05-install-registry.md) — 共享注册表
