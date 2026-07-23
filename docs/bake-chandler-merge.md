# 要不要把 bake 与 chandler 合并?

> 状态:**方向已决(2026-07-23 更新)**。原 §0–§4 分析保留作决策记录;§5 起为更新后的方案。
> 相关:[07](../designs/07-bake-integration.md)(与 bake 的分工裁决)· [08 §3](../designs/08-bootstrap-security.md)(清单只读不求值)·
> [12](../designs/12-chandler-layering.md)(runtime 子集 / 运行时门)· bake designs/26、27(install / pack / self-install 移交 chandler)。

## 0. 先核对现状(不是印象,是数字)

| | bake | chandler |
|---|---|---|
| 规模 | `bake/*.ss` + `bake.ss` ≈ **2 966 行** | `chandler/**` + umbrella + bootstrap ≈ **5 294 行** |
| 模块 | cli / compile / deps / dispatch / dsl / engine / globals / import-graph / init / loader / main / miniregex / native / output / records / runtime / sha256 / util | util / fs / proc / hash / sexp / layout / version / manifest / lock / fetch / resolve / install / registry / runtime-detector / runtime-paths / activate / build / pack / base / cli.* |
| 相互依赖 | **零**——bake 不 import 任何 `(chandler …)` | 只在 `chandler build` 里**子进程**调 `bake` |

历史轨迹是**单向的**:bake 一直在卸责任(designs/26 删 install-task/uninstall-task、
designs/21 §二 把 pack 交出、designs/27 删 self-install),裁决写在 [07 §1](../designs/07-bake-integration.md):
**编译动作永远是 bake 的,组装与部署是 chandler 的。** 于是今天 bake 收敛成一个纯构建引擎。

问题是:**两个工具零代码共享,却共享一堆不变量**——

1. `<mt>` 分区与前缀形状(`<prefix>/{src,<mt>,share,.chandler}`);
2. native 落点 `<lib>/native/<soname>.<ext>`;
3. 生成的 native-loader 候选序,其中候选 1 是 `$APP_ROOT/<mt>/<libpath>/native/`;
4. `APP_ROOT` 的语义(= 库前缀);
5. machine-type → so 扩展名的推导;`(源 . 对象)` 目录对的拼法。

而且**基础设施是重复实现的**:bake 有自己的 `sha256.ss`(129 行)、`util.ss`(207)、`runtime.ss`(103);
chandler 有 `hash.ss`(120)、`util.ss`(103)、`runtime-detector.ss`(84)、`layout.ss`(109)。
同一件事各写一遍,共约 **900 行重复面**。

**代价不是理论上的。就在今天一小时内撞了两次:**

- bake 0.1.5 删掉 `install-task`,chandler 的 `recipe.ss` 里还留着 → **整份 recipe 加载失败**,
  连 `bake build` 都跑不了,连带前缀里的对象刷新不了,最终表现成一个莫名其妙的 `unbound identifier`;
- chandler P1 改了包布局(去掉 `lib/` 前缀),bake 生成的 loader 候选 1 仍拼旧路径 → 恒 miss,
  只是恰好被候选 2 兜住才没炸。

这两件事的共同点:**不变量写在两处,靠人肉同步。**

## 1. 先区分「合并」的三个层次

不区分就会各说各的。

| | M1 合并发行 | M2 共享底座 | M3 合并概念 |
|---|---|---|---|
| 做什么 | 单仓、单二进制;内部仍是 `bake/` 与 `chandler/` 两层库,`chandler build` 变成**进程内调用** | 两仓、两 CLI 不变;bake 通过 chandler 的**运行时门**依赖 `(chandler base)`,共用 sha256/util/layout/运行时探测与不变量常量 | 一个工具、一套声明:`manifest.ss` 里既写依赖也写构建,`recipe.ss` 消失 |
| 消灭版本漂移 | ✅ 彻底(同一次发布) | ⚠️ 部分(lock 钉住版本,门校验区间) | ✅ |
| 消灭重复实现 | ✅ | ✅ | ✅ |
| 删掉 subprocess + 生成 recipe | ✅ | ❌ | ✅ |
| 改动量 | 中(合仓 + 自举 + 测试合并) | **小**(bake 侧删 3 个模块,加一个门) | 大,且撞安全红线(见 §2) |
| 保留「只要构建、不要包管理」的用法 | ✅(保留 `bake` 子命令/别名) | ✅ | ❌ |

## 2. 有一处**不能**合:清单是数据,recipe 是程序

M3 最诱人的地方是「一个文件说清一个项目」,但它撞上 chandler 的一条安全红线
([08 §3](../designs/08-bootstrap-security.md)):**`manifest.ss` 只 `read`,永不 `eval`。**
解析依赖清单要处理**第三方仓库**的清单——那是不可信输入,所以清单是纯数据、有白名单校验器。

