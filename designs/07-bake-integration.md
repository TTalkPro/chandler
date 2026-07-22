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
  1. 读 lock,取拓扑序;要求 vendor/<dep>/ 已在(install 已整仓 checkout)
  2. 收集 native 声明并校验授权(§3);未授权即停
  3. 按拓扑序**逐个依赖**,在**它自己的 vendor/ 树里**生成临时 recipe 并跑 bake:
       ;; vendor/<dep>/.chandler-build.ss   (cwd = vendor/<dep>)
       (define-lib-roots "." (prebuilt "<项目>/lib"))  ; 仓库根=搜索根;已装好的依赖作预构建根
       (native-task '<soname> (lib <dep>) (dir "<path>") (build <后端>))  ; 已授权项(§3)
       (library-task 'c-<rel> "<rel>") …               ; 该树里的**每一个库**(见下)
       (task 'build-all '(…) …)
       (install-task   'install   (lib <dep>) (from ".") (needs build-all)
                       (target (prefix "<项目>/lib")))
       (uninstall-task 'uninstall (lib <dep>) (target (prefix "<项目>/lib")))
     先 `bake -f … uninstall`(容错;首次无清单)再 `bake -f … install`
  4. 应用自身:用户另跑 bake build(recipe.ss)
```

**分工(2026-07-22 修订)**:**bake 只负责编译,以及安装到指定位置**;chandler 老实遍历 `vendor/`,一个一个交给 bake。搬运不再由 chandler 手做 —— `_build/<mt>/` → `lib/<mt>/` 本来就是 `bake install` 的事(src/mt 拆分,排除项也由它统一)。每个依赖在**自己的树里**构建,各有各的 `_build/<mt>/`,彼此不混。

**拓扑序要紧**:A 依赖 B 时,编 A 需要 B 已在 `lib/` 里 —— 故逐个装,并把已装好的部分作**预构建对象根** `(prebuilt "<项目>/lib")` 挂进去(bake designs/25:对象式消费,不重编)。

**编的是整棵树,不是 umbrella 闭包**:一个库包的整棵源码树就是它的公开面,消费方会 import umbrella 从不引用的子库(chez-markding 的 `extensions/` 全是选择性启用的,umbrella 一个都不 import)。只编 umbrella 闭包,装出来的 `lib/<mt>/` 就残缺 —— **实测 107 个源码库只出 49 个对象**。残缺还会被悄悄掩盖:消费方的 bake 遇到没有对象的库会退回从 `lib/src/` 现编进**应用自己的** `_build/<mt>/`(designs/25 分类第 4 档),同一个依赖被劈成两棵对象树,看着能跑而已。枚举时只收**首个 datum 为 `(library …)`** 的文件 —— 包里的测试程序/脚本交给 bake 会走 `compile-program`,既无意义也可能失败。

- **为何在依赖自己的树里编**:布局规范就是「仓库根 = 搜索根」,在 `vendor/<dep>/` 里 `(define-lib-roots ".")` 正是该依赖作者本来的构建姿势;产物落它自己的 `_build/<mt>/`,再由 `bake install` 按 src/mt 拆分装进项目 `lib/`。跨依赖 import 靠**已装好的** `lib/` 作预构建根解析,这也顺带保证了拓扑序不能乱。bake 的 DAG 按 import 图自排编译序,吃其指纹增量(内容哈希+flags+Chez 版本+mt)。
- **不需要依赖带 `recipe.ss`**——**布局规范就是隐式构建描述**;依赖带 `recipe.ss` 也**不执行**(别人的代码,信任模型见 §3)。
- 产物落各依赖自己的 `vendor/<dep>/_build/<mt>/`,由 `bake install` 装成 `lib/{src,<mt>}` 对;native 收进所属库 `lib/<mt>/<dep>/native/`(bake native-task 的落点不变量)。**重装前先按 bake 自己的安装清单精确卸载** —— `chandler install` 已经装过一次(只发源码),而 `bake install` 见到已装会 bail。

## 3. native 构建:授权与执行的分工

- **授权在 chandler**:`--allow-build` 是 chandler 旗标;缺省时遇到 native 声明即停,列出「哪些包」供审计后重跑。授权范围可细化:`--allow-build=sqlite,osi` 白名单;授权**绑构建描述哈希**写 `.chandler-approvals`,脚本掉包则失效重提示([08 §3](08-bootstrap-security.md))。
- **执行在 bake**:chandler 把每个获批 native 项落成生成 recipe 里的一条 `(native-task '<soname> (lib <dep>) (dir "vendor/<dep>/<path>") (build <后端>))`(后端 = 依赖 manifest 里的 `(build …)` 原样透传:`make` / `(script …)` / `(cmake …)`);bake 按其总设计跑后端(`chez-api` 注入、落点 `_build/<mt>/<dep>/native/<soname>.<ext>` 校验)。native 源在依赖 checkout 的 `vendor/<dep>/<path>`(默认 `native/<soname>`)。
- 信任判定始终是「**谁写的**」:依赖的 native 构建 = 别人的代码 → 须授权;根项目自己 manifest 里 `(path …)` 的 native = 自己的代码 → `chandler build` 默认放行(与 recipe.ss 的 `run`/`sh` 同级信任)。

## 4. pack 时序(全链路)

```
chandler install               ; 闭包锁定+物化 → lib/{src,<mt>}(只发源码)
chandler build --allow-build   ; 依赖闭包编译 + native(生成 recipe,真实 bake 执行)→ lib/<mt>/
bake build                     ; 应用自身编译(recipe.ss)
bake pack                       ; 组装:应用 _build/<mt>/ + 依赖 lib/<mt>/(含各库 native/)
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

## 5b. native 加载分层(对齐 bake designs/24,2026-07-22)

bake 现为每个带 native 的库**生成** `(<lib> native-loader)`,编译产物 `<mt>/<lib>/native-loader.so` 随交付树落位(install/pack 白拿)。作者的 FFI 模块 import 它并用 `native-foreign-procedure` 宏,`.so` 的定位/加载由生成代码按落点不变量完成。于是统一加载**降级为兜底**:

| 层 | 谁 | 何时 |
|----|----|------|
| **自加载(优先)** | bake 生成的 loader,库 invoke 期自定位 | 被 import 即生效,四态通吃,零使用方纪律;**惰性**(不引用 FFI 就不 dlopen) |
| **统一加载(兜底)** | chandler `activate` / setup / run / repl | 仅**非 bake 构建、无生成 loader** 的第三方库;与自加载重复时幂等 |

**chandler 侧零适配即命中**:loader 候选序第 2 条是「`(library-directories)` 每根的 obj 侧 `<obj>/<lib>/native/<soname>.<ext>`」,而 chandler 挂的正是 `lib/src::lib/<mt>` 对,obj 侧 `lib/<mt>` 恰是 native 落点 —— 挂好对即自加载生效(已实测:清空 `_build/` 后仅靠该对跑通;移走 native 则报 loader 自己的错)。

故 chandler 的预加载清单(`native-load-paths`)改为**滤掉自带 loader 者**:判据为该 native 所属库目录下是否有 `native-loader.so`(与 `native/` 同级,多段库名同理)。`chandler build` 无需改动——loader `.so` 在 `_build/<mt>/` 内,随既有整树拷贝进 `lib/<mt>/`。

## 6. 失败与幂等约定

- chandler 调 bake 一律子进程(生成 recipe + `bake -f <recipe> <task>`),非零退出即带上下文报出;临时 recipe 用毕即删(失败亦删)。
- bake DAG 保证依赖序;任一依赖编译失败即停,重跑从 bake 指纹增量续起;
- `chandler build` 幂等:全部命中指纹时 bake 是 no-op(秒回),chandler 再幂等拷 `_build/<mt>/` → `lib/<mt>/`。

## 相关文档

- **bake 项目**(独立仓库)— 编译语义(指纹/WPO/并行)与 native 后端权威、`bake pack` / pack 规范
- [05-install-registry.md](05-install-registry.md) — 共享注册表
