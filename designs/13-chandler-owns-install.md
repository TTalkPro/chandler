# 13 — chandler 全面接管安装与卸载

> 状态:**设计中(2026-07-23)**,O 标号见 §9。
> 前置:[07](07-bake-integration.md)(bake 协作接口 —— 本文修订其 §分工)· [05](05-install-registry.md)(全局注册表,已由 chandler 拥有)· [09](09-pack.md)(pack 已自 bake 移交,本设计是同一方向的延续)· [12](12-chandler-layering.md)(runtime subset,chandler 自举的约束)。
> 上游规范:[chez-skiff-library-layout.md](../chez-skiff-library-layout.md) · [chez-chandler-git-lib-manager-design.md](../chez-chandler-git-lib-manager-design.md)。

## 一句话目标

chandler 成为安装/卸载的**唯一执行者**;bake 退化为**纯编译引擎**(编译 `.ss→.so`、构建 native、跑 recipe 任务),**删除 `install-task`/`uninstall-task`**,不再有安装/卸载能力。消除 `chandler install` 对 bake 的子进程依赖,使 install 不再需要 bake 在场。

## 1. 背景:当前分工的问题

[07](07-bake-integration.md) §分工(2026-07-22 修订)写道:

> **bake 只负责编译,以及安装到指定位置**;chandler 老实遍历 `vendor/`,一个一个交给 bake。

这条边界在实践中有三处摩擦:

### 1.1 install 是纯文件拷贝,却要起 bake 子进程

`chandler install` 生成一份临时 recipe(`.chandler-install.ss`),内含每依赖一条 `(install-task ...)`,**不带 `(needs ...)`**(install.ss:121)——因为 install 只发源码、不编译(bake `run-install` 的步骤 3「拷 `_build/<mt>/`」在 install 期是空操作:vendor 是干净 checkout,无 `_build/`)。起一个 bake 子进程**只为拷贝文件**,是不必要的开销,且制造了 `chandler install` 对 bake 可执行文件在场的硬依赖。

### 1.2 build 让 bake 做 install,导致 chandler 不知道 lib/ 里有什么

`chandler build` 每依赖生成一份 recipe,含 `(install-task 'install ... (needs build-all) ...)`(build.ss:156),bake 先编译再安装(源码 + 编译产物)到 `lib/`。chandler 只知道「我让 bake 装了」,不知道**具体装了什么**——要靠 `.bake-install/<lib>.files` 清单事后反推。

### 1.3 pack 已经自己做了一遍 install 逻辑

[09](09-pack.md) 的 `copy-dep-trees!`(pack.ss:206-229)从项目 `lib/<mt>/` 拷依赖编译产物进 pack。它与 bake install 的 `run-install`(bake/install.ss:63-109)做的是**同一件事**(枚举 `.so`、过滤 `.bake-manifest`/`*.wpo`、拷贝),却是两份独立实现。这正是上一个 bug 的根源——pack 拷了 bake 同步进去的**陈旧残留**,覆盖了新编好的产物。

### 1.4 三条 install 路径只有一条依赖 bake

| 路径 | 当前实现 | 依赖 bake? |
|------|---------|-----------|
| 项目级 install | `bake install-all` 子进程(install.ss:131) | **是** |
| 全局 install 他人库 | `(chandler registry)` 直接事务(registry.ss) | **否** |
| chandler 自身 install | `bake install` 子进程(selfinstall.ss) | **是** |

全局 install 已经完全由 chandler 拥有。本设计把另外两条也收回来。

## 2. 新分工模型

| 事项 | 旧归属 | 新归属 | 接口 |
|------|--------|--------|------|
| 依赖获取/锁定/物化 vendor/ | chandler | chandler(不变) | `manifest.ss` → `manifest.lock` |
| **源码布局 `lib/src/`** | bake(install-task) | **chandler** | §3 |
| **编译 `.ss→.so`** | bake | bake(**不变**) | recipe `library-task` |
| **native 构建** | bake | bake(**不变**) | recipe `native-task` |
| **编译产物布局 `lib/<mt>/`** | bake(install-task) | **chandler** | §4 |
| **native 产物布局** | bake(install-task) | **chandler** | §4 |
| **resources 布局** `lib/share/` → **`lib/src/resources/`**(2026-07-24 C4) | chandler(已拥有) | chandler(不变) | §3 |
| 全局安装注册表 | chandler(已拥有) | chandler(不变) | [05](05-install-registry.md) |
| **卸载** | bake(uninstall-task) | **chandler** | §5 |
| pack 组装 | chandler(已拥有) | chandler(简化,§7) | [09](09-pack.md) |

