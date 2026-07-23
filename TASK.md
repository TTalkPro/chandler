# Chandler 实现任务清单

> 本仓库**只实现 Chandler**(包管理器)。bake 在另一仓库实现——凡涉及编译动作,Chandler 只做**排单 + 生成 recipe + 子进程调 bake**,以 mock bake 测试(见阶段 10)。
> (早期设计假想的 `bake compile-tree`/`bake native` 子命令真实 bake 并不存在,2026-07-22 已改为驱动真实 bake 任务,见 [07](designs/07-bake-integration.md)。)
>
> 设计权威:[designs/](designs/)。每条任务标注对应设计文档。实现约束:只 `import (chezscheme)`,限 Petite 可跑子集(见 [06 §2](designs/06-runtime-compat.md));`.ss` 首行 `#!chezscheme`、次行 `;;; <相对路径> --- <一句话>`([库布局规范](chez-skiff-library-layout.md))。
>
> **本机环境**(实现基线):Chez `10.4.1` / machine-type `ta6le` / petite 在场 / git `2.47.3` / 解释器 `~/.local/share/mise/installs/chezscheme/latest/bin/scheme`。

## 目标仓库布局(最终态)

```
chandler.ss                 (library (chandler))         umbrella:re-export activate/load-native/runtime
chandler/
  util.ss                   (chandler util)              横切工具:字符串 + alist + ignore-errors 宏
  fs.ss                     (chandler fs)                文件系统(原生 directory-list/rename/bytevector)
  proc.ss                   (chandler proc)              子进程封装(git / bake 调用)
  hash.ss                   (chandler hash)              纯 Scheme SHA-256(lock 哈希 / registry 完整性)
  sexp.ss                   (chandler sexp)              清单 read + canonical 写(只读不求值)
  layout.ss                 (chandler layout)            machine-type / so-ext / 路径 / 库名↔路径
  version.ss                (chandler version)           版本区间解析与匹配
  manifest.ss               (chandler manifest)          解析+校验 manifest.ss
  lock.ss                   (chandler lock)              读写 manifest.lock、拓扑序
  fetch.ss                  (chandler fetch)             git 镜像缓存 / 物化
  resolve.ss                (chandler resolve)           BFS 解析 / 冲突裁决 / 环检测
  install.ss                (chandler install)           lib/ 物化 / install 判定 / verify
  registry.ss               (chandler registry)          全局安装文件清单事务
  runtime.ss                (chandler runtime)            chez/skiff 探测 + 版本门
  activate.ss               (chandler activate)          activate / load-native 核心
  build.ss                  (chandler build)             排单 → bake + --allow-build 授权
  cli/
    args.ss                 (chandler cli args)          参数解析
    commands.ss             (chandler cli commands)      各子命令实现
    selfinstall.ss          (chandler cli selfinstall)   install-self / uninstall-self(对齐 bake)
    main.ss                 (chandler cli main)          dispatch + 退出码
    main.sps                                             程序入口(取 argv 调 main)
  test/fixtures.ss          (chandler test fixtures)     测试夹具:临时目录 / 文件 / git 仓构造
  test/*.ss                 与被测库共置的测试库
bin/chandler                开发期入口 wrapper(运行时发现:skiff 优先)
tests/
  run-tests.sps             汇总跑 chandler/test/*
  mock-bake.sh              build 测试用的 mock bake
  powershell-run.sh         Windows(.ps1)启动器验收:渲染后用 pwsh 实跑
manifest.ss  manifest.lock  Chandler 自身依赖清单(自举:零外部依赖)
recipe.ss                   bake 构建描述(另仓 bake 消费)
install.sh / install.ps1    薄壳:运行时发现 → chandler install-self(POSIX / Windows)
```

---

## 阶段 0 — 脚手架与测试地基

- [x] **0.1** 建目录骨架 + 空 umbrella `chandler.ss`(先只 re-export 一个 `chandler-version`),确认 `echo '(import (chandler))' | scheme -q --libdirs .` 可解析。对应:[库布局规范](chez-skiff-library-layout.md)。
- [x] **0.2** 极简测试框架 `chandler/test/harness.ss`(`define-test` / `assert-equal` / `assert-raises` / 统计),`tests/run-tests.sps` 汇总运行、非零退出码表失败。**不引入外部测试库**。
- [x] **0.3** `recipe.ss` 占位(注释说明由另仓 bake 消费);`manifest.ss` 写 Chandler 自身(`name "chandler"`、`(chez ">=10.0")`、无 deps)。验收:`scheme --script tests/run-tests.sps` 绿。

## 阶段 1 — 纯数据地基(无 I/O,最易测)

- [x] **1.1** `(chandler sexp)`:`read-sexp-file`(单一顶层 form、EOF 校验)、`write-sexp-file`(固定缩进 pretty-print、字典序可选)、**结构白名单校验器**(读到非预期结构即拒,禁 eval)。测试:round-trip 稳定、拒非法。对应:[02 §校验](designs/02-manifest-lock-spec.md)、[08 §3 信任](designs/08-bootstrap-security.md)。
- [x] **1.2** `(chandler layout)`:`(current-machine-type)`、`(so-ext)`(so/dylib/dll 按 mt)、`path-build`、`native-path`、库名↔相对路径互推、`srcdir` 拼接。测试:`ta6le`→`so`、`(a b)`→`a/b.ss`。对应:[库布局规范](chez-skiff-library-layout.md)、总设计 `load-native` 草案。
- [x] **1.3** `(chandler version)`:解析 `"1.2.0"`/`"^…"`/`"~…"`/`">=…"`/`"*"`/合取 `">=0.4 <0.5"`;`version-match?`、从 tag 列表 `select-highest`(剥 `v` 前缀)。测试覆盖各算子边界。对应:[02 §版本区间](designs/02-manifest-lock-spec.md)。