而 `recipe.ss` 是**程序**:`(task 'test … (lambda () (run "scheme" …)))`,任意 Scheme 代码,
加载即求值。两者合成一个文件只有两种结果:

- 要么让清单变得可求值 → 解析一个第三方依赖的清单就等于**执行它的代码**,红线破了;
- 要么仍然是两个文件 → 那合并的只是仓库,不是概念。

所以 M3 应当**否决**。真正的重复不在「两个文件」,而在两个文件里**同一件事各说一遍**——
例如 native 构建:`manifest.ss` 有 `(native …)` 声明,`recipe.ss` 又有 `native-task`。
这类重复该用「清单是唯一事实来源、chandler 据此**生成**给 bake 的构建描述」来解决
(`chandler build` 今天生成 `.chandler-build.ss` 已经是这个思路),而不是把两个文件揉成一个。

## 3. 有一处**应该**合:底座与不变量

这正是 M2,而且 chandler 刚刚做完的机制天然适配:

- [12](../designs/12-chandler-layering.md) 已经定义了 **runtime 子集**(`(chandler base)` = hash/version/util/fs/sexp/layout/
  runtime-detector/proc/runtime-paths)——**一个不含包管理逻辑的公共底座**;
- 刚落地的**运行时门**让 bake 只需在自己的 manifest 里写 `(chandler ">=0.1.x")`,
  实体取自全局前缀,零 URL、零 fetch;
- 于是 bake 删掉自己的 `sha256.ss` / `util.ss` / `runtime.ss`(≈440 行),
  改 import `(chandler base)`;而**不变量常量**(前缀形状、native 落点、loader 候选拼法、mt→so-ext)
  收敛进 `(chandler layout)`,bake 从那里读。

这样今天那两次漂移**在结构上不可能再发生**:候选路径只有一个定义,谁也没法单方面改。

代价:bake 从此需要一个装好的 chandler 才能构建自己——**自举链变长**。
缓解办法是 bake 的 `bootstrap.ss` 保持自含(它现在就是),把这条依赖限定在「bake 的日常构建」而非「首次自举」。

## 4. M1(单仓单二进制)值不值

M2 之后仍留着一件事:`chandler build` 生成 recipe → 起 `bake` 子进程 → 解析 porcelain → 翻译退出码,
外加 `CHANDLER_BAKE` 环境变量这条逃生口。M1 把它变成**函数调用**,删掉的是:

- `.chandler-build.ss` 的生成与清理、子进程与退出码翻译、`CHANDLER_BAKE`;
- 两套 CLI 各自的 help/版本/运行时发现/启动器(今天各有一份 sh + ps1 启动器与探测逻辑);
- 两条自举链(两个 `bootstrap.ss`)合成一条;
- 「装 bake 还是装 chandler」的用户困惑:装一个。

保留的是**内部分层**——`bake/` 仍是独立的库树,只是不再跨进程。对外可以继续提供 `bake` 这个名字
(薄 alias 或 `chandler bake …` 子命令),纯构建用户体感不变。

真正的成本:

1. **发布节奏合并**——bake 的编译内核改动会带上 chandler 的版本号;反过来包管理的小修也会推动构建工具发版。
   这是**唯一**真实的损失,但两个工具同一个作者、同一套不变量,今天的独立节奏并没有换来独立性,
   只换来了漂移。
2. **测试合并**:bake ≈243 断言 + chandler 225 用例,合仓后一次全跑变长(可分 suite)。
3. **一次性迁移**:命名空间(`(bake …)` 保持不变即可)、目录、CI、文档、两个 README 的合并。

## 5. 结论(2026-07-23 更新)

方向已定,不再是「要不要合」,而是「怎么合」。三条要求合为一个连贯架构:

- **M3(合并概念)仍否决** —— 理由不变(§2):清单只 `read` 不求值。
- **M2(共享底座)已完成** —— `(chandler base)` umbrella + 运行时门已落地(P1c / 阶段 13)。
  bake 的 sha256/util/runtime(~439 行)随时可删、改 import `(chandler base)`。
- **M1(单仓单二进制)升格为全吸收** —— 不止「合仓 + 进程内调用」,而是将 bake 的**编译引擎整体
  搬进 chandler 的 dev-time 层**(§7)。chandler 从包管理器变成包管理器 + 构建器。
- **命令职责重新划分** —— `build` 只编译不安装;新增 `assembled` 是唯一把 `_build/` 组装进 `lib/` 的
  阶段,且**不安装源码**(§8)。

| 要求 | 架构角色 | 状态 |
|---|---|---|
| ① chandler 分 runtime / dev-time | **三层边界**(§6) | 已落地;吸收 bake 时据此保持边界 |
| ② 继承 bake 全部能力 | **dev-time 层吸收编译引擎**(§7) | 待实施 |
| ③ 增加 assembled | **编译 + 组装的一步到位**(§8) | 待实施(依赖②) |