**修订 [07](07-bake-integration.md) §分工**:~~「bake 只负责编译,以及安装到指定位置」~~ → **「bake 只负责编译」**。文件布局(源码、编译产物、native、resources)全部归 chandler。bake 的 `install-task` / `uninstall-task` **从 bake 中删除**——chandler 是唯一的安装/卸载执行者,bake 不再有此能力。

### 2.1 跨仓协调

bake 在**独立仓库**,且 import 了 6 个 chandler 库(`lock/registry/layout/sexp/util/fs`,见 [07 §5](07-bake-integration.md))。本设计**不改变这些库的 export 签名**。

bake 侧改动:
- **删除** `install-task` / `uninstall-task` DSL 宏 + `run-install` / `run-uninstall` / `install-manifest-path` 等实现(bake/install.ss 全删)。
- **删除** `.bake-install/` 目录约定——该目录不再产生,chandler 用命名空间精确清旧(§4.5),不需要文件清单。
- bake 的 `selfinstall.ss`(自安装)改为直接拷贝模块 + 写 launcher,不再走 install-task。与 chandler 的 install-self 同构(§8)。
- bake 的 recipe DSL 保留 `library-task` / `native-task` / `task` / `file` / `rule` / `default-task`——纯构建语义不变。

**协调时序**:bake 删 install-task 与 chandler 不再写 install-task 到 recipe **同步发布**。二者在同一 minor 版本窗口内对齐。

## 3. 安装:chandler install(源码搬运 in-process)

### 3.1 替换 `bake-install-deps`

当前 install.ss 的 `bake-install-deps`(L111-132)被替换为 `install-dep-sources!`——纯 in-process 文件拷贝,无子进程:

```
install-dep-sources!(root, git-deps):
  for each dep in git-deps:
    name   = locked-dep-name(dep)
    vdir   = vendor/<name>
    srcdir = srcdir-join(vdir, locked-dep-srcdir(dep))   ; dep 的 srcdir(默认 ".")
    1. 找 umbrella:srcdir/<name>.{.chezscheme.sls,.sls,.ss,.scm} → lib/src/<name>.<ext>
    2. 拷源码子树:srcdir/<name>/** → lib/src/<name>/**
    3. (resources 已有 install-resources,不变)
```

**umbrella 扩展名探测**(复用 build.ss 的 `find-umbrella`):

```scheme
(define lib-extensions '(".chezscheme.sls" ".sls" ".ss" ".scm"))
```

与 bake 的 `run-install`(bake/install.ss:75-76 探测 `.ss`/`.sls`/`.scm`)的差异:bake 不认 `.chezscheme.sls`;chandler build 的 `find-umbrella` 认。统一用 build 的版本(更全)。

### 3.2 非源码文件过滤

bake `run-install` 的步骤 2(`files-under` → 全拷)会把 vendor 树里的 `.git/`、`README.md`、测试文件等一并拷进 `lib/src/`。当前已如此(bake 也不过滤),本设计**不改变行为**——源码树原样拷,消费方只 import `(library ...)` 声明的文件,非库文件不影响(但占空间)。

> **开放**:未来可加 `library-source?` 过滤(只拷首个 datum 为 `(library …)` 的文件),但那是优化,不是正确性问题。§12 open question 1。

### 3.3 install 不再依赖 bake 在场

`chandler install` 不再调用 `bake-command`。前置条件仅为:
- `git` 在 PATH(fetch/vendor)
- `manifest.ss` + `manifest.lock` 可读写

用户可以在**未安装 bake** 的机器上跑 `chandler install`(源码激活、REPL、`chandler run` 等不依赖编译产物的场景)。

### 3.4 chandler-setup.ss 继续生成 —— **已推翻(2026-07-23)**

> 本节与 §6 的结论(保留 setup 文件)已被后续决定取代:**setup 文件不再生成,启动统一走 `chandler run`**。
> 它当年要解的 chicken-and-egg 由 §6.2 早已点出的 launcher 路线解决——而 `chandler run` 就是那个 launcher:
> 它在 exec 解释器之前设好 `--libdirs` 与 `APP_ROOT`,不需要任何 import。见 §6 的补记。