## 阶段 2 — 清单与锁

- [x] **2.1** `(chandler manifest)`:record 化 manifest.ss(name/version/chez/skiff/srcdir/deps/dev-deps/native/overrides/scripts),按 [02 §4 校验规则表](designs/02-manifest-lock-spec.md)逐条校验(format 门、pin 三选一、path 存在、名唯一不撞内建)。测试:合法解析 + 每条非法用例。
- [x] **2.2** `(chandler lock)`:record 化 + 读写 `manifest.lock`([02 §2 格式](designs/02-manifest-lock-spec.md));`manifest-sha256` 计算(sha256 内容哈希);**同输入必出字节相同**(字典序 + 固定缩进)。测试:round-trip 字节稳定。
- [x] **2.3** `(chandler cli commands)` 之 `init`:生成骨架 `manifest.ss`(+ `--lib` 出目录骨架)、`.gitignore` 追加 `lib/`。对应:[01 add/init](designs/01-cli.md)、[04 §3](designs/04-fetch-cache.md)。

## 阶段 3 — 获取与缓存

- [x] **3.1** `(chandler proc)`:`run-capture`(`open-process-ports`,返回 stdout/stderr/exit)、`run-check`(非零即抛带上下文)。**先于 git 封装**,后续 bake 调用复用。
- [x] **3.2** `(chandler fetch)` 缓存层:XDG 缓存根解析、`<url-key>`(规范化 + sha256 前 16 + 可读残端)、镜像 clone/fetch、文件锁。对应:[04 §1-2,§6](designs/04-fetch-cache.md)。
- [x] **3.3** `(chandler fetch)` 解析原语:`resolve-branch`/`resolve-tag`/`list-tags`/`has-rev?`,尽量走缓存零网络;`materialize`(`--shared` clone + detached checkout,保留 `.git`);`--offline` 语义。测试:对一个**本地临时 git 仓**(测试内 `git init` 造)跑通,不依赖外网。对应:[04 §2-4](designs/04-fetch-cache.md)。

## 阶段 4 — 解析

- [x] **4.1** `(chandler resolve)`:BFS 层序收集 + 三级元数据来源(overrides>上游 manifest>裸库默认)+ `(skiff …)`/`(rnrs …)`/`(chezscheme)` 内建排除。对应:[03 §1](designs/03-resolution.md)、[02 §3 overrides](designs/02-manifest-lock-spec.md)。
- [x] **4.2** 冲突裁决 R1-R4(根覆盖/层近者胜/恒警告/异域同名硬错)+ 区间求交。测试:构造多来源同名冲突各分支。对应:[03 §2](designs/03-resolution.md)。
- [x] **4.3** 环检测 + 拓扑序(被依赖先)+ 写 lock。测试:线性、菱形、成环三形。对应:[03 §3-4](designs/03-resolution.md)。

## 阶段 5 — 安装(端到端首个里程碑)

- [x] **5.1** `(chandler install)`:`install` 判定逻辑(lock 是否过期→是否重解析→物化→清理孤儿),幂等、脏改动拒动。对应:[01 §install 判定](designs/01-cli.md)。
- [x] **5.2** `verify`(lib/ 对 lock:rev 匹配 + `git status --porcelain` 查脏)、`list`/`tree`。对应:[01](designs/01-cli.md)、[04 §3](designs/04-fetch-cache.md)。
- [x] **5.3** **里程碑**:`tests/smoke.ss` 用本地临时 git 仓造 2-3 个依赖(含一层传递),跑 `init→add→install→verify→list` 全绿。

## 阶段 6 — 运行期激活

- [x] **6.1** `(chandler activate)`:`activate`(读 lock→prepend `library-directories`→topo 序 `load-shared-object` natives,幂等)、`activate-natives`(native-only 子集)、`load-native`/`native-path`(总设计草案)。umbrella `chandler.ss` re-export。
- [x] **6.2** `(chandler runtime)`:`current-runtime`(探测顶层 `skiff-version` 绑定)、`verify-runtime!`(chez/skiff 区间门,expected vs actual 措辞)。对应:[06 §3-4](designs/06-runtime-compat.md)。
- [x] **6.3** 测试:脚本顶层 `(activate)` 后 `(import (dep))` 可解析(用阶段 5 的临时依赖 + 一个假 `.so`/纯 Scheme 库);`verify-runtime!` 版本不符抛错。对应:[06 §4](designs/06-runtime-compat.md)。

## 阶段 7 — CLI 装配

- [x] **7.1** `(chandler cli args)`:子命令 + 旗标解析(`--offline`/`--allow-build`/`-C`/`--verbose`/`--global` 等),`--porcelain` s-表达式输出。
- [x] **7.2** `(chandler cli main)`:dispatch + sysexits 退出码表([01 §退出码](designs/01-cli.md));`run`/`exec`(组 `CHEZSCHEMELIBDIRS` + native preamble 后 exec 解释器,选 chez/skiff 见 [06 §5](designs/06-runtime-compat.md))。
- [x] **7.3** `bin/chandler` wrapper + `chandler/cli/main.sps` program;`chandler --version`/`-T`/`--help`。验收:`bin/chandler init` 起步冒烟。

## 阶段 8 — 全局安装与注册表