---

## 6. 三层架构

```
┌──────────────────────────────────────────────────────────┐
│ ③ assembled(用户命令)                                    │
│    编译全部(依赖 + 项目)→ 组装 lib/<mt>/ + resources    │
│    唯一把 _build/ 产物装进 lib/ 的阶段;不装源码           │
├──────────────────────────────────────────────────────────┤
│ ② dev-time 工具层                                         │
│    包管理:install / fetch / resolve / lock / manifest /  │
│           registry / activate / pack                      │
│    编译引擎(自 bake 吸收,§7):                           │
│           compile / native-build / import-graph /          │
│           task-engine / recipe / miniregex                │
│    CLI: chandler {init, install, build, assembled,        │
│                   run, repl, pack, …}                     │
├──────────────────────────────────────────────────────────┤
│ ① runtime 公共基础设施 `(chandler base)`                  │
│    runtime-paths / hash / version / util / fs /           │
│    sexp / layout / runtime-detector / proc                │
│    随 lib/app 进 pack;bake 吸收后亦用此层                  │
└──────────────────────────────────────────────────────────┘
```

**关键不变量**:

- **runtime 层零编译逻辑** —— 吸收 bake 后编译引擎全部在 dev-time 层,`(chandler base)` 的 import
  闭包仍只含 9 个 runtime 子库。
- **dev-time 层复用 runtime 层** —— 编译引擎(原 bake/compile.ss 等)的 sha256/util/fs/layout
  全部走 `(chandler base)`,不再自带副本(消灭 §0 诊断的 ~900 行重复面)。
- **assembled 是 dev-time 层的编排** —— 它调用编译引擎 + 包管理,产出完整前缀,本身不含新算法。

### 与既有设计的关系

- [designs/12](../designs/12-chandler-layering.md) 定义了 runtime/dev-time 分层与 `(chandler base)` ——
  **本方案是其 dev-time 层的扩展**(填入编译引擎)。
- [designs/13](../designs/13-chandler-owns-install.md) 让 chandler 接管安装/卸载,bake 退化为纯编译引擎 ——
  **本方案是退化的终点**(bake 连编译也并进来)。
- [docs/single-build-prefix.md](single-build-prefix.md)(P4)提出 `lib/` 与 `_build/` 物理合一 ——
  **assembled 是其安全替代**:两目录保持分离(`_build/` 是编译 scratch、`lib/` 是组装结果),
  用一条命令把 `_build/` 组装进 `lib/`,比物理合并更安全(§8.6)。

---

## 7. bake 模块吸收清单

bake 共 18 个模块 + launcher + bootstrap ≈ 3318 行。分三处置:

### 删除:重复基础设施(→ 用 `(chandler base)`)

| bake 模块 | 行数 | 对应 chandler 模块 |
|---|---|---|
| `bake/sha256.ss` | 129 | `(chandler hash)` |
| `bake/util.ss` | 207 | `(chandler util)` + `(chandler fs)` |
| `bake/runtime.ss` | 103 | `(chandler runtime-detector)` + `(chandler proc)` |
| **小计** | **439** | 与 chandler 逐行对应,直接删、改 import |

### 吸收:编译引擎(→ chandler 新 dev-time 模块)

| bake 模块 | 行数 | → chandler 模块 | 职责 |
|---|---|---|---|
| `compile.ss` | 612 | `(chandler compile)` | library-task / compile-lib / 指纹增量 / 并行编译(`-j N` + `--compileone` worker)/ prebuilt roots / `define-lib-roots` |
| `native.ss` | 427 | `(chandler native-build)` | native-task / script·make·cmake 后端 / 落点校验 / 工具链指纹 / native-loader codegen |
| `deps.ss` | 312 | `(chandler import-graph)` | R6RS import 解析 / lib-node·dep-edge / 库闭包枚举 / 内建/预编/自有分类 / 环检测 |
| `engine.ss` | 156 | `(chandler task-engine)` | task·file·rule DAG / run-once 环检测 / mtime + 指纹判定 / 拓扑执行 |
| `dsl.ss` | 147 | `(chandler recipe)` | recipe DSL 宏(task/file/rule/default-task/library-task/native-task)|
| `loader.ss` | 68 | → 合入 `(chandler recipe)` | recipe 加载(eval in interaction-environment)+ native 预扫描 |
| `records.ss` | 36 | → 合入 `(chandler task-engine)` | task/rule/miniregex 记录类型 |
| `globals.ss` | 34 | → 合入 `(chandler task-engine)` | 版本常量 / 退出码 / flag 状态(*dry-run* 等) |
| `output.ss` | 40 | → 合入 `(chandler task-engine)` | 进度输出(show-begin/done/skip) |
| `miniregex.ss` | 70 | `(chandler miniregex)` | rule pattern 匹配器 |
| `import-graph.ss` | 71 | → `(chandler import-graph)` CLI 子命令 | `chandler import-graph --root <dir> <entry>` |
| **小计** | **~1973** | **6 个新 dev-time 模块** | |