## 4. 构建:chandler build(编译委托 bake + chandler 布局产物)

### 4.1 recipe 变化:移除 install-task / uninstall-task

当前每依赖的 recipe(build.ss:emit-dep-recipe, L120-160):

```scheme
;; 旧 recipe
(define-lib-roots "." (prebuilt "<root>/lib"))
(native-task 'soname (lib name) ...)
(library-task 'c-rel "rel") ...
(task 'build-all '(...) ...)
(install-task 'install (lib name) (from ".") (needs build-all) (target (prefix "<root>/lib")))
(uninstall-task 'uninstall (lib name) (target (prefix "<root>/lib")))
(default-task 'install)
```

新 recipe——**只编译,不安装**:

```scheme
;; 新 recipe
(define-lib-roots "." (prebuilt "<root>/lib"))
(native-task 'soname (lib name) ...)
(library-task 'c-rel "rel") ...
(task 'build-all '(...) ...)
(default-task 'build-all)
```

bake 子进程调用变为 `bake -f .chandler-build.ss build-all`(而非 `install`)。bake 只编译,产物落 `vendor/<dep>/_build/<mt>/`。

### 4.2 chandler 接管编译产物布局

bake 编译完成后,chandler 自己把产物从 `vendor/<dep>/_build/<mt>/` 搬到 `lib/<mt>/`。新增 `install-dep-objects!`:

```
install-dep-objects!(root, dep):
  name = locked-dep-name(dep)
  srcdir = vendor/<name>/<srcdir>
  bdir = srcdir/_build/<mt>                    ; bake 产物落点(cwd=srcdir)
  objdir = lib/<mt>                             ; chandler 的对象根
  1. 清旧:删除 lib/<mt>/<name>.so + lib/<mt>/<name>/ (精确,不碰别的依赖)
  2. 拷_build/<mt>/** → lib/<mt>/**,过滤:
     - .bake-manifest(bake 指纹缓存,路径相关)
     - *.wpo(whole-program 中间物,仅构建期消费)
  3. native 产物随之:_build/<mt>/<name>/native/** → lib/<mt>/<name>/native/**
```

**过滤逻辑复用 pack.ss 的 `deliverable?`**(pack.ss:165-167):

```scheme
(define (deliverable? rel)
  (and (not (string=? (base-name rel) ".bake-manifest"))
       (not (string-suffix? ".wpo" rel))))
```

未来可提取到共享模块(§12 open question 2),但本设计不强制——先 correctness 后 de-dup。

### 4.3 源码同步

`chandler build` 执行前,`chandler install` 已经把源码铺进 `lib/src/`(§3)。build 的 preflight 已校验(build.ss:40-41):

```scheme
(unless (file-directory? (car (project-lib-pair root)))
  (error 'build "lib/src missing; run `chandler install` first" root))
```

**不需要在 build 里重拷源码**——install 已完成,bake install-task 原来顺手做的源码拷贝是冗余的(install 已经做过一遍)。

### 4.4 拓扑序与 prebuilt 不变

`(prebuilt "<root>/lib")` 指向项目 `lib/`(install 目标),**路径不变**。拓扑序保证:编 A 时其依赖 B 已在 `lib/{src,<mt>}/` 里(先 install + build B,再编 A)。这个时序约束**不因 install 搬运方改变而改变**——`lib/` 的布局路径与内容结构(src/mt 拆分)完全一致。

### 4.5 清旧:精确而非 nuke

当前 `chandler build` 的 `bake-one-dep` 先跑 `bake uninstall`(build.ss:112-113)清旧,再 `bake install`。新流程中 chandler 自己做精确清旧:

```scheme
;; 删除该依赖在 lib/<mt>/ 下的旧产物(umbrella .so + 子树)
(define (clean-dep-objects! objdir name)
  (let ([ns (symbol->string name)])
    (delete-if-exists (join-paths objdir (string-append ns ".so")))
    (rm-rf (join-paths objdir ns))))
```

只删该依赖的命名空间,**不碰**同 `lib/<mt>/` 下别的依赖。chandler 按命名空间清旧,**不需要文件清单**——lock 知道每个依赖的名字,名字就是命名空间。

### 4.6 无文件清单:`.bake-install/` 彻底退役

bake `install-task` 旧流程写 `.bake-install/<lib>.files` 文件清单,供 `uninstall-task` 精确删除。新流程中:

