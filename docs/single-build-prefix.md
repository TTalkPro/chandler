# 单一前缀:把 `lib/` 与 `_build/` 合成一个

> 状态:**分析,待决(2026-07-23)**。触发点是 `APP_ROOT` 语义反复摇摆——结论是那只是症状,
> 病根在「一个项目有两个库加载根」。
> 相关:[09](../designs/09-pack.md)(包布局与前缀同构)· [11](../designs/11-runtime-paths.md)(资源定位)·
> [12 §5](../designs/12-chandler-layering.md)(chandler 是运行时门)· [07](../designs/07-bake-integration.md)(与 bake 的分工)。

## 0. 提案(原始表述)

1. 依赖放 `_vendor/`,其内容一律按 `~/.local/share/chez` 的模式**安装**到 `_build/`;
2. 当前项目 build 时同样按该标准落进 `_build/`;
3. `chandler build` 把 `resources/` 也放进 `_build/`;
4. `chandler build` 加 `--no-deps` 开关,只构建本项目——供逐个构建 `_vendor` 里的项目时使用。

## 1. 诊断成立:两个加载根才是病根

今天一个项目跑起来要挂两处:`lib/{src,<mt>}`(chandler 铺的依赖)与 `_build/<mt>`(bake 编的本项目)。
于是「前缀」不是一个目录,后果是一串:

- 资源必须**复制**一份进 `lib/share/`,因为 `APP_ROOT` 只能指一个地方;
- `chandler build` 结束后要把 `_build/<mt>` **同步**进 `lib/<mt>`(`build.ss` 的 sync-obj-tree);
- `pack` 得从**两处**拼,并且留着「应用后拷才能赢」的注释——那正是同一个库在两个根里各有一份、
  旧的盖掉新的踩过的坑;
- `run` / `repl` / `activate` 的库搜索规则要逐一枚举这些根。

合成一个前缀后,这些**整段消失**——不是换个写法,是删代码。而且三态会变成同一棵树的三次搬运:

| 动作 | 合一后是什么 |
|---|---|
| `chandler run` | 挂 `_build/src::_build/<mt>` 一对 + 项目源码根;`APP_ROOT=<project>/_build` |
| `chandler install`(全局) | 把 `_build/` 整棵 merge 进 `~/.local/share/chez` |
| `chandler pack` | 把 `_build/` 整棵拷进包 + 捆运行时 |

这正是 P1 / P1b 想达到、却被两个根挡住的终点。

## 2. 代价只有一个,但要认:`_build` 是 bake 的地盘

bake 0.1.5 的事实(已核对源码):

- 输出目录**写死**:`bake/compile.ss:11` → `(define (bake-build-dir) (string-append "_build/" (machine-type-string)))`,
  没有 flag、没有 env 可改;
- `bake -c` **删整棵 `_build/`**(`bake/compile.ss:522` 的 `(clean-report "_build")`)。

所以「一切进 `_build`」= chandler 把**持久状态**(依赖源码、`share/` 资源、`.chandler/` 清单)
放进一个由另一个工具拥有、且它的 clean 会整棵删掉的目录。

| | A:一切进 `_build`(提案) | B:bake 加 `--build-dir`,输出到 `lib/<mt>` |
|---|---|---|
| bake 改动 | 零 | 要改输出目录,`.gen` / `.bake-manifest` 跟着搬,两仓对齐 |
| 语义 | `_build` 从「构建产物」变成「安装前缀」,名字不再准确 | `_build` 仍是 bake 私有 scratch,持久状态归 chandler |
| `bake -c` | 连依赖一起删 | 只删编译产物 |

**建议 A**,但把「前缀缺失就自动从 `_vendor` 重铺」做进 `chandler build` / `run`:
`_vendor` 是原始 checkout,重铺是纯本地拷贝、秒级、无网络。
于是 `bake -c` 的语义变成「清干净,下次自动补」,同时顺手覆盖了**新 clone**、**CI 缓存丢失**
这两个今天要手动 `chandler deps` 的场景——代价从「危险」降级为「一次自动动作」。

## 3. 逐条对照提案

### 3.1 依赖装进 `_build` ✅

`_vendor` 这个命名只是可选的对称化;真正的收益是职责说清楚:
**`_vendor` = 原样 checkout,`_build` = 安装前缀**。

### 3.2 本项目也落 `_build` ✅(对象侧今天已经是了)