### 合并 / 删除:CLI / init / launcher

| bake 模块 | 行数 | 处置 |
|---|---|---|
| `cli.ss` | 235 | 合入 `(chandler cli args)`:bake 的 `--recipe`/`--jobs`/`--clean`/`-T`/`-P` 变为 `chandler bake` 子命令参数 |
| `dispatch.ss` | 65 | 合入 `(chandler cli main)` |
| `init.ss` | 113 | 合入 `chandler init`(吸收 bake init 的 recipe 骨架生成) |
| `main.ss` | 29 | 删除(chandler 有自己的 main) |
| `bake.ss`(launcher) | 112 | 删除(加载逻辑由 chandler umbrella 统一) |
| `bootstrap.ss` | 352 | 删除(chandler 的 `bootstrap.ss` 统一安装) |
| **小计** | **~906** | |

### 吸收后的新 chandler dev-time 模块

```
chandler/
  compile.ss          (chandler compile)          ← bake/compile.ss
  native-build.ss     (chandler native-build)      ← bake/native.ss
  import-graph.ss     (chandler import-graph)      ← bake/deps.ss + import-graph.ss
  task-engine.ss      (chandler task-engine)       ← bake/engine.ss + records + globals + output
  recipe.ss           (chandler recipe)            ← bake/dsl.ss + loader.ss
  miniregex.ss        (chandler miniregex)         ← bake/miniregex.ss
```

> **命名注意**:根目录 `recipe.ss`(项目构建描述,用户写)与 `chandler/recipe.ss`(recipe DSL
> 实现,`(chandler recipe)` 库)同名不同路径。Chez 按路径解析不冲突,但文档需明确区分。

### import 改写

每个被吸收模块把 bake 内部 import 改为 chandler:

```scheme
;; 旧(bake/compile.ss)
(import (chezscheme) (bake sha256) (bake util) (bake runtime) (bake deps) (bake engine) …)

;; 新(chandler/compile.ss)
(import (chezscheme) (chandler base) (chandler import-graph) (chandler task-engine) …)
```

`bake/sha256`、`bake/util`、`bake/runtime` 统一改为 `(chandler base)`(已 re-export 全部所需)。

---

## 8. 命令职责重新划分:install / build / assembled

每个命令一个使命、一个产出:

| 命令 | 使命 | 产出 |
|---|---|---|
| `install` | 把整个项目安装到 `.local/share/chez` 格式 | `lib/` 的**源码侧**(`src/` + `share/` + `.chandler/`) |
| `build` | 编译依赖闭包(验证可编译) | `_vendor/<dep>/_build/`(scratch,**不碰 `lib/`**) |
| `assembled` | 组装全部编译产物进前缀 | `lib/<mt>/`(**对象侧**)+ 刷新 resources |

`install` + `assembled` = 完整前缀(与 `~/.local/share/chez` 同构)。

### 8.1 核心变更

**今天的 `chandler build` 混了两件事**:编译依赖(bake 子进程)+ 把产物搬进 `lib/<mt>/`
(`install-dep-objects!`,build.ss:124)。新方案将它们拆开:

| 命令 | 编译? | 装源码? | 装 `_build/` → lib/? | resources? |
|---|---|---|---|---|
| `install` | ✗ | **✓** → `lib/src/` | ✗ | ✓ → `lib/share/` |
| `build` | ✓ dep → `_vendor/<dep>/_build/` | ✗ | **✗**(产物留在 `_build/`,不动 `lib/`) | ✗ |
| **`assembled`** | **✓** dep + project | **✗ 不装源码** | **✓ 唯一装 `_build/` → `lib/<mt>/`** | ✓ sync → `lib/share/` |

**三条规则**(用户 2026-07-23 明确):

1. **`build` 不再把 `_vendor/*/_build/` 装进 `lib/`** —— 编译产物留在各依赖自己的 `_build/` 里,
   `lib/` 不被 `build` 碰。
2. **`assembled` 是唯一把 `_build/` 组装进 `lib/` 的阶段** —— 项目的 `_build/<mt>/` +
   各 `_vendor/<dep>/_build/<mt>/` 全部装进 `lib/<mt>/`。
3. **`assembled` 不安装源代码** —— 源码由 `install` 负责;`assembled` 只搬编译产物 + resources。

### 8.2 各命令的精确语义

#### `chandler install` — 把整个项目安装到 `.local/share/chez` 格式

`install` 的任务是产出 `lib/` 的**源码侧**,让 `lib/` 在结构上与 `~/.local/share/chez/` 逐一对应
(只差对象侧 `<mt>/`,那由 `assembled` 补)。