- bake **删除** `install-task`/`uninstall-task`,不再产生 `.bake-install/`。
- chandler 按命名空间清旧(§4.5),不需要文件清单。
- 全局安装的文件追踪由已有的 `.chandler/registry/` 负责([05](05-install-registry.md)),不受影响。

**干净断裂**:旧 `.bake-install/` 目录若存在于历史项目中,chandler 不读、不写、不删——它只是残留文件,用户可手动 `rm -rf .bake-install/` 清理。不存在向后兼容负担(格式不兼容,也不需要兼容)。

## 5. 卸载:chandler uninstall

### 5.1 项目级:整树清除(当前行为,不变)

`chandler install` 每次执行时 `rm-rf lib/` + 重建(install.ss:64)。这是**项目级卸载**——简单、幂等、不需要 per-dep 追踪。本设计**保持不变**。

### 5.2 全局:注册表事务(已拥有,不变)

`chandler uninstall --global --name=X` 走 `(chandler registry)` 的 `uninstall-global`(registry.ss)。hash 校验 + 精确删除 + 空目录清扫。**不受本设计影响**。

### 5.3 未来:per-dep 项目级卸载(开放)

当前无 `chandler uninstall <dep>`(项目级)。若未来需要,chandler 可凭 lock 知道某依赖的命名空间,精确删 `lib/src/<name>.*` + `lib/src/<name>/` + `lib/<mt>/<name>.so` + `lib/<mt>/<name>/` + `lib/share/<libpath>/`。**本设计不实现,留 §12 open question 3。**

## 6. chandler-setup.ss 的处置 —— **结论已反转(2026-07-23)**

> **现状**:`write-setup-file` 已删除,`chandler deps` 不再生成 `chandler-setup.ss`;启动统一 `chandler run`
> (它同时交接库搜索路径与 `APP_ROOT` = 项目库前缀 `<project>/lib`),进程内则用 `(activate)`,
> 别的进程用 `eval "$(chandler env)"`。§6.2 当年判定为「未来方向」的 launcher-wrapper 正是现在的做法,
> 只是不必新造 `chandler-run` 可执行文件——`chandler run` 子命令即可。
>
> **为什么反转**:setup 是**生成物**,它把「库搜索规则 + APP_ROOT 约定」复制了一份到项目里,规则一改就有
> 两处要同步(P1 改前缀语义时正好撞上)。少一份副本,就少一类漂移。
>
> 以下原文保留作决策记录。
>
> ### 6.1 结论(**当时**):保留,不改

`chandler-setup.ss` 解决的是 **library-directories 引导问题**——chicken-and-egg:

```
要 (import (my-dep))     →  需要 library-directories 指向 lib/
设 library-directories   →  需要 (import (chandler activate))?
(import (chandler ...))  →  需要 library-directories 指向 chandler 全局前缀
```

setup 文件用纯 `(chezscheme)`(零 import)打破这个环:它从自身位置推导项目根,直接设 `library-directories`。任何基于 `(import (chandler activate))` 的替代方案**都无法解决这个环**——因为 import 本身需要 library-directories 已设好。

Metis 分析(见 `.sisyphus/analysis/`)的结论一致:

> **Don't fully eliminate `chandler-setup.ss`.** It is solving a legitimate bootstrap problem that a library cannot solve cleanly.

### 6.2 未来方向(不在本设计范围内)

消除 setup 文件的**可行路径**是 launcher-wrapper(而非 library import):

```sh
#!/usr/bin/env chandler-run    ;; 设好 --libdirs + APP_ROOT 后 exec scheme
```

这需要一个 `chandler-run` 可执行文件,在 exec scheme 前设好环境。它解决了 chicken-and-egg(因为 wrapper 不需要 import)。但这是独立设计,不在本设计范围内。§12 open question 4。

### 6.3 install 接管对 setup 文件的影响:零(**已作废**:setup 文件本身已删除)

`write-setup-file` 的逻辑当时完全不变——它挂的是 `lib/src::lib/<mt>` 对,而本设计**不改 `lib/` 的布局结构**。
2026-07-23 起该函数已删除,`lib/` 反而多了两样东西使它成为一个**完整前缀**:`src/resources/<name>/`(2026-07-24 C4 起;原为 `share/<name>/resources/`)
(项目自己的资源同步过来)与 `.chandler/<name>/manifest.ss`(清单快照,应用名由此可辨)。