bake 输出 `_build/<mt>/<lib>.so`,那正是前缀的对象侧。缺的是源码侧,而这里有个坑要**提前钉死**:

> **项目自己的源码不要拷进 `_build/src`。** 拷了就是同一份代码两个副本,
> 「编译到底用哪份」会变成薛定谔问题。

规则写清楚是:

```
库搜索 = (_build/src :: _build/<mt>) 一对   ← 依赖(源 + 对象)+ 本项目对象
       + 项目源码根                          ← 本项目源码(唯一副本,原地编辑)
       + 全局前缀一对                        ← 兜底
```

只有 `install` / `pack` 这类**发布动作**才把项目源码拷进前缀——那是刻意的搬运,不是开发回路。

### 3.3 resources 放 `_build` ✅

落点 `_build/share/<name>/resources/`,`APP_ROOT=<project>/_build`,
`app-resource-path` 一条规则通四态;现有的 mtime 增量同步原样复用。

### 3.4 `chandler build --no-deps` ✅,但有个前置难点

「进 `_vendor` 里逐个 `chandler build --no-deps`」这条路要先解决:
**dep 的 recipe 解析不了它自己的依赖**——那些依赖装在**主项目**的前缀里,不在 dep 树里。
所以 chandler 必须给每个 dep 注入一个库根(生成 wrapper recipe,或 `bake -f <生成的>`),
不能指望 dep 的 recipe 自己知道主项目在哪。这与 skiff-demo 里那条 `"../chandler"` 是同一个问题的一般形式。

解决之后收益不小:**逐仓构建尊重每个 dep 自己的 recipe**(native-task、生成 loader、优化级别),
比今天「chandler 合成一份 recipe 统编所有 dep」更正确——后者会丢掉 dep 作者写在 recipe 里的一切。

## 4. 改动清单

**消失**

- `build.ss` 的 sync-obj-tree(`_build/<mt>` → `lib/<mt>` 的整段拷贝);
- pack 的双源拼装 + 「应用后拷才能赢」的 stale 覆盖处理;
- `run` / `repl` / `activate` / setup 里的双根分支;
- `lib/` 这个目录本身。

**修改**

- `project-libdir` → `_build`;`verify` 改查 `_build/src`;
- 用户 recipe 的 `(prebuilt "lib")` → `(prebuilt "_build")`——**breaking change**,
  `chandler init` 模板、文档、skiff-demo 同步;
- `.gitignore` 去掉 `/lib/`;
- pack / 全局 install 的来源收敛为单一前缀。

**新增**

- `chandler build --no-deps`;
- 前缀缺失时自动从 `_vendor` 重铺;
- 逐仓构建的库根注入机制。

**风险点**

1. `_build/.gen`(bake 生成的 loader 源码)与 `.bake-manifest` 从此和前缀混住 ——
   pack 已有 `deliverable?` 过滤,**全局 install 的 merge 也必须加同一份过滤**,
   否则会把指纹缓存装进 `~/.local/share/chez`;
2. `(prebuilt "_build")` 让 bake 把自己的输出目录同时当作「预编译根」。
   理论上 prebuilt 只影响 import 解析、不影响 `.` 根下的编译,但**必须有回归钉**证明
   它不会因此跳过本项目的重编;
3. `bake -c` 的语义变化要写进 CLI help 与 README,否则用户会以为依赖丢了。

## 5. 建议顺序

| 步 | 内容 | 可验证点 |
|---|---|---|
| 1 | 前缀落点切到 `_build`(install / run / repl / activate / verify + 删 sync-obj-tree) | 三运行时测试全绿;`chandler run` 只挂一对 |
| 2 | pack / 全局 install 改单一来源(补 merge 的 `deliverable?` 过滤) | pack 端到端 + `verify-pack --target` |
| 3 | 前缀缺失自动重铺 | `bake -c` 后直接 `chandler run` 仍能跑 |
| 4 | `--no-deps` + 逐仓构建的库根注入(最大的一步,独立做) | 带自有 recipe(含 native)的 dep 能被正确构建 |
| 5 | 文档 + skiff-demo + `chandler init` 模板同步 | README 与实际行为一致 |

前三步做完就能验证「一个 `APP_ROOT`、一条路径规则」是否真把复杂度削掉了;
第 4 步是独立收益,可以延后。