- [x] **8.1** `(chandler registry)`:注册表格式([05 §2](designs/05-install-registry.md))、安装事务(冲突检测→staging→进位→登记,弱事务 + 回滚)。测试:装/冲突/野文件。
- [x] **8.2** 升级(孤儿清理)、`uninstall --global`(哈希核对)、`list --global`、`doctor --global`(野文件/缺失/漂移/ABI 失效/残留)。对应:[05 §4](designs/05-install-registry.md)。
- [x] **8.3** `install --global` 命令接线 + 遮蔽规则文档化输出。对应:[05 §3,§5](designs/05-install-registry.md)。

## 阶段 9 — 与 bake 的接口(mock 验证)

- [x] **9.1** `(chandler build)`:按 lock 拓扑序**排单**,对每依赖子进程调 `bake compile-tree`/`bake native`(porcelain);授权:`--allow-build`(白名单粒度)+ 授权绑构建描述哈希写 `.chandler-approvals`。对应:[07 §2-3](designs/07-bake-integration.md)、[08 §3](designs/08-bootstrap-security.md)。
- [x] **9.2** mock bake(`tests/mock-bake.sh`)+ 测试:`chandler build` 排单顺序、`--allow-build` 门、描述哈希失效重提示。对应:[07 §6](designs/07-bake-integration.md)。
- [x] **9.3** 确认对外共享库面 `(chandler lock/registry/layout/sexp)` 导出干净(bake 反向依赖),不 import bake。对应:[07 §5](designs/07-bake-integration.md)。

## 阶段 10 — 自举与安全收尾

- [x] **10.1** 安装模型对齐 bake:`install.sh` 薄壳(运行时发现 skiff→Chez)委托 `chandler install-self`(`chandler/cli/selfinstall.ss`);默认装 `~/.local`,`--prefix`/`--global`;生成运行时发现启动器 + `.chandler-self.files` 清单;`uninstall-self`/`self-update`。对应:[08 §2](designs/08-bootstrap-security.md)。
- [x] **10.2** 安全红线落地:clone 时 `core.hooksPath=/dev/null`、清单只 `read`、`--allow-build` 描述哈希绑定。威胁清单对照自查。对应:[08 §3-4](designs/08-bootstrap-security.md)。
- [x] **10.3** `recipe.ss` **落地为可跑的 bake 构建描述**(`build`=`library-task '(chandler)`、`test`、`install`/`uninstall`=`install-task`/`uninstall-task` → Chez lib dir);README 用法;全量 `run-tests` **三运行时全绿**(`scheme`/`petite`/已部署的 `skiff` 均 132/132);`chandler run` 依 manifest 自动选运行时(skiff-only→skiff)。
- [x] **闭环验证**:`bake build → test → install → uninstall` 全通(bake 0.1.0 跑在 skiff 0.1.0 上);`bake install` 把 `(chandler …)` 库树装进 `~/.local/share/chez/lib`,`(import (chandler lock/registry/…))` 从安装位置可解析——正是 bake 自身依赖的库面。**skiff 跑 · chandler 管依赖 · bake 装库** 三工具互相支撑,生态闭环达成。
- [x] **自安装改为基于 `bake install`**:`chandler install-self` 去掉自写的库树拷贝(`install-tree!`),库树完全委托 `bake install`/`bake install-global`(读本仓 recipe.ss 的 install-task),chandler 只补运行时发现启动器;`uninstall-self` 据 bake 的 `.bake-install/chandler.files` 清单删库(不依赖源码)。`recipe.ss` 增 `install-global`/`uninstall-global`(target global)。端到端:`./install.sh`(库经 bake)→ 安装的 chandler 在 skiff 上管理项目 → `uninstall-self` 零残留,全通。

## 阶段 11 — deploy loader 统一(design 10)— **已完成**

- [x] **11.1-11.7 (L0-L6)** deploy loader 移交 chandler:`bootstrap.ss` runtime-aware(stock+skiff 同一份)、`skiff --app` 删除、sysexits + s-expr 诊断、`verify-pack --target`、pack-spec 更新。详见 [10](designs/10-deploy-loader.md)。

## 阶段 12 — runtime-paths:统一资源定位 API(design 11)— **已完成**

- [x] **12.1 (M0)** `chandler/runtime-paths.ss`:`app-root` / `app-resource-path` / `find-app-resource-path`(env `APP_ROOT` + 路径安全校验)。
- [x] **12.2 (M1)** install 资源复制 → `lib/share/<lib>/resources/` + resolve 传播 `resources` 从 dep manifest → lock。
- [x] **12.3 (M2)** pack `copy-share!` 从 `lib/share/` → `<pack>/share/`(lock 驱动,不套 `.so` filter)。
- [x] **12.4 (M3)** `lib-resource-path` / `find-lib-resource-path`:`(library-object-filename)` N+1 反推 prefix + source fallback + `ignore-errors` 容错。
- [x] **12.5 (M4)** manifest/lock schema `(resources ...)` simple + multi-lib 形 + 校验。
- [x] **12.6 (M5)** `define-resource-path-resolver` 宏(app + quoted libref 两种 wrapper)。
- [x] **12.7 (M6)** 文档:TASK.md 更新 + 设计标注完成。

## 阶段 13 — chandler 分层:dev-time 工具 + runtime 公共基础设施(design 12)— **已完成**