```
install → vendor/<dep>/ (git checkout)
        → lib/src/<dep>.ss + lib/src/<dep>/** (依赖源码摊平)
        → lib/share/<dep>/resources/ (依赖资源)
        → lib/.chandler/<app>/manifest.ss (清单快照)
```

不编译、不碰 `lib/<mt>/`。装完 `lib/` 已是可用前缀(源码态):`chandler run`(解释执行)、
`chandler repl` 立即可用。全局安装 = 把 `lib/` merge 进 `~/.local/share/chez/`
(`chandler install --global`),格式已对齐,无需转换。

#### `chandler build` — 纯编译(行为变更)

```
build → 逐依赖(拓扑序):
          生成 .chandler-build.ss → 编译 → _vendor/<dep>/_build/<mt>/
        【不调 install-dep-objects!】【不碰 lib/<mt>/】
```

**变更点**:删除 `bake-one-dep` 里的 `install-dep-objects!` 调用(build.ss:107)。
编译产物留在 `_vendor/<dep>/_build/<mt>/`,`lib/` 原封不动。

**用途**:CI 验证依赖可编译、预热编译缓存、单独检查编译错误。
`build` 后 `lib/<mt>/` 仍为空 —— 要用编译产物须跑 `assembled`。

> **拓扑序 + prebuilt 注意**:今天 `build` 在每依赖编译后立即装进 `lib/`,使下一依赖能以
> `(prebuilt "<project>/lib")` 消费已编好的对象(不重编)。去掉安装后,`lib/<mt>/` 无对象,
> 跨依赖 import 会从 `lib/src/` 现编进当前依赖的 `_build/`(bake designs/25 第 4 桥)。
> **正确性不受影响**(同源同编译器 = 同对象),但跨依赖闭包有冗余编译。
> 缓解:bake 吸收后(§7),可用 `(chandler import-graph)` 做单趟编译(一棵 `_build/` 树含全部依赖),
> 消除冗余。**此项为实现期优化,不阻塞方案落地。**

#### `chandler assembled` — 编译 + 组装(新增)

```
assembled [--allow-build[=…]] [--jobs N]:
  1. 校验前置:lib/src/ 存在(install 已跑)、manifest.lock 可读
  2. build(自动触发):编译依赖(拓扑序,逐个 install-dep-objects! 后再编下一个 ← prebuilt 机制正常)
     → _vendor/<dep>/_build/<mt>/ 编译 → lib/<mt>/ 安装(精确清旧 + 拷新产物)
  3. 编译项目自身(读根 recipe.ss → 编译 → _build/<mt>/)
  4. 组装项目对象:_build/<mt>/ → lib/<mt>/(项目同名对象覆盖依赖的,项目赢)
  5. 同步 resources:resources/ → lib/share/<app>/resources/(mtime 增量)
  6. 写 manifest 快照:lib/.chandler/<app>/manifest.ss
```

**assembled 自动包含 build**(步骤 2):无需先手动跑 `build`。指纹增量保证无变更时秒回。

**产出**:`lib/` 成为**完整前缀**,目录结构与全局前缀 `~/.local/share/chez/` 逐一对应。
`assembled` 的核心约束就是**忠实重现这个布局** —— 三态(项目 `lib/`、全局前缀、解开的 pack)
同一形状,`APP_ROOT` 指向哪个,应用代码一个字都不用改。

```
lib/                                          ← = ~/.local/share/chez 的同构副本
├── src/                          [install 铺]  源码侧
│   ├── <dep>.ss  <dep>/           ← 各依赖源码(install 摊平)
│   ├── <app>.ss  <app>/           ← 项目自身源码(install 摊平;或开发期原地,不拷)
│   └── chandler/                  ← chandler runtime subset(install 从全局前缀铺)
├── <mt>/                         [assembled 铺] 对象侧(如 ta6le/)
│   ├── <dep>.so  <dep>/           ← 依赖编译产物(assembled 从 _vendor/<dep>/_build/ 搬入)
│   ├── <dep>/native/*.so          ← 依赖 native(assembled 随对象树搬入)
│   ├── <dep>/native-loader.so     ← bake 生成的 native-loader(有 native 的库)
│   ├── <app>.so  <app>/           ← 项目编译产物(assembled 从 _build/ 搬入)
│   └── chandler.so  chandler/     ← chandler runtime 编译产物(install 已铺;assembled 不重搬)
├── share/                        [install + assembled 铺]  资源层
│   ├── <dep>/resources/           ← 依赖资源(install 从 vendor/<dep>/ 铺;assembled 重新同步)
│   └── <app>/resources/           ← 项目资源(assembled 从 resources/ 按 mtime 增量同步)
└── .chandler/                    [install + assembled 铺]  清单层
    └── <app>/manifest.ss          ← 项目清单快照(install 写;assembled 刷新)
```

