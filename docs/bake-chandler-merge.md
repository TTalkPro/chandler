# 要不要把 bake 与 chandler 合并?

> 状态:**分析,待决(2026-07-23)**。
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

## 5. 结论与建议

- **M3(合并概念、清单里写构建)否决** —— 与「清单只读不求值」的安全姿态直接冲突,
  收益(少一个文件)远小于代价(解析第三方清单等于执行其代码)。
- **M2(共享底座 + 不变量)现在就该做** —— 改动小、收益即时,而且今天两次漂移正是它要解决的问题。
  chandler 侧的前置条件(runtime 子集 + 运行时门)**刚刚已经就绪**。
- **M1(单仓单二进制)方向正确,但排在 M2 之后** —— 先把底座共享掉,合仓就只剩「搬目录 + 合 CLI」,
  风险与工作量都低得多;而且做完 M2 之后若发现独立发布确实有价值,可以就停在 M2。

### 建议顺序

| 步 | 内容 | 验证点 |
|---|---|---|
| 1 | 不变量常量收敛进 `(chandler layout)`:前缀形状、`<mt>` 分区、native 落点、loader 候选拼法、so-ext | chandler 侧测试全绿;bake 侧生成的 loader 文本不变 |
| 2 | bake 声明 `(chandler ">=…")` 运行时门,删掉自带 sha256/util/runtime,改用 `(chandler base)` | bake 全套断言绿;`bootstrap.ss` 自含性不变 |
| 3 | 评估 M1:合仓、`chandler build` 改进程内调用、两套启动器合一、保留 `bake` 别名 | 单二进制跑通两边全部验收;skiff-demo 端到端 |

先做 1–2 就能消灭「不变量写在两处」这个真正的痛点;第 3 步是体验与维护成本的进一步收敛,可独立决策。