- [x] **13.1 (N0)** design 12 文档落地。
- [x] **13.2 (N1)** rename `(chandler runtime)` → `(chandler runtime-detector)`(文件 `runtime.ss` → `runtime-detector.ss` + 9 处 import 同步)。
- [x] **13.3 (N2)** `(chandler base)` umbrella re-export 9 runtime subset 库(runtime-paths/hash/version/util/fs/sexp/layout/runtime-detector/proc)。
- [x] **13.4 (N3)** manifest `(runtime-subset ...)` 字段 + lock 快照。
- [x] **13.5 (N4)** `chandler init` 模板注入 `(deps (chandler ...))`(soft 强制,自举例外)。
- [x] **13.6 (N5)** `chandler install` warning(diagnostic)+ `--strict` 拒绝(hard)。
- [x] **13.7 (N6)** pack runtime-only filter:chandler 作为 transitive dep 时跳过 dev-only 子库(pack/install/build/cli 等),只复制 runtime-subset + base umbrella。
- [x] **13.8 (N7)** 文档:TASK.md 更新 + 设计标注完成。

---

## 里程碑

| M | 完成阶段 | 可演示 |
|---|---------|--------|
| M1 | 0-2 | `chandler init` 生成清单;清单/锁解析+校验有测试 |
| M2 | 3-5 | `init→add→install→verify` 对本地 git 仓端到端跑通 |
| M3 | 6-7 | `chandler run app.ss` 激活依赖并运行;完整 CLI |
| M4 | 8-10 | 全局安装/卸载、bake 排单(mock)、install.sh 自举 |
| **M5** | **11** | deploy loader 统一(已完成)|
| **M6** | **12** | runtime-paths:app/lib 资源定位 API + `<prefix>/share/` 层(已完成)|
| **M7** | **13** | chandler 分层:`(chandler base)` umbrella + 强制依赖 + runtime-only filter(已完成)|

- [x] **repl 命令**:交互 shell,自动挂库路径(规则见下,与 run/exec/setup 统一)。默认运行时跟随 chandler 当前所在(skiff/chez),`--runtime` 可覆盖。

- [x] **依赖模型改为 Bundler 式(vendor/ + 扁平 lib/ + setup 文件)**:
  - `chandler install`:git 依赖整仓 checkout 到 **`vendor/<name>/`**,再由 **`bake install`** 装进**扁平 `lib/`**(结构同 `~/.local/share/chez/lib`:`lib/<name>.ss`、`lib/<name>/`、`lib/native/<mt>/`)。故库搜索只挂 `lib/` 一个目录。install 依赖 bake。path 依赖不进 vendor/lib,直挂源目录(live)。
  - **生成 `chandler-setup.ss`**(Bundler 的 `bundler/setup`):主脚本顶部 `(load)` 它即挂库路径 + 载 native,纯 skiff/scheme 跑无需 chandler。位置无关:依入口脚本(`(command-line)` 首元素)所在目录解析项目根,不硬编码绝对路径(`(load)` 是 cwd 相对、被载文件拿不到自身路径,故用入口脚本路径)。
  - **run / exec / repl / activate 库搜索规则统一**(install 的 `resolved-libdirs` / `project-mode?`):项目(lock 有依赖)= `lib/` + path 源目录 + 项目库根 + 全局兜底(项目最高优先);非项目 = 全局。
  - `verify` 改查 vendor/ rev + lib/ 存在;`activate` 挂扁平 lib/。测试全改;`scheme`/`petite`/`skiff` 三运行时 132/132。

- [x] **对齐 bake install 的 src/mt 拆分(2026-07-22)**:bake install 落点由扁平 `lib/` 改为 **src/mt 拆分**——源码 → `<prefix>/src/`、平台绑定产物(编译 `.so` + native)整棵 `_build/<mt>/` → `<prefix>/<mt>/`;native 收进所属库 `<prefix>/<mt>/<lib>/native/`。chandler 全线跟进:
  - **消费模型改「一对」**:库搜索条目可为 Chez 库目录**对** `(源 . 对象)`;`(chandler layout)` 新增 `split-pair`/`entry->arg`/`libdirs->arg`(pair → `src::obj`)/`native-so?`/`lib-native-*`。run/exec/repl/activate/setup 统一用「条目」(pair 或字符串)。
  - **项目本地** `lib/` 成 src/mt 前缀:`install` 装进 `lib/{src,<mt>}`(只发源码),挂一对 `lib/src::lib/<mt>`;`native-load-paths` 改扫 `lib/<mt>/**/native/`;`chandler-setup.ss` 改挂 pair + **运行时扫描** native(故 install 后再 build 亦生效)。
  - **`chandler build` 重构为驱动真实 bake**:bake 无 `compile-tree`/`native` 子命令——改为于项目根生成 recipe(`define-lib-roots "lib/src"` + 逐依赖 `library-task` + 授权的 `native-task (lib …)`),跑 `bake -f … build-all`,再拷 `_build/<mt>/` → `lib/<mt>/`。见 [07](designs/07-bake-integration.md)。
  - **全局注册表迁 src/mt**([05](designs/05-install-registry.md)):`install --global` 落 `<prefix>/{src,<mt>}`(源 → `src/`、`_build/<mt>/` → `<mt>/`),注册表 `<prefix>/.chandler/registry/`,与 bake install 同一全局前缀。默认前缀 `~/.local/share/chez`(对齐 bake,去 `/lib` 去 XDG)。
  - **自安装 + 启动器**:落 `<prefix>/{src,<mt>}`,启动器挂 `<prefix>/src::<prefix>/<mt>` 跑 `<prefix>/src/chandler/cli/main.sps`;`recipe.ss` 的 install-task 加 `(needs build)`(bake 恒装编译内容)。
  - **验证**:全套 **133 用例三运行时(scheme/petite/skiff)全绿**;真实 bake 端到端(纯 Scheme 跨依赖 import + native `--allow-build`)跑通:`install → build → run` 用编译产物解析,native 经 setup 扫描自载。