**assembled 只碰上表的 `[assembled 铺]` 部分**:`lib/<mt>/`(全部编译产物 + native)+
`lib/share/`(重新同步 resources)。`lib/src/` 和 `lib/.chandler/` 由 `install` 负责 ——
**assembled 不安装源代码**。

**为什么 resources 要在 assembled 里重新同步**:`install` 时铺的 dep resources 可能已过时
(源码 checkout 后用户改了 vendor 里的文件,或 install 后 resources/ 有新增)。`assembled`
按 mtime 增量刷新(复用 `sync-app-prefix!`,install.ss:447),保证 `lib/share/` 与源同步。
这与全局前缀的 `share/` 结构完全一致:`share/<name>/resources/`,dep 与 app 各占一个命名空间。

**步骤 2 复用**:`install-dep-objects!`(build.ss:124)+ `clean-dep-objects!`(build.ss:117)
原样复用 —— 只是从 `build` 搬到 `assembled`。`build` 去掉此调用后,`install-dep-objects!` 的
**唯一调用方**变为 `assembled`。

**步骤 3**(bake 吸收后):`(load-recipe "recipe.ss")` + `(invoke-task 'build)`,进程内编译,
不再起 bake 子进程。

#### run / repl:自动组装 + 资源优先级

`chandler run` 和 `chandler repl` 是开发期主命令,有两个特殊行为:

**① 自动触发 assembled**(后者自动触发 build):

```
chandler run → auto assembled → auto build → 编译(增量) → 组装 → run
                                                 ↑
                                           无变更 = no-op,秒回
```

`chandler install` 一次后,`chandler run` 自给自足 —— 无需手动跑 build / assembled。
指纹增量保证:改了源码才重编,没改就秒过。

**② 资源优先级例外**(唯一绕过前缀的场景):

run/repl 上下文中,资源访问优先 `<project>/resources/`(项目根的源码态),
**而非** `lib/share/<app>/resources/`(前缀里的组装态)。目的是开发期改一个资源文件
立即生效,不必等 assembled 同步。

| 上下文 | 资源搜索优先序 |
|---|---|
| **run / repl**(开发期) | **`<project>/resources/` 优先** → `lib/share/<app>/resources/` 兜底 |
| pack / install --global(发布态) | `lib/share/<app>/resources/`(前缀唯一来源) |

> **实现方案:env var `CHANDLER_DEV_ROOT`**
>
> `app-resource-path` 运行在**应用进程**内(scheme 子进程),不在 chandler 进程里。它目前
> 只认 `APP_ROOT`(= 前缀 `<project>/lib`)。要让它在 run/repl 时优先读 `<project>/resources/`,
> 需要一条通道把「项目根」传进去 —— 不能改 `APP_ROOT`(那会破坏前缀语义)。
>
> 方案:沿用 `APP_ROOT` / `APP_NAME` 同款 env var 模式。`chandler run`/`repl`/`env` 在
> exec 前设 `CHANDLER_DEV_ROOT=<project>`,`app-resource-path` 读它。
>
> **谁设 / 谁不设:**
>
> | 上下文 | 设 `CHANDLER_DEV_ROOT`? | 资源解析序 |
> |---|---|---|
> | `chandler run` / `repl` | ✓ `<project>` | dev 优先 → prefix 兜底 |
> | `chandler env`(项目模式) | ✓ `<project>` | 同上 |
> | pack 启动器 | ✗ | prefix 唯一 |
> | `chandler install --global` | ✗ | prefix 唯一 |
>
> **部署态 = 无 env = 零开销**:候选表只有 prefix 一条,行为与今天完全一致。
>
> **解析逻辑**(`runtime-paths.ss`):把 `build-app-resource-path` 的单路拼法改为**有序候选表**,
> 第一个存在的文件赢:
>
> ```scheme
> (define (app-resource-candidates segs)
>   (filter string?
>     (list
>       ;; ① dev:<CHANDLER_DEV_ROOT>/resources/<segs>(仅在 run/repl 上下文)
>       (let ([dev (getenv* "CHANDLER_DEV_ROOT")])
>         (and dev (apply join-paths (append (list dev "resources") segs))))
>       ;; ② prefix:<APP_ROOT>/share/<app>/resources/<segs>(app-name 可辨时)
>       (let ([app (app-name)])
>         (and app (apply join-paths (append (list (app-root) "share" app "resources") segs)))))))
>
> (define (app-resource-path . segs)
>   (for-each validate-resource-segment segs)
>   (let ([cs (app-resource-candidates segs)])
>     (when (null? cs)
>       (error 'app-resource-path
>              "cannot locate resource: no CHANDLER_DEV_ROOT and cannot tell which app"))
>     (or (find-existing-file cs)
>         (error 'app-resource-path
>                (string-append "resource not found; tried: " (string-join cs ", "))))))
> ```
>
> `find-app-resource-path` 同构,未找到返回 `#f` 而非报错。
>
> **CLI 侧**(`cli/commands.ss`):`app-root-env` 加第二个绑定,仅在项目模式:
>
> ```scheme
> (define (dev-root-env root)
>   (if (project-mode? root)
>       (list (cons "CHANDLER_DEV_ROOT" (abspath root)))
>       '()))
> ```
>
> `chandler env` 同步导出该变量(项目模式时)。
>
> **不变的部分**:
> - `lib-resource-path` —— 库资源无 dev 例外(已有 source fallback 扫 `library-directories`)。
> - `define-resource-path-resolver` 宏 —— `app` 分支调 `app-resource-path`,自动走候选表。
> - `sync-app-prefix!` —— assembled 仍把 resources 同步进 `lib/share/`(为 pack/global 保完整);
>   dev 例外只是让 run/repl 先读更鲜活的源。
> - `APP_ROOT` 语义 —— 恒指前缀,不受影响。
>
> **为何不用 parent-dir 启发式**(`parent-dir(APP_ROOT)/resources/`):
> `APP_ROOT=<project>/lib` → `parent-dir` → `<project>` → `<project>/resources/`,无需 env var、
> 不改 CLI。但:① 隐式 —— 任何 prefix 的父目录碰巧有 `resources/` 就误判(把全局安装当 dev);
> ② 每次调用 `app-resource-path` 都做 `file-exists?` stat,部署态也有开销;③ 不可调试
> (用户看不到自己是否在 dev 模式)。env var **显式、零部署态开销、可调试**(`echo $CHANDLER_DEV_ROOT`)。