## 7. pack 的简化

### 7.1 pack 已自给自足

[09](09-pack.md) 的 `pack` 函数(pack.ss:760-840)已经有自己的搬运逻辑:

| pack 函数 | 搬什么 | 从哪 → 哪 |
|-----------|--------|-----------|
| `copy-dep-trees!` | 依赖编译产物 | `lib/<mt>/` → pack `lib/<mt>/` |
| `copy-obj-tree!` | 应用编译产物 | `_build/<mt>/` → pack `lib/<mt>/` |
| `copy-resources!` | 应用资源 | `resources/` → pack `resources/` |
| `copy-share!` | 依赖资源 | `lib/share/` → pack `share/` |

这些**已经是 chandler in-process**的,不调 bake。本设计不改变 pack 的行为。

### 7.2 搬运逻辑统一的机会

`pack.ss:copy-dep-trees!` 与 §4.2 的 `install-dep-objects!` 做的是同类操作(枚举 `.so`、过滤 deliverable?、拷贝)。未来可提取共享的 `(chandler deliverable)` 模块。**本设计不强制**——先让两处各自 correctness,de-dup 留后续(§12 open question 2)。

## 8. install-self 的迁移

### 8.1 当前流程

```
chandler install-self:
  1. bake install → ~/.local/share/chez/{src,<mt>}/   (读本仓 recipe.ss)
  2. 写 launcher → ~/.local/bin/chandler               (runtime 发现 + 设 --libdirs)
```

selfinstall.ss 调用 `bake install`(或 `bake install --global`),bake 从 chandler 仓库根读 `recipe.ss`,把库树装进全局前缀。

### 8.2 新流程:chandler 自己装自己

chandler 知道自己的源码树(仓库根 = `(bake-script-dir)` 的等价物),也知道自己有哪些子库(design [12](12-chandler-layering.md) 的 `runtime-subset` 声明)。新流程:

```
chandler install-self:
  1. chandler 自己把源码 + 编译产物铺进 ~/.local/share/chez/{src,<mt>}/
     - 源码:<chandler-root>/chandler.ss + chandler/** → src/
     - 编译产物:<chandler-root>/_build/<mt>/** → <mt>/
  2. 写 launcher(不变)
```

这复用 §3 的 `install-dep-sources!`(只是 from = chandler 仓库根,to = 全局前缀)和 §4.2 的编译产物搬运逻辑。

### 8.3 自举约束

chandler 自身的 `manifest.ss` 保持零 deps(design [12](12-chandler-layering.md) §5.2 自举例外)。`install-self` 不走 `chandler install` 路径(那条要读 lock、有 deps)——它是特殊路径,直接铺自己的树。当前 selfinstall.ss 也是特殊路径(不读 lock),**行为一致**。

### 8.4 uninstall-self

按命名空间清,不需要文件清单:

```
uninstall-self:
  1. 删 ~/.local/share/chez/src/chandler.ss + chandler/** 
  2. 删 ~/.local/share/chez/<mt>/chandler.so + chandler/**
  3. 删 launcher
```

与 §4.5 的精确清旧同构。旧 `.bake-install/chandler.files` 若存在则忽略——它是历史残留,不影响新流程的正确性。

## 9. 实施顺序(O 标号,接续 N)

| # | 内容 | 依赖 |
|---|------|------|
| O0 | 本设计文档 | — |
| O1 | 新增 `install-dep-sources!`(install.ss):umbrella + 子树拷贝,替换 `bake-install-deps`。`chandler install` 不再调 bake 子进程 | O0 |
| O2 | `chandler install` 移除 `bake-install-deps` 调用,改用 O1。验证:install 不需要 bake 在场 | O1 |
| O3 | 修改 `emit-dep-recipe`(build.ss):移除 `install-task`/`uninstall-task`/`default-task 'install`,改为 `default-task 'build-all` | O0 |
| O4 | 新增 `install-dep-objects!`(build.ss):编译产物 + native 从 `_build/<mt>/` → `lib/<mt>/`,含精确清旧(clean-dep-objects!)。`bake-one-dep` 改为先 `bake build-all` 再 `install-dep-objects!` | O3 |
| O5 | `chandler build` 验证:拓扑序 + prebuilt 不变;编译产物正确落位;native 正确落位 | O4 |
| O6 | `install-self` / `uninstall-self`:改为 chandler 自己铺树(§8),不再调 bake install/uninstall | O1,O4 |
| O7 | 更新 [07](07-bake-integration.md) §分工 + §2 recipe 示例 + §4 pack 时序;更新 README "装完之后" 段(install 不再依赖 bake) | O2,O5 |