- [x] **对齐 bake native 自加载 loader + 输出改英文(2026-07-22 之二)**:bake 0.1.2 为每个带 native 的库生成 `(<lib> native-loader)`(产物 `<mt>/<lib>/native-loader.so`,随交付树落位),库 FFI 被引用时自加载。
  - **chandler 零适配即命中**:loader 候选序第 2 条扫 `(library-directories)` 各根 obj 侧,而 chandler 挂的 `lib/src::lib/<mt>` 对象侧恰是 native 落点。实测:清空 `_build/` 后仅靠该对跑通;移走 native 则报 loader 自己的错。
  - **`chandler-setup.ss` 生成优化**:不再预加载有 loader 的库(自加载**惰性**——不碰 FFI 就不 dlopen),扫描降级为**兜底**,只加载无 `native-loader.so` 的第三方库;`activate`/`run`/`repl` 同此分层。见 [07 §5b](designs/07-bake-integration.md)。
  - **`.gitignore` 补齐**:生成的 `.chandler-build.ss` 与 bake 产出的 `_build/`(`.chandler-approvals` 是信任决定,是否提交交由用户,故不入)。
  - **用户可见输出改英文**(CLI 帮助 + 运行期提示/错误),便于通用;源码 `;;;` 注释仍为中文(本仓约定)。
  - 新增自加载跳过的回归用例;全套 **134 用例三运行时全绿**。

- [x] **Windows/PowerShell 补强 + 显式指定运行时(2026-07-22 之三)**:
  - **修掉 Windows 分隔符 bug**:`libdirs->arg` 原写死 `:`/`::`。据 ChezScheme `s/syntax.ss` 的 `parse-string`(`^ is ; under windows : otherwise`;`src-dir^^obj-dir` 为对),分隔符须随平台 —— 新增 `path-sep`,Windows 用 `;` / `;;`。
  - **Windows 启动器 `.cmd` → `.ps1`**(与 bake 对齐):PowerShell 已取代 cmd,PATH 上 `.ps1` 可裸名调用。规避 PowerShell 四坑(无 `exec` 须回传 `$LASTEXITCODE`、PS 7.3+ 原生非零退出会终止、函数内 `$args` 是函数自己的、路径用正斜杠)。分隔符取 `[System.IO.Path]::PathSeparator`(与 Chez 同规则),故同一份脚本 Windows 正确、Linux pwsh 下亦可**实跑**。
  - **显式指定运行时**:新增 `CHANDLER_RUNTIME=skiff|chez`(选哪一种),与既有 `CHANDLER_SKIFF`/`CHANDLER_SCHEME`(选哪个可执行文件)配套。优先级 `--runtime > CHANDLER_RUNTIME > manifest > 默认`,**启动器与 run/exec/repl 共用一套**。非法值报错(启动器 64);显式覆盖照单执行——找不到即 127,不静默回退、不再探测。
  - **顺手修掉 skiff 误判为 chez**:skiff 自 0.1.1 起把顶层 `skiff-version` 绑为**过程**而非字符串,而 `skiff?` 只认字符串 → `current-runtime` 在 skiff 上报 `chez`,连带版本门挂错、`runtime-version` 回落成 Chez 版本、repl 兜底选错运行时。改为**两种绑法都认**(与 bake 同)。此 bug 由既有 `runtime-detection` 用例暴露(skiff 从 137 掉到 136),非本轮改动引入。
  - **测试**:新增 `tests/powershell-run.sh`(P1–P9,渲染 `.ps1` 后用 pwsh **真跑**:语法/强制/覆盖/退出码/参数透传/端到端启动;无 pwsh 则干净跳过)**11 断言全绿**,并接入 `bake test-ps`;sh 启动器同项手工验证一致。Scheme 侧新增两启动器语义对齐、`CHANDLER_RUNTIME` 解析、skiff 版本不回落等用例,**137 用例三运行时全绿**。

- [x] **skiff 以内置 `(skiff-version)` 自证 → 探测收紧 + 版本门归位(2026-07-22 之四)**:
  - **探测收紧**:启动器原先只验「输出含口令」,现改为验 **`<token>:<数字打头版本>`** —— 一次调用同时确认「能跑 R6RS 程序」与「确实是 skiff」。实测:把一个指向 Chez 的 shim 命名为 `skiff` 放进 PATH,旧判据会误采纳,新判据正确跳过并回退真 Chez。sh/ps1 共用同一份探测程序文本(各写一份必漂移)。
  - **两个坑写进注释与测试**:① 取值必须走反射 `(top-level-value (string->symbol "skiff-version"))`,直接写 `(skiff-version)` 在 `--program` 模式下是展开期未绑定标识符会报错(而 CLI/探测正是 `--program`);② 探测程序文本不得含单引号(sh 侧要嵌在 `'…'` 里),故用 `string->symbol` 而非 `'skiff-version`。
  - **`(skiff …)` 版本门归位**:此前 skiff 被误判为 chez,导致 manifest 的 skiff 约束**从未被执行**且冒假警告;修复后 `(skiff ">=99")` 正确报 `have 0.1.1`,`(skiff ">=0.1")` 放行。
  - **`chandler --version` 报告所在运行时**(与 bake 同款):`chandler 0.1.2 (skiff 0.1.1) (chez 10.4.1)`。PowerShell 验收据此把 P4/P5 从「能启动」升级为**校验选中的确实是哪个运行时**,13 断言全绿。
  - **pack 侧结论**:`pack.manifest` 的 `(target … (skiff-version …))` 由 **bake** 探测并写入、由 `skiff --app` 校验,bake 用的正是同款反射 + 过程/字符串双容忍,故**不受影响、chandler 无需改动**;chandler 侧的关联只在 `manifest.ss` 的 `(skiff …)` 门(已归位)。
  - **138 用例三运行时全绿** + PowerShell 13/13。