### 8.3 典型工作流

```sh
# 开发期(install 一次,之后 run 自给自足):
chandler install                        # 一次性:源码 → lib/src/
chandler run --script app.ss            # 自动 assembled(编译 if needed)→ 跑
                                        # 资源优先 <project>/resources/(改了立即生效)
                                        # 源码改了 → 下次 run 自动增量重编

# 发布准备:
chandler assembled                      # 显式组装(run 已自动做过;此处保险)
chandler pack                           # lib/ → pack
chandler install --global               # lib/ → ~/.local/share/chez

# CI 验证(只检查依赖可编译,不碰 lib/):
chandler install
chandler build                          # 编译依赖 → _vendor/*/_build/,不动 lib/
```

### 8.4 与既有命令的对照

| 场景 | 今天 | 新方案 |
|---|---|---|
| 开发期 run / repl | `install` → `run`(解释执行,无编译) | `install` → `run`(**自动 assembled** → 编译态;资源优先 `<project>/resources/`) |
| 编译依赖(验证) | `build`(编 + 装 lib/) | `build`(只编,不装) |
| 完整前缀(发布) | `install` + `build` + 手动 `bake build` + 手动同步 | `install` + `assembled`(一条命令) |
| pack | 从 `lib/` + `_build/` 两处拼(有 stale 覆盖坑) | 从 `lib/` 一处取(§8.6) |
| 全局安装 | 先 `build` 再 `install --global` | 先 `assembled` 再 `install --global` |

### 8.5 pack 的简化

assembled 之后 `lib/` 已含全部对象(依赖 + 项目),pack 简化:

```
;; 旧:pack 从两处拼(copy-obj-tree! 项目 _build/ 覆盖 copy-dep-trees! 依赖 lib/ 的 stale)
copy-dep-trees!  (lib/<mt>/  → pack)    ← 依赖对象
copy-obj-tree!   (_build/<mt>/ → pack)  ← 项目对象(覆盖 stale)

;; 新(assembled 后):pack 从一处拷
copy-obj-tree!   (lib/<mt>/  → pack)    ← 全部对象(stale 覆盖问题消失)
```

`preflight` 不再检查 `_build/<mt>/`(已被 assembled 组装进 `lib/`)。
`copy-dep-trees!` 可保留(它从 `lib/<mt>/` 取,语义不变)或与 `copy-obj-tree!` 合并。

### 8.6 与 P4(单一前缀)的关系

P4(docs/single-build-prefix.md)提议 `lib/` 与 `_build/` 物理合一。**assembled 是其安全替代**:

| | P4(物理合并) | assembled(逻辑组装) |
|---|---|---|
| `_build/` | 消失(变 `lib/<mt>/`) | 保留(编译 scratch) |
| `clean` | 连依赖一起删 | 只删 `_build/`(scratch),`lib/` 不动 |
| 重新就绪 | 从 `vendor/` 重铺 + 重编 | `chandler assembled` 重跑(增量指纹) |
| 项目源码副本 | 不拷(原地) | 不拷(原地,与 P4 §3.2 一致) |