**发布门**:O0–O5 一组(核心 install + build 迁移);O6–O7 跟进(self-install + 文档)。

**依赖序**:
- O1 独立(新函数,不改现有调用)。
- O2 依赖 O1(切换调用点)。
- O3 独立(改 recipe 生成)。
- O4 依赖 O3(recipe 不再含 install-task 后,chandler 必须自己搬产物)。
- O5 依赖 O4(端到端验证)。
- O6 依赖 O1 + O4(复用源码 + 产物搬运)。

## 10. 失败模式 / 陷阱

| # | 场景 | 期望行为 | 诊断 / 缓解 |
|---|------|---------|------------|
| 1 | **umbrella 扩展名遗漏** | 认 `.chezscheme.sls`/`.sls`/`.ss`/`.scm` | 复用 build.ss `find-umbrella` 的 4 扩展名列表;与 bake 的 3 扩展名列表的差异是**改进**(bake 漏 `.chezscheme.sls`) |
| 2 | **srcdir 非标准** | dep 的 `(srcdir "lib")` → 从 `vendor/<name>/lib/` 取 | `srcdir-join` 已处理(install.ss:119 同款);`install-dep-sources!` 传 `locked-dep-srcdir` |
| 3 | **_build/<mt>/ 不存在就搬** | 报错而非静默跳过 | `install-dep-objects!` 前置 `(unless (file-directory? bdir) (error ...))`;对应 build.ss 的 bake 非零退出检查 |
| 4 | **精确清旧漏删嵌套子库** | `lib/<mt>/<name>/` 整棵删 | `clean-dep-objects!` 用 `rm-rf <objdir>/<name>`(整子树),不只删 `.so` |
| 5 | **prebuilt 路径过时** | build 跑前重新生成 recipe | `emit-dep-recipe` 每次执行都生成(build.ss:104-106 已如此);不缓存 recipe |
| 6 | **install 不再依赖 bake,但 build 仍依赖** | install 成功、build 找不到 bake → 报 "bake not found" | `bake-command`(build.ss:32)返回 #f 时报清晰错误;"install 不需要 bake"与"build 需要 bake"不矛盾 |
| 7 | **跨仓:bake 删 install-task** | bake 同步删除 install-task/uninstall-task,两者同步发布 | bake 侧删 `install.ss` 全文 + DSL 宏;chandler 侧删 recipe 中的 install-task/uninstall-task。同一 minor 版本窗口对齐 |
| 8 | **旧 `.bake-install/` 残留** | 不影响 chandler | chandler 不读、不写、不删 `.bake-install/`;用户可 `rm -rf .bake-install/` 清理。干净断裂,无兼容负担 |
| 9 | **install-self 旧安装残留** | 按命名空间卸载,忽略旧清单 | `uninstall-self` 按 `chandler.ss` + `chandler/` 命名空间删;旧 `.bake-install/chandler.files` 若存在则忽略 |
| 10 | **非库文件进 lib/src/** | vendor 树里的 README/test/.git 也被拷 | 当前 bake 也不过滤——**行为一致**;未来可加过滤(§12 #1) |
| 11 | **CHANDLER_BAKE 测试注入** | mock-bake 仍工作 | build 仍调 bake 子进程(只换 task 名:`build-all` 替 `install`);`bake-command` 不变 |
| 12 | **native-loader.so 随产物搬运** | bake 生成的 native-loader.so 在 `_build/<mt>/<lib>/native-loader.so`,chandler 搬进 `lib/<mt>/<lib>/native-loader.so` | `deliverable?` 不过滤 `.so`(native-loader.so 也是 `.so`);`copy-obj-tree!` 同款行为(pack 已验证) |

## 11. 与其他设计的关系

| 文档 | 关系 |
|------|------|
| [07-bake-integration.md](07-bake-integration.md) | **本文修订其 §分工 + §2 recipe 示例 + §4 pack 时序**。核心变化:recipe 不再含 `install-task`/`uninstall-task`;chandler 自己搬产物。O7 同步文档 |
| [05-install-registry.md](05-install-registry.md) | 全局注册表不受影响(已是 chandler 拥有)。本文使项目级 install 与全局 install 的**搬运逻辑同源**(都是 chandler in-process) |
| [09-pack.md](09-pack.md) | pack 已自 bake 移交;本文是同一方向(install 也移交)。pack 的 `copy-dep-trees!` 与本文的 `install-dep-objects!` 做同类操作——de-dup 机会留开放(§12 #2) |
| [12-chandler-layering.md](12-chandler-layering.md) | runtime subset 不受影响。install-self 的 chandler 自举铺树复用 layout 规范(src/mt 拆分) |
| [01-cli.md](01-cli.md) | CLI 命令面不变(`install`/`build`/`uninstall` 用法不变)。内部实现变,用户面不变 |
| [08-bootstrap-security.md](08-bootstrap-security.md) | 信任模型不变:清单只 `read` 不求值;native 构建 = 别人代码 → `--allow-build` 授权不变 |
| bake designs/21 (install-and-pack) | bake 侧 `install-task`/`uninstall-task` 实现保留,但 chandler 不再消费。bake 独立使用时仍可用 |
| [chez-skiff-library-layout.md](../chez-skiff-library-layout.md) | src/mt 拆分布局**不变**——本设计只改「谁来搬」,不改「搬到哪」 |

## 12. 开放问题

1. **非库文件过滤**:vendor 树里的 README/test/.git 随源码进 `lib/src/`(bake 也不过滤)。加 `library-source?` 过滤(只拷首个 datum 为 `(library …)` 的文件)是优化,但可能漏掉 `(program …)` 或非标准入口。短期保持行为一致,中长期评估。
2. **deliverable 搬运逻辑统一**:pack 的 `copy-dep-trees!`/`copy-obj-tree!` 与本文的 `install-dep-objects!` 做同类操作。提取共享 `(chandler deliverable)` 模块?本设计不强制,留后续 de-dup。
3. **per-dep 项目级卸载**:`chandler uninstall <dep>`(精确删某依赖,不 nuke 整个 lib/)。当前 install 的 `rm-rf lib/` + 重建足够;per-dep 卸载需要吗?
4. **chandler-setup.ss 消除路径**:launcher-wrapper(`#!/usr/bin/env chandler-run`)可解决 chicken-and-egg。独立设计,不在本文范围。
5. **install 与 build 合并**:`chandler install && chandler build` 是否合为一条 `chandler setup`?当前两步分离有其价值(install 不需 bake、可只做源码激活;build 需 bake、产出编译产物)。合并是 UX 糖,不是架构变化。
6. **bake selfinstall 迁移**:bake 删 install-task 后,bake 自身的 install-self 也需要改为直接拷贝(与 chandler install-self 同构,§8)。这是 bake 仓的改动,与 chandler 同步发布。

## 13. 参考

- [07-bake-integration.md](07-bake-integration.md) §分工(L39)——本文修订此条。
- [09-pack.md](09-pack.md)——pack 已自 bake 移交(2026-07-22),本文是 install 的同方向移交。
- [`chandler/install.ss`](../chandler/install.ss) L111-132(`bake-install-deps`,本文替换)· L296-300(`write-setup-file`,不变)。
- [`chandler/build.ss`](../chandler/build.ss) L94-160(`bake-one-dep`/`emit-dep-recipe`,本文修改)· L175-181(`find-umbrella`,复用)。
- [`chandler/pack.ss`](../chandler/pack.ss) L165-180(`deliverable?`/`copy-obj-tree!`,本文复用)· L206-229(`copy-dep-trees!`,同类操作)。
- [`bake/install.ss`](../../bake/bake/install.ss) L63-109(`run-install`——纯文件拷贝,确认可接管)· L111-124(`run-uninstall`)。
- [`chandler/registry.ss`](../chandler/registry.ss)——全局注册表(已由 chandler 拥有,不受影响)。
- [`chandler/lock.ss`](../chandler/lock.ss)——`locked-dep-srcdir`/`locked-dep-name`/`locked-dep-resources`(install/uninstall 的数据源)。
- [`chandler/layout.ss`](../chandler/layout.ss)——`split-pair`/`srcdir-join`/`lib-native-path`(src/mt 拆分路径工具)。
- Metis 预分析(`.sisyphus/analysis/`):三组 install scope 区分、chicken-and-egg 论证、迁移风险清单、AI 失败点 11 条。