- [x] **安装路径补齐 Windows + 文档化(2026-07-22 之五)**:
  - **新增 `install.ps1`**(install.sh 的 PowerShell 对应物,对齐 bake):此前只有 POSIX 的 `install.sh`,而启动器已是 `.ps1` —— Windows 无自举入口。两者语义一致:检查前置 bake、能力探测发现运行时、认 `CHANDLER_RUNTIME`/`CHANDLER_SKIFF`/`CHANDLER_SCHEME`、非法值 64 / 无运行时 127。
  - **`install.sh` 同步收敛**:它原先自带一份**旧判据**的探测副本(只验口令),已随启动器升级为「口令 + 自证版本」,并补上强制运行时分支;输出改英文。两处副本都注明与 `self-probe-src` 保持同步(自举脚本无法 import chandler,重复不可避免)。
  - **README 重写安装章**:前置环境表(运行时 / git / bake / Windows 的 PowerShell,并点明 **Petite 不够**——无编译器而 `bake install` 要编译)、POSIX 与 Windows 两套步骤、执行策略提示、卸载与开发期用法;「指定运行时」章补安装期用法与 `--version` 自证。
  - 端到端实跑二者(install → 启动器 → 卸载零残留);PowerShell 验收增 P10–P12(install.ps1 语法 / 非法运行时 / 缺 bake),**16 断言全绿**。

## 进度

**阶段 0-13 全部完成,M1-M7 全部达成。** 环境:Chez 10.4.1 / ta6le。

- 测试:`tests/run-tests.sps` **219 用例全绿**(18 个 suite:util/fs/sexp/layout/version/manifest/lock/proc/fetch/resolve/install/activate/cli/registry/build/pack/selfinstall/**base**/**runtime-paths**)。**`scheme`、`petite`、已部署的 `skiff` 三运行时均全绿**。
- **skiff 端到端验证**:skiff 应用(manifest 声明 `(skiff …)`)经 chandler-on-skiff 走 `init→add→install→verify→run` 全通;`chandler run` 依 manifest 自动选运行时(skiff-only→skiff、chez→chez),应用运行期自证落在正确运行时。
- 端到端验证:`init→add→install→verify→list→tree→run→exec` 经二进制跑通;`(activate)` 真实挂载并 import 依赖;全局 `install/uninstall/list/doctor`;`build` 排单经 mock bake + 授权哈希绑定;`install-self` 装 `~/.local` + 自卸载自洽(启动器 skiff 优先运行时发现)。
- 实现的库:`(chandler)` umbrella + 底座 `util/fs/hash/proc` + `sexp/layout/version/manifest/lock/fetch/resolve/install/registry/runtime-detector/activate/build/pack` + **`runtime-paths`**(资源定位)+ **`base`**(runtime umbrella)+ `cli.{args,commands,main,selfinstall}`;测试夹具 `(chandler test fixtures)`。
- 对外共享面(bake 反向依赖):`(chandler lock/registry/layout/sexp)` 导出干净,不 import bake。**(chandler base)** umbrella 对所有 lib/app 提供 runtime 公共能力(资源定位/hash/版本/路径/运行时探测)。

### 实现期发现/决定(偏离或补充设计处)

1. 新增 `(chandler hash)`——纯 Scheme SHA-256(设计假定有,Chez 基础库无);lock 内容哈希与 registry 文件完整性均用它。
2. 新增 `(chandler proc)`——子进程封装,用临时文件 + `system` 捕获退出码(`open-process-ports` 拿不到退出码)。**修掉一处隐蔽 bug**:`get-string-all` 对空文件返回 eof 而非 `""`,曾致 `git status --porcelain` 干净仓库崩溃。
3. `add`/`remove` 采用 datum 级改写(而非设计倾向的文本级插入);对 init 生成的规范清单无损,代价是重排手写格式——v0.1 取舍,已在 [01](designs/01-cli.md) 注明的 fallback 范围内。
4. `run` 用生成的 preamble 脚本(先 `load-shared-object` native 再 `load` 目标),自包含、不需子进程持有 `(chandler)`。

### 优化 pass(去冗余 / 清模块 / 用宏)

- **新增底座 `(chandler util)`**(字符串 split/trim/prefix/suffix/search/join、`alist-ref`、`ignore-errors` 宏)与 **`(chandler fs)`**(原生 `directory-list`/`rename-file`/`delete-directory`/bytevector I/O,替掉散落各处 shell-out 到 `ls`/`cp`/`mv`/`rm`/`find`)。分层:`util`(叶)← `fs` ← `proc` ← 其余域模块。
- 各模块删掉自带的 split/trim/prefix?/contains?/parent-dir/ensure-dir/rm-rf/dir-entries/assq-val 副本,统一走 util/fs(`fetch` 减 ~90 行;`registry` 完全脱离 `proc`)。
- **测试夹具集中到 `(chandler test fixtures)`**(mktmp/write-file/read-file/trim/git-init!/git-commit!/make-lib-repo/make-native-lib/make-app),消除 7-8 个测试文件各写一份的 boilerplate。
- 最佳实践:文件操作优先 Chez 原生原语而非 shell;重复的 `(guard (e [#t #f]) …)` 收敛为 `ignore-errors` 宏。全程 `scheme` + `petite` 132 用例保持全绿。

## 进行中任务

### P1 — pack 布局统一为 .local/share/chez 结构 — **已完成(2026-07-23)**

