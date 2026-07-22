# 09 — `chandler pack`:无源码分发包

> 状态:**K0–K3 已实现(2026-07-22)**,`chandler pack` / `chandler verify-pack` 可用(modules 模式 · skiff/scheme/petite 运行时 · sh + `.ps1` 启动器);K4(boot 模式)配置期 bail 待做,K5–K6 见下。`chandler/test/pack.ss` 11 用例,合计 **149 全绿**;skiff-demo 端到端实跑(clean-env 起服务、重定位、verify-pack 80 ok/0 bad)。
> 前置:[05](05-install-registry.md)(`{src,<mt>}` 落点)· [06](06-runtime-compat.md)(双运行时)· [07](07-bake-integration.md)(与 bake 的协作接口)。
> 上游规范:[chez-skiff-pack-spec.md](../../skiff/chez-skiff-pack-spec.md)(`skiff --app` 契约)· bake [designs/21 §二](../../bake/designs/21-install-and-pack.md)(**搬运基线**——现行实现在 bake 里,71 断言绿,本文照它实现后再从 bake 删除)。

## 一句话目标

把应用**整体**打成无源码、可重定位、自包含的分发包:应用编译树 + 依赖编译闭包(含 native)+ 随包运行时 + boot + 启动器 + `pack.manifest`。

## 为什么归 chandler(移交理由)

bake 的职责收敛为 **build + install**。打包是「依赖闭包 + 部署」,那正是 chandler 的领域:

| pack 需要知道的 | chandler | bake |
|---|---|---|
| 依赖闭包是哪些、拓扑序 | `manifest.lock` **精确知道** | 只能从构建图**推断**(且遇预构建库不下探,只能整棵命名空间搬) |
| 每个依赖有哪些 native | lock 的 `(natives)` **精确知道** | 扫 `lib/<mt>/**/native/` 反推 |
| 依赖产物在哪 | `lib/{src,<mt>}` 是它自己铺的 | 需要 recipe 里手写 `(prebuilt "lib")` 告诉它 |
| 该捆哪个运行时 | `manifest.ss` 的运行时门 + `chandler run` 已在选 | `pack-task` 里手写 `(runtime skiff)`,与前者重复 |
| 部署态挂载 | `chandler-setup.ss` 已是同一套 `(源 . 对象)` 挂载 | — |

裁决与 [07 §1](07-bake-integration.md) 一致并延伸:**编译动作永远是 bake 的,组装与部署是 chandler 的。** pack 是组装。

## 包布局(照搬 bake 现状,不再改)

```
myapp-1.0-<mt>/
├─ bin/
│   ├─ myapp[.ps1]                        启动器 —— 唯一平台中立入口
│   └─ <mt>/  skiff[.exe] | scheme[.exe]  运行时可执行文件  ┐
├─ boot/<mt>/  petite.boot scheme.boot     boot(+ boot 模式  ├ 平台绑定,<mt> 分区
│              skiff.boot  myapp.boot      的应用 boot)      │
├─ lib/<mt>/                               对象根           ┘
│   ├─ myapp.so   myapp/**/*.so            应用编译树(= _build/<mt>/ 剥源码)
│   ├─ <dep>.so   <dep>/**/*.so            依赖编译闭包(= lib/<mt>/,chandler 自己铺的)
│   └─ <lib>/native/*.{so,dll,dylib}       C FFI(收进所属库;递归扫描)
├─ resources/                              应用数据,原样
└─ pack.manifest
```

**四态同构**是这个布局的全部理由:`_build/<mt>`(build)、`<prefix>/<mt>`(install)、`lib/<mt>`(chandler)、`lib/<mt>`(pack)结构完全一致 —— 包里的 `lib/<mt>/` 就是普通对象根,chandler 铺好的依赖树整棵 `cp` 进去即可,不需要第二套路径规则;运行时也不再与库名空间混住。

## 三条约定,不做成配置

1. **`resources/`** —— 应用数据目录,名字钉死。项目根有就打包,没有就没有。**不设子句**。它在 `<mt>` 层之上:数据不带 ABI,同一份被该应用的所有平台包共用;放进 `lib/<mt>/` 反而会进库搜索根。
2. **`<lib>/native/<soname>.<ext>`** —— native 落点,与 bake [designs/20](../../bake/designs/20-native-backends.md) 的落点不变量同一份。
3. **`(<lib> native-loader)`** —— 自加载 loader,bake 生成、随对象树交付([bake designs/24](../../bake/designs/24-native-loader-codegen.md))。chandler 不生成、不改写,只搬运。`chandler-setup.ss` 现有的 native 兜底扫描继续只服务**无 loader 的第三方库**。

## env:去两个,留一个,换中性前缀

**只留一个:`APP_ROOT`(部署根)。** 包内其余一切都在它下面的**约定路径**上:

| 旧变量 | 决定 | 现在怎么定位 |
|---|---|---|
| `BAKE_PACK_ROOT` | 改名 **`APP_ROOT`** | 唯一无法推导的信息就是「这个包被解到哪儿了」 |
| `BAKE_RESOURCES` | **取消** | `$APP_ROOT/resources/` —— 名字钉死 |
| `BAKE_NATIVE_<LIB>`(每库一个,按库名大写造名) | **整族取消** | `$APP_ROOT/lib/<mt>/<libpath>/native/` —— 生成的 loader 自己拼 |