保留了 P4 的核心收益(`lib/` 是唯一前缀、run/install/pack 从同一棵树取),
避免了「`_build/` 是 bake 地盘、`clean` 会误删持久状态」的代价(P4 §2)。

---

## 9. 更新后的实施顺序

### 阶段 A:共享底座(M2)— 可独立交付

| 步 | 内容 | 验证点 |
|---|---|---|
| A1 | 不变量常量收敛进 `(chandler layout)` | chandler 测试全绿;bake loader 文本不变 |
| A2 | bake 声明 `(chandler ">=…")`,删除 sha256/util/runtime(~439 行),改 import `(chandler base)` | bake 全套断言绿;`bootstrap.ss` 自含性不变 |

**前置条件已满足**(P1c 运行时门 + 阶段 13 `(chandler base)` umbrella 均已落地)。

### 阶段 B:吸收编译引擎(M1+)— 核心工作

| 步 | 内容 | 验证点 |
|---|---|---|
| B1 | `records + globals + output + engine` → `(chandler task-engine)`;import 改 `(chandler base)` | task DAG / mtime 判定 / run-once 单元测试 |
| B2 | `dsl + loader` → `(chandler recipe)`;根 recipe.ss 能被 chandler 加载 | `(load-recipe)` + `(invoke-task 'build)` 跑通 chandler 自身编译 |
| B3 | `deps` → `(chandler import-graph)` | import 闭包枚举与 bake 一致;环检测正确 |
| B4 | `compile` → `(chandler compile)`:library-task、compile-lib、指纹、并行、prebuilt | 编译 chandler 自身产物与 bake 字节一致 |
| B5 | `native + miniregex` → `(chandler native-build)` + `(chandler miniregex)` | native(script/make/cmake)端到端;loader codegen 文本不变 |
| B6 | bake CLI(dispatch/cli/init/main)合入 chandler CLI;保留 `chandler bake` 别名 | `chandler bake build` ≡ 旧 `bake build` |
| B7 | 删除 bake 仓;统一一套 bootstrap + 启动器 | skiff-demo 端到端 |

**依赖序**:B1 → B2 → B3 → B4 → B5 → B6 → B7。

### 阶段 C:命令职责拆分 + assembled + run/repl 自动化 — 依赖阶段 B

| 步 | 内容 | 验证点 |
|---|---|---|
| C1 | `chandler build` 去掉 `install-dep-objects!` 调用:编译产物留在 `_vendor/<dep>/_build/`,`lib/` 不动 | build 后 `lib/<mt>/` 为空;`_vendor/<dep>/_build/<mt>/` 有对象 |
| C2 | `(chandler build)` 的 `bake-one-dep` 改进程内调用 `(chandler compile)`(不再子进程) | mock-bake 测试改为 in-process;拓扑序 + prebuilt 不变 |
| C3 | 新增 `chandler assembled` 命令:build(自动) + 编译项目 + 组装 + sync resources | `lib/` 完整:src + mt(含项目对象)+ share;不装源码 |
| C4 | `chandler run`/`repl` 自动触发 assembled(后者自动 build);无变更时秒回 | run 后 `lib/` 完整;改源码 → 下次 run 增量重编;无变更 no-op |
| C5 | 资源 dev 例外:`CHANDLER_DEV_ROOT` env var + `app-resource-path` 候选表(dev 优先 → prefix 兜底) | run 时资源读 `<project>/resources/`;pack/全局读 `lib/share/` |
| C6 | pack 简化:来源从双源收敛为 `lib/<mt>/` 单源 | pack 端到端;stale 覆盖测试不再需要 |
| C7 | 文档 + skiff-demo + init 模板同步 | README 命令表加 assembled;skiff-demo 用 assembled 替代旧流程 |

### 阶段 D:收尾

| 步 | 内容 |
|---|---|
| D1 | 两套 bootstrap 合一(chandler `bootstrap.ss` 统一安装编译引擎 + 包管理) |
| D2 | 两套启动器合一(不再有独立 bake 启动器) |
| D3 | `chandler init` 模板:recipe.ss 注明「chandler 直接消费,不需 bake」 |

### 发布节奏

- **阶段 A** 立即可做,独立发布 —— 消灭今天的漂移痛点(bake 用 `(chandler base)`)。
- **阶段 B** 是核心(~2000 行搬运 + import 改写 + 测试合并)。B1–B5 逐模块交付;B6–B7 一次合仓。
- **阶段 C** 依赖 B4(compile 吸收完成)。C3(assembled)代码量小(编排);C4–C5(run/repl 自动化 +
  资源 dev 例外)是面向用户的体验层改动,依赖 C3。
- **阶段 D** 是 B7 的延伸,可同期。

先做 A 消灭漂移;B 逐模块吸收;C 落地新命令 + run/repl 自动化;D 收尾合一。