将 pack 输出布局与全局安装前缀 `~/.local/share/chez/` 统一,消除 `lib/<mt>/` 与 `<mt>/` 的分裂。**一个包解开就是一个自带运行时的安装前缀**:`<mt>/` 对象根、`share/<name>/resources/` 资源、`.chandler/<name>/manifest.ss` 清单三层逐一对应。设计见 [09 §包布局](designs/09-pack.md)、[11 §3](designs/11-runtime-paths.md)。

| # | 任务 | 状态 | 文件 |
|---|------|------|------|
| 1 | `pack-lib-dir` 去掉 `lib/` 前缀 → `<mt>/` | ✅ 已完成 | `chandler/pack.ss` |
| 2 | `bootstrap-source` 生成 `library-directories` 指向 `<mt>/` | ✅ 已完成 | `chandler/pack.ss` |
| 3 | `copy-resources!` 改为 `share/<app>/resources/`(与 dep 资源 `share/<dep>/resources/` 同构) | ✅ 已完成 | `chandler/pack.ss` |
| 4 | `manifest-head` 的 `(lib-dirs ...)` 更新为 `"<mt>"` | ✅ 已完成 | `chandler/pack.ss` |
| 5 | `manifest-native-lines` 的 native 路径从 `"lib/<mt>/..."` 改为 `"<mt>/..."` | ✅ 已完成 | `chandler/pack.ss` |
| 6 | pack 中添加 `.chandler/<app>/manifest.ss`(与全局 install 一致) | ✅ 已完成 | `chandler/pack.ss`(`write-app-manifest!`;源项目无 manifest.ss 时合成最小清单) |
| 7 | `runtime-paths.ss` 的 `app-resource-path` 从 `$APP_ROOT/resources/` 改为 `$APP_ROOT/share/<app>/resources/` | ✅ 已完成 | `chandler/runtime-paths.ss`(候选序 + 新增 `app-name`) |
| 8 | 全量测试 + pack 端到端验证 | ✅ 已完成 | `chandler/test/{pack,runtime-paths}.ss` |

**实现期决定**:

- **`app-resource-path` 用候选序而非单一路径**:`share/<app>/resources/`(部署/安装态)优先,回落 `<app-root>/resources/`(源码 checkout —— 资源就摆在项目根,那是应用作者写的目录)。故同一份应用代码四态通用,不必条件分支。
- **应用名怎么来**:新增 `(app-name)`,三级 —— `APP_NAME` 显式(共享前缀装了多个应用时由启动器传,**可选**)> `<app-root>/.chandler/` 下唯一条目(pack 恒只写一个)> `#f`(只走源码态落点)。**包内不需要第二个 env**,`APP_ROOT` 仍是唯一必需变量;`.chandler/` 多于一个条目即返回 `#f`,不猜。
- **两处跨仓待跟进**(都不阻塞):① bake `bake/native.ss` 生成的 native-loader 候选 1 仍拼 `$APP_ROOT/lib/<mt>/…`,现恒 miss —— 但候选 2 扫 `(library-directories)` 对象侧,而 bootstrap 挂的正是 `<mt>/`,native 照常自加载(唯一没有 `library-directories` 可依赖的 boot 模式已作废);② skiff 的 `chez-skiff-pack-spec.md` 仍以 `(lib-dirs "lib/<mt>")` 举例,文档宜同步。

**验证**:`scheme`/`petite`/`skiff` 三运行时 **219/219 全绿**(pack suite 由 17 增至 21 用例,runtime-paths 由 13 增至 18);端到端另造一个带资源、以 `(chandler runtime-paths)` 读资源的应用(bake 编译 → `chandler pack --runtime petite`)——clean-env(`env -i`)启动打印出 `share/<app>/resources/hello.txt` 内容、整包 `cp` 到别处后仍命中、`verify-pack --target` 0 bad;`chandler run` 跑源码态同一入口则命中项目根 `resources/`。skiff-demo 仓库的 pack 组装 + `verify-pack --target`(82 ok/0 bad)亦已实跑,但其 `_build/` 是旧 skiff 编译产物,启动报「different compilation instance of (skiff)」——与本次改动无关,需在该仓 `chandler deps && bake build` 后再验;其 `mdserver/app.sls` 仍手写 `$APP_ROOT/resources`,按 [11 §3](designs/11-runtime-paths.md) 迁移到 `(app-resource-path)` 后即可跟随新落点(属该仓改动,未动)。

### P1b — APP_ROOT 即库前缀 + 去掉 chandler-setup.ss — **已完成(2026-07-23)**

P1 之后 `APP_ROOT` 的语义被钉死为**库前缀**,三态逐层同构:全局 `~/.local/share/chez` · 项目自己的 `lib/` · 解开的 pack。于是资源与 native 各只剩**一种拼法**:

```
$APP_ROOT/share/<app>/resources/…      应用数据
$APP_ROOT/<mt>/<libpath>/native/…      native(bake 生成的 loader 自己拼)
```

| # | 改动 | 文件 |
|---|------|------|
| 1 | `chandler run`/`repl` 在 exec 前设 `APP_ROOT=<project>/lib`(已有值不覆盖);`chandler env` 同时导出它 | `chandler/cli/commands.ss` |
| 2 | `(activate)` 同上(进程内入口) | `chandler/activate.ss` |
| 3 | **删除 `chandler-setup.ss` 生成**(`write-setup-file`/`setup-datum` 及其 `.gitignore` 条目) | `chandler/install.ss`、`chandler/cli/commands.ss` |
| 4 | `lib/` 成为**完整前缀**:项目 `resources/` → `lib/share/<name>/resources/`(按 mtime 增量,`deps`/`run`/`repl` 都同步)、manifest 快照 → `lib/.chandler/<name>/manifest.ss` | `chandler/install.ss`(`sync-app-prefix!`) |
| 5 | `app-resource-path` 收敛为单一形状(去掉 `<app-root>/resources/` 回落);认不出应用名时报的是「这个前缀属于谁」而非「文件不存在」 | `chandler/runtime-paths.ss` |
| 6 | bake 的 native-loader 候选 1 `$APP_ROOT/lib/<mt>/…` → `$APP_ROOT/<mt>/…`(跨仓;`tests/loader-run.sh` Z4/Z5 同步,35 断言绿) | bake `bake/native.ss` |