**实现期修正的一处论证。** 起初的理由是「`resources/` 名字钉死 ⇒ 包根一定它就完全确定 ⇒ 不必传」——漏了一步:**应用自己不知道包根**。`bootstrap.ss` 能从 `(car (command-line))` 推,`skiff --app` 能从 manifest 路径推,但编译成 `.so` 的应用库两者都没有。所以「部署根」这一个信息必须传。

顺着这个漏洞反而得到更简的结论:既然布局已经全面 `<mt>` 分层、路径完全由约定决定,那么 **一个 `APP_ROOT` 足以定位包内任何东西**,per-library 的 native 变量整族可以删掉 —— 那一族当初存在,正是因为布局还不够统一、推不出路径。而且 `$APP_ROOT/lib/<mt>/<libpath>/native/` 与 loader 早就有的 dev 兜底 `_build/<mt>/<libpath>/native/` 是同一个形状:**一条约定,两个根**。

`APP_ROOT` 仍然是**必需**的,理由不变([bake designs/24 §约束 3](../../bake/designs/24-native-loader-codegen.md)):boot 里 loader 在库 invoke 期执行,早于一切 stub 代码,运行期 `library-directories` 不可依赖;env 在 exec 前设好,时序天然正确。

已同步落地:bake 的 `native-loader` 生成器(候选 1 改为 `$APP_ROOT/lib/<mt>/…`)、bake 四处启动器、bake 的 V/Z/P 系列断言、chandler pack 启动器。启动器因此从 5 行降到 3 行。

> `SKIFF_BOOT_DIR` 不在此列 —— 那是 skiff 自己文档化的覆盖,本布局(`bin/<mt>` + `boot/<mt>`)对不上它的 exe 相对发现,必须显式给;且 boot 须在进程有堆之前注册,远早于 `--app` 被解析,env 是唯一交接方式。

## CLI

```
chandler pack [--mode modules|boot] [--runtime skiff|scheme|petite]
              [--out DIR] [--name NAME] [--version V]
              [--entry '(myapp)'] [--main main]
chandler verify-pack <dir|pack.manifest>
```

缺省取自 `manifest.ss`:`name`/`version` 直接来;`--runtime` 由 [06](06-runtime-compat.md) 的运行时门推导(manifest 声明 `(skiff …)` → skiff);`--entry` 缺省 `(<name>)`;`--mode` 缺省 `modules`;`--out` 缺省 `dist`。

**前置校验**(沿用 [07 §4](07-bake-integration.md)):lock 每项在 `lib/<mt>/` 有产物,缺 → 报「先跑 `chandler build`」;应用自身 `_build/<mt>/` 缺 → 报「先跑 `bake build`」。**pack 只组装,不构建** —— native 尤其无法在此现编。

## boot 模式:排单给 bake,不自己编

boot 模式要「生成入口 stub → `compile-file` → 对整棵 `.so` 闭包拓扑排序 → `make-boot-file`」。按 [07 §1](07-bake-integration.md) 的裁决,**编译归 bake**,故与 `chandler build` 同样走**生成 recipe 跑真实 bake**:

```scheme
;; .chandler-pack.ss(生成,cwd = 项目根)
(define-lib-roots "." (prebuilt "lib"))        ; bake designs/25:依赖对象式消费
(boot-task 'app-boot ".chandler-pack-main.ss") ; stub 也由 chandler 生成
```

跑 `bake -f .chandler-pack.ss app-boot` → `_build/<mt>/app-boot.boot`,chandler 拷进 `boot/<mt>/<app>.boot`。

**需要 bake 补一个口子**:`boot-task` 的 base boots 现在硬编码 `("scheme" "petite")`,而 petite 运行时的包只随 `petite.boot`(bake pack 内部另有 `link-boot-file/bases` 走这条)。移交时把 base 选择提升为 `boot-task` 的可选子句(`(bases petite)`),这是 bake 侧唯一需要**新增**的东西 —— 其余全是删除。

## `pack.manifest`

格式与现状一致(bake designs/21 §pack.manifest),两处调整:

- `(resources "resources")` **删除** —— 名字约定死,存在与否看包里有没有那个目录。
- `(native …)` 段改由 **lock 的 `(natives)`** 生成而非扫目录 —— 精确,且缺项能报出是哪个依赖缺。

## 实现顺序

| # | 内容 |
|---|---|
| K0 ✅ | `(chandler pack)` 模块骨架 + `chandler pack` CLI + 前置校验(闭包完整性) |
| K1 ✅ | modules 模式 + skiff 运行时(主力路径):对象树搬运 · 运行时/boot 捆绑 · sh 启动器 · `pack.manifest` |
| K2 ✅ | stock scheme/petite 运行时:`bootstrap.ss` 生成(包根从自身路径推导)· 绝对 `-b` 链 |
| K3 ✅ | `.ps1` 启动器 + `chandler verify-pack` |
| K4 | boot 模式(排单 bake `boot-task`,含 bake 侧 `(bases …)` 子句) |
| K5 | ~~`resources/`~~ ✅ + ~~env 收敛为单个 `APP_ROOT`~~ ✅(bake 侧已同步);待做:`chandler-setup.ss` 在 dev 态也设 `APP_ROOT`,使应用四态读同一个东西 |
| K6 | 从 bake 删除 `pack.ss` / `pack-task` / V 系列 / P9–P10 / Z7 · Z7b,designs/21 §二 改为「已移交」 |

验收对齐 bake 现有的 V1–V23(71 断言)+ Z7/Z7b,移植进 `tests/`;新增闭包不完整时的报错路径。