**为什么删 setup**:它是**生成物**,把「库搜索规则 + APP_ROOT 约定」复制进了每个项目,规则一改就有两处要同步(P1 改前缀语义时正好撞上)。启动只留 `chandler run` 一条路;别的进程用 `eval "$(chandler env)"`,已持有 `(chandler)` 的脚本用 `(activate)`。设计 [13 §3.4/§6](designs/13-chandler-owns-install.md) 当年「保留 setup」的结论已在原处标注反转,其 §6.2 预见的 launcher 路线就是今天的 `chandler run`。

**验证**:三运行时 **220/220 全绿**;端到端(带资源的应用,`(chandler runtime-paths)` 读资源):`chandler run` 打印 `APP_ROOT=<project>/lib`、命中 `lib/share/resdemo/resources/`,改一个资源文件后再跑即生效;`chandler pack` + `env -i` clean-env 启动命中 `<pack>/share/resdemo/resources/`,`verify-pack --target` 0 bad。

**顺带修掉的两处**(都在验证 skiff-demo 时暴露):

- **`chandler run --script X <args>` 静默丢参数** —— `--script` 分支只取 `--` 之后的 `rest`,位置参数直接扔掉,于是 `chandler run --script serve.ss 8099` 里的端口没传下去、应用拿默认值跑。改为 `rest + 剩余位置参数`(脚本名若来自位置参数才剥掉首个)。
- **`recipe.ss` 整份加载失败** —— bake 0.1.5 已删除 `install-task`/`uninstall-task`(bake designs/26:install 归 chandler),recipe 里还留着,导致 `bake` 连 `build` 都跑不了(`variable build is not bound`)。四个 install/uninstall 任务已删除;chandler 的安装本就由自含的 `bootstrap.ss` 负责(拷源码 + `_build/<mt>/` + 写启动器),故顺序是 **先 `bake` 编译、再 `scheme --script bootstrap.ss --force`** —— 否则装进前缀的是上一轮的旧对象(本轮就撞上了:前缀里 `install.so` 是改动前编译的,而 `cli/commands.ss` 从源码现编,于是 `sync-app-prefix!` unbound)。

**skiff-demo 已同步**(该仓改动):`mdserver/app.sls` 的 `docs-root` → `(app-resource-path)`;`serve.ss` 去掉 `(load chandler-setup.ss)`;`manifest.ss` 去掉 `(chez ">=10.0")`(它 `import (skiff web)`,本就跑不了 stock chez,而双声明按 [06 §3](designs/06-runtime-compat.md) 是「双跑项目」→ `chandler run` 会选 chez);README/recipe/.gitignore 同步。端到端实跑:`chandler deps → bake → chandler build → chandler run --script serve.ss <port>` 起服务 `/` 与 `/hello` 均 200(docs 落 `lib/share/skiff-demo/resources`);`chandler pack` 后 `env -i` clean-env 启动 `/` 与 `/features` 均 200(docs 落 `<pack>/share/skiff-demo/resources`)、整包 `cp` 到别处仍 200、`verify-pack --target` 125 ok/0 bad。

### P2 — 运行时依赖 vs 开发时依赖分离(dev-deps)

当前 `(deps ...)` 和 `(dev-deps ...)` 区分不严格。chandler 本身应作为 runtime dep(runtime subset 隐式),bake 等纯开发工具应放 `(dev-deps ...)`。

| # | 任务 | 状态 | 文件 |
|---|------|------|------|
| 1 | `chandler init` 模板:chandler 留 `(deps ...)`,bake 放 `(dev-deps ...)` | 🔲 待实现 | `chandler/cli/commands.ss` |
| 2 | `chandler install` 全局安装:只装 `(deps ...)`(runtime),不装 `(dev-deps ...)` | 🔲 待实现 | `chandler/cli/commands.ss` |
| 3 | `chandler pack`:只打 `(deps ...)`(部署态不需要 dev-deps) | 🔲 待实现 | `chandler/pack.ss` |
| 4 | 全局 install 也用 `chandler-dev-only-so?` filter(只装 runtime subset) | 🔲 待实现 | `chandler/cli/commands.ss` |

### P3 — app 全局安装时创建命令行入口

当 `chandler install` 的是 app(有 `(app (entry ...) (main ...))`)时,创建启动器到 `~/.local/share/chez/bin/<app>`,并 symlink 到 `~/.local/bin/<app>`,用户裸名调用。

| # | 任务 | 状态 | 文件 |
|---|------|------|------|
| 1 | app install 检测:manifest 有 `(app ...)` 时创建 bin/ 启动器 | 🔲 待实现 | `chandler/cli/commands.ss` |
| 2 | 启动器模板:挂全局 `src::<mt>` 对 + 运行时发现(skiff 优先) | 🔲 待实现 | `chandler/cli/commands.ss` |
| 3 | symlink `~/.local/bin/<app>` → `~/.local/share/chez/bin/<app>` | 🔲 待实现 | `chandler/cli/commands.ss` |
| 4 | app uninstall 时也删除 bin/ 启动器 + symlink | 🔲 待实现 | `chandler/cli/commands.ss` |
