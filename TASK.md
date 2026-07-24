# Chandler 实现任务清单

> 本仓库正在**吸收 bake**(阶段 B 进行中),吸收后 chandler 成为包管理器 + 构建器。阶段 B 完成前,编译动作仍由 bake 子进程执行(以 mock bake 测试,见阶段 10)。
>
> **资源定位 + per-dep 库路径 + .env** 的后续架构见 [design 14](designs/14-unified-resources.md)(统一 `resource-path`、dev 期无 `lib/`、`.env` 项目配置),替代原 P6 阶段 C 的 assembled + CHANDLER_DEV_ROOT 方案。
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

- 测试:`tests/run-tests.sps` **259 用例全绿**(21 个 suite:util/fs/sexp/layout/version/manifest/lock/proc/fetch/resolve/install/activate/cli/registry/build/pack/base/runtime-paths/**task-engine**/**miniregex**/**recipe**)。**`scheme`、`petite`、已部署的 `skiff` 三运行时均全绿**。
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

### P1c — chandler 改为运行时门(不是依赖)— **已完成(2026-07-23)**

`(deps (chandler …))` 取消。chandler 与 `(chez …)`/`(skiff …)` 同类:**只声明版本区间,不声明来源**——它没有可 fetch 的 URL,实体恒是全局前缀 `~/.local/share/chez`(`CHANDLER_PREFIX` 可覆盖)里装好的那一份。

```scheme
(manifest (format 1) (name "myapp") (version "0.1.0")
  (chez ">=10.0") (chandler ">=0.1.4") (srcdir ".")
  (deps …))                     ; ← chandler 不在这里
```

| # | 改动 | 文件 |
|---|------|------|
| 1 | manifest 新字段 `(chandler "<range>")` + 区间校验;同时写 `(deps (chandler …))` 直接拒 | `chandler/manifest.ss` |
| 2 | `chandler deps`:读 `<prefix>/.chandler/chandler/manifest.ss` 拿装的版本 → 区间校验(expected vs actual)→ 把 **runtime 子集**铺进 `vendor/chandler/` 与 `lib/{src,<mt>}`(源码 + 前缀里已编译的对象,不重编) | `chandler/install.ss` |
| 3 | `chandler pack`:从**同一前缀**取同一子集进 `<pack>/<mt>/chandler/` —— 包必须自包含,不能指望目标机装了 chandler | `chandler/pack.ss` |
| 4 | `bootstrap.ss` 装 chandler 时写 `<prefix>/.chandler/chandler/manifest.ss`(前缀自描述,版本门据此判定);卸载时删 | `bootstrap.ss` |
| 5 | `chandler init` 模板写运行时门;N5 检查改判 `(chandler …)` 字段(warning / `--strict` 拒) | `chandler/cli/commands.ss` |
| 6 | `global-prefix` 支持 `CHANDLER_PREFIX` 覆盖(非默认前缀 + 测试可控) | `chandler/install.ss` |
| 7 | 版本常量 `chandler-version` 收敛到 `(chandler util)`(原先 umbrella / CLI / resolve 各写一份 "0.1.4") | `chandler/util.ss` 等 |

**修掉一个潜伏 bug**:pack 的 N6 过滤器 `chandler-dev-only-so?` 把 `strip-prefix` 参数写反(`(strip-prefix s pre)`),导致 `chandler/` 下**每个**库都被判成 dev-only —— 即「作为依赖的 chandler 一个库都进不了包」。此前没炸,是因为应用自己的 `_build/` 里也编了一份、经 `copy-obj-tree!` 进了包。现在判据挪到 `(chandler install)` 由 deps/pack 共用,并顺手修正。

**验证**:三运行时 **224/224 全绿**(新增 4 个用例:runtime 子集铺设 + dev-only 不铺、版本过旧报错、前缀无 chandler 报错、vendor/chandler 不被孤儿清理误删)。skiff-demo 全链路实跑:`deps`(铺 10 个 runtime 库到 `lib/{src,ta6le}`,无 cli/pack/build)→ `bake`(`(prebuilt "lib")` 直接消费,`_build/` 里不再重编 chandler)→ `chandler build` → `run` 起服务 200 → `pack`(`<pack>/ta6le/chandler/` 10 个 `.so`)→ `env -i` clean-env 起服务 `/` 与 `/features` 均 200 → `verify-pack --target` **131 ok / 0 bad**。

### P4 — 单一前缀:`lib/` 与 `_build/` 合一 — **已被 design 14 替代**

> ** superseded by [design 14](designs/14-unified-resources.md)**。doc 14 的 per-dep `(src . obj)` 对方案更彻底地解决了同一个问题:dev 期**根本不需要 `lib/`**(源码/对象/资源各自 live),`assembled` 命令被消除。原分析 [docs/single-build-prefix.md](docs/single-build-prefix.md) 保留作决策记录。

### P5 — bake 与 chandler 是否合并 — **方向已决(2026-07-23),落地中**

分析见 [docs/bake-chandler-merge.md](docs/bake-chandler-merge.md)。要点:两个工具**零代码共享**(bake 不 import 任何 `(chandler …)`),却共享 5 条不变量(前缀形状 / native 落点 / loader 候选序 / `APP_ROOT` 语义 / mt→so-ext),且各自重复实现了 sha256+util+运行时探测约 900 行 —— 今天一小时内就撞了两次漂移(bake 删 `install-task` 使 chandler 的 recipe 整份加载失败;P1 改包布局使 loader 候选 1 恒 miss)。

结论:**合并概念(清单里写构建)否决** —— 撞 [08 §3](designs/08-bootstrap-security.md) 的「清单只读不求值」红线;**共享底座(M2)已完成**(P1c 运行时门 + 阶段 13 `(chandler base)` umbrella);**单仓单二进制(M1)升格为全吸收** —— bake 编译引擎整体搬进 chandler dev-time 层。落地任务见下方 **P6 阶段 A–D**;资源定位 + per-dep pairs + `.env` 的后续重构见 **[design 14](designs/14-unified-resources.md)**(替代原 P6 阶段 C 的 assembled + CHANDLER_DEV_ROOT 方案)。

### P6 — bake 全吸收进 chandler(单仓单二进制)— **进行中**

设计权威:[docs/bake-chandler-merge.md](docs/bake-chandler-merge.md) §5–§9。bake 仓 `/home/david/workspace/bake`(18 模块 + launcher + bootstrap = 3318 行)整体并入 chandler;chandler 从包管理器变成**包管理器 + 构建器**。三条要求:① 三层边界(runtime/dev-time/assembled);② 继承 bake 全部能力;③ 新增 `assembled` 命令。

**三层架构**(§6):

```
③ assembled(用户命令)— 唯一把 _build/ 组装进 lib/<mt>/;不装源码
② dev-time 工具层 — 包管理(install/fetch/resolve/lock/manifest/registry/activate/pack)
                   + 编译引擎(吸收自 bake:compile/native-build/import-graph/task-engine/recipe/miniregex)
① runtime 公共基础设施 (chandler base) — 9 子库,零编译逻辑
```

**实施决策(执行前澄清)**:

- bake 是 **load-based**(被 `bake.ss` 顺序 load 到共享 interaction-environment),非 `(library …)` 形式。阶段 A 的「改 import `(chandler base)`」= 在 `bake.ss` 顶部加 `(import (chandler base))`(同 `(import (chezscheme))` 一行),bake 模块即可见 base 导出;非「逐模块改 import」。阶段 B 把源码搬进 chandler 时自然变成 library。
- bake 仓**没有 manifest.ss**(零依赖自含)。阶段 A2 需先建 manifest(`(chandler ">=0.1.4")` 运行时门 + `(chez ">=10.0")`),`bootstrap.ss` 改为依赖已装的 chandler。

#### 阶段 A — 共享底座(M2,可独立交付)

消灭 §0 诊断的 ~900 行重复面 + 5 条不变量漂移。前置条件已就绪(P1c 运行时门 + 阶段 13 base umbrella)。

| # | 任务 | 状态 | 文件 |
|---|------|------|------|
| A1 | 不变量常量收敛进 `(chandler layout)` | ✅ 已完成(核对) | layout 已含 so-ext/native-*/split-pair 全部不变量(阶段 13 + P1 已收敛),无需补充 |
| A2 | bake 改用 `(chandler base)`,删重复实现 | ✅ 已完成 | 见下方「A2 实现期决定」 |

**A2 实现期决定(2026-07-23)**:

1. **chandler 侧扩充(面向阶段 B)**——util 加 `format-object`/`eprintf`/`datum->string`/`string-subst`/`strip-leading`(= strip-prefix 别名);fs 加 `write-text-if-changed`/`file-byte-size`/`mtime`/`path-root`/`path-ext`/`path-swap-ext` + 别名 `file->string`/`file->lines`/`delete-tree`/`path-basename`;layout 加 `machine-type-string`/`windows-mt?`/`join-path`/`rel-to`。base export 同步。
2. **bake 侧保守删改(零风险)**——`bake/sha256.ss` 整删(129 行,API 与 chandler hash 完全一致);`bake/native.ss` 删 `so-ext`(由 base 提供);`bake/util.ss`+`runtime.ss` 把纯字符串/格式化/路径函数改为 alias(str-prefix?→string-prefix? 等);`bake.ss` 加 `(import (chandler base))` + libdirs 自动挂全局前缀对。
3. **子进程封装保留 bake**(签名不兼容,阶段 B 统一)——bake `run`/`run/capture`/`run/code` 接受 `(run "prog" "arg" ...)` 可变参数,chandler `run-capture`/`run-check` 接受 `(run-capture prog args-list)` 列表签名;bake `shq`(加双引号)与 chandler `shell-quote`(单引号转义)语义不同;bake `bail-*` 依赖 `*exit-code*` 全局状态。这些**不 alias**,留 bake(阶段 B 搬进 task-engine 时统一)。
4. **bake manifest 暂未建**——bake 仓当前零依赖自含,manifest 化牵连 bootstrap/启动器/测试全套,留阶段 B7(删 bake 仓)时随合并自然解决;A2 仅让 bake 在已装 chandler 的环境下 import base。
5. **bake bootstrap.ss 不动**(计划要求保持自含)。

**验证**:chandler **225/225** 全绿(新增 path-root/path-ext/string-subst 等用例);bake **12 suite 全绿**(loader-run **35/35** 含 Z4/Z5 → native-loader codegen 文本字节不变);bake 净删 174 行重复实现。

#### 阶段 B — 吸收编译引擎(M1+,核心工作,~2000 行搬运)

把 bake 的编译引擎搬进 chandler dev-time 层,变 6 个新 library 模块。依赖序 B1→B7。

| # | 任务 | 状态 | 文件 |
|---|------|------|------|
| B1 | `records`(36)+ `globals`(34)+ `output`(40)+ `engine`(156) → `(chandler task-engine)`;import 改 `(chandler base)` | ✅ 已完成 | `chandler/task-engine.ss`(新) |
| B2 | `dsl`(147)+ `loader`(68) → `(chandler recipe)`(DSL 宏 + 注册器 + recipe 加载 + 目标选择);`miniregex`(70)提前搬入 | ✅ 已完成 | `chandler/recipe.ss`、`chandler/miniregex.ss`(新) |
| B3 | `deps`(312) → `(chandler import-graph)`(R6RS import 解析 + 库闭包 + 环检测) | ✅ 已完成 | `chandler/import-graph.ss`(新) |
| B4 | `compile`(612) → `(chandler compile)`(library-task/program-task/boot-task/指纹/并行 `-j`/prebuilt/clean);**B2 遗留验收**:`load-recipe` 本仓 `recipe.ss` + `(invoke-task 'build)` 跑通自编译 | ✅ 已完成 | `chandler/compile.ss`(新) |
| B5 | `native`(427) → `(chandler native-build)`;注册 `current-native-prescan`;native(script/make/cmake)端到端(miniregex 已于 B2 完成) | ✅ 已完成 | `chandler/native-build.ss`(新) |
| B6a | **`chandler build` 改进程内编译**(不再 spawn bake);`chandler deps/build/run` 在无 bake 的环境全通 | ✅ 已完成 | `chandler/build.ss`、`chandler/cli/commands.ss` |
| B6b | **`recipe.ss` 变可选**:没有它就从 manifest 推导构建((name)/(srcdir)/(native …)) | ✅ 已完成 | `chandler/build.ss` |
| B6c | bake CLI 表面合入:`chandler bake [-f/-T/-A/-P/-j/-n/-c/-q/-t]`(自带 argv 语法);`bake init` **不搬** | ✅ 已完成 | `chandler/cli/bake.ss`(新)、`chandler/cli/main.ss` |
| B7 | 删除 bake 仓;统一一套 bootstrap + 启动器;skiff-demo 端到端 | 🔲 待实现 | 删 `/home/david/workspace/bake`;`bootstrap.ss` |

**执行约定(2026-07-24)**:阶段 B **只从 bake 仓读取搬运,不改 bake 仓** —— 能力吸收完即 B7 删仓,给作废物打补丁是纯浪费。故 A2 记的「bake 侧保守删改」到此为止,不再有 bake 侧改动。

**B1 实现期决定**:见 `chandler/task-engine.ss` 头注 —— load-based bake 靠运行时符号解析,library 词法封闭,故 ① 被 `set!` 的全局(`*dry-run*`/`default-task-name`/…)改 `make-parameter`(R6RS library 不能 export 被赋值的变量),约定「读 `(*x*)` / 写 `(*x* v)`」;② 对 B4/B5 的 forward reference 改钩子参数(`current-regexp-matcher`/`current-fingerprint-judge`/`current-compile-needed`)。

**B2 实现期决定(2026-07-24)**:

1. **miniregex 从 B5 提前到 B2** —— `register-rule!` 要把字符串 pattern 编成 miniregex、engine 的 `resolve` 要拿它匹配 rule,都是 B2 的必要前置;而该模块自含 70 行、零下游依赖,提前无代价。`(chandler miniregex)` 库体末尾把 `regexp-match?` 注册进 B1 的 `current-regexp-matcher` 钩子(**实例化即注册**,不需调用方记得初始化)。B5 因此只剩 native。
2. **recipe 求值环境**:bake 把 recipe.ss eval 进 `(interaction-environment)`,能看见全部顶层绑定;library 词法封闭,故改为按 `recipe-environment-libs`(parameter,默认 `(chezscheme)`/`base`/`task-engine`/`recipe`)**每次加载现组一个可变环境**(`copy-environment` —— recipe 顶层的 `(define …)` 需要可变环境;每次新组则上一份 recipe 的定义不会渗进下一份,已有回归用例)。B4/B5 吸收后往这个 parameter 追加 `(chandler compile)`/`(chandler native-build)` 即可,无需回头改 recipe。
3. **native loader 预扫**(bake/native.ss 的 `prescan-native-loaders!`)是 forward reference,改 `current-native-prescan` 钩子,未注册时 no-op;调用点仍是「整份读完 → 预扫 → 逐 form 求值」,顺序不变(生成的 `(<lib> native-loader)` 源码必须早于 `library-task` 求值落盘)。
4. **recipe 面子进程封装留在 `(chandler recipe)`**:`run`/`run/code`/`run/capture`/`displayln` 是 recipe 表面 API,签名(可变参数)与 `(chandler proc)` 的 `run-capture`/`run-check`(列表参数)不兼容,按 A2 决定 3 不 alias;`path-ext`/`file->string`/`file->lines` 同理补齐(`path-root` 是 Chez 内建,`path-swap-ext`/`mtime` 由 base 提供)。
5. **`select-targets`/`normalize-target` 从 dispatch.ss 提前搬入**(argv 恒是字符串而 phony 登记在符号键下,二者是 `invoke-task` 的正确性前提,与 CLI 接线无关);dispatch 的其余部分(选项→全局、`-j`、manifest 读写)留 B6。
6. **用户可见前缀 `bake: error:` → `chandler: error:`**(吸收后用户见到的工具名只有 chandler);内部哨兵符号仍是 `'bake-error`,它不面向用户,改名要连累 B4/B5 全部搬运。
7. **B2 验收缩到 DSL + loader**(真 recipe 文件端到端:task/file/rule/default-task 注册 → 物化 → 执行 → 产物落盘);原文写的「跑通 chandler 自身编译」依赖 `library-task`,已挪到 B4。

**验证**:`scheme`/`petite`/`skiff` 三运行时 **259/259 全绿**(新增 miniregex 7 + recipe 17 用例;recipe 全部在临时目录里造**真** recipe 文件跑 `load-recipe`,不 mock)。

**B3 实现期决定(2026-07-24)**:

1. **公开名一律照搬**(`dep-read-all`/`dep-find-clause`/… 的 `dep-` 前缀原是为共享 interaction-environment 防撞,library 词法封闭后理由消失)—— 但不改名:B4 搬 compile 时逐处引用,改名只平添 diff 与出错面。
2. **三处并进 base**:`dep-join` → `string-join`(实现完全一致)、`dep-warn` → `eprintf`、`dep-parent-or-dot` → `parent-dir`(空串换 `"."`)。
3. **`runtime-provided` 快照排除整片 `(chandler …)`** —— 与 bake 的唯一行为差异,且是合并**引入**的新风险:chandler 是单二进制,构建器自己的库此刻就加载在本进程里,会混进 `(library-list)`;若判成 builtin,一个忘了跑 `chandler deps` 的项目会**静默**不编、不交付 `(chandler base)`,直到部署才炸。排除后:铺好了源码/对象自然解析得到,没铺就报 `cannot locate library (chandler base)` —— 可操作的错。实测 skiff 上 `(skiff web)` 仍判 builtin、`(chandler base)` 不再误判。
4. bake 的 `bake/import-graph.ss`(71 行 CLI 壳)**不搬** —— 它只是 `deps-run.sh` 的驱动,等价能力已由 Scheme 测试直接调库覆盖;需要时 B6 再加 `chandler bake -P` 一类子命令。

**验证**:三运行时 **277/277 全绿**(新增 import-graph 18 用例,覆盖 bake `deps-run.sh` 的 I1–I4/I9/I10 全部断言 + 预构建根归类 + 项目库胜过同名预构建 + `(chandler …)` 不算 builtin)。

**B4 实现期决定(2026-07-24)**:

1. **「与 bake 字节一致」这条验收作废** —— 实测 **Chez 的 fasl 输出本就不可复现**:同一目录、同一份源码,`bake` 连编两次产物字节就不同(`chandler/util.so` 20017 vs 20019 字节,第 528 字节起分歧)。原文写这条时并不知道这一点。**改用功能等价验收**:自编译产出的 `_build/<mt>/` 单独作为**唯一**库搜索根(源码不在路径里)能 `(import (chandler))` 成功,且整套测试跑在这批对象上全绿。已实跑通过。
2. **显式装配 `install-compile-hooks!`** —— Chez **惰性实例化**库:库体的副作用直到有绑定被真正引用才跑。而 recipe 里的 `(define-lib-roots …)` 要求「加载 recipe 之**前**」求值环境里就有它,那时还没人引用过 compile 的任何绑定。实测只留库体副作用会报 `variable define-lib-roots is not bound`。故导出显式装配过程,由入口(B6 CLI 的 build 通路、测试)调用;库体也调一次作为尽力而为。**对照**:`(chandler miniregex)` 的钩子注册不需要这一套 —— 它由 `register-rule!` 调 `regexp` 时被强制实例化,而没有 rule 时那个钩子根本用不上。
3. **修掉一个合并引入的真 bug:同进程二次构建**。bake 是「一次调用 = 一个进程」,全局构建状态(`compile-nodes`/`fp-cache`/WPO 开关/`*gen-roots*`/`lib-roots`/`classify-cache`)靠进程退出复位;chandler 是单二进制且 compile 是**库**,同进程连着建两次是自然用法 —— 那时第二次会命中第一次的指纹缓存,**内容真改了也判成「无需重编」**。新增 `(chandler recipe)` 的 `recipe-reset-hooks`(按 key 去重的复位钩子,`load-recipe` 开头统一跑)+ compile 的 `reset-compile-state!` + import-graph 的 `reset-classify-cache!`。已有回归用例(同进程改源码再建,必须重编)。
4. **`libdirs-string` 顺带修掉 bake 的 Windows 分隔符 bug** —— bake 那份写死 `":"`/`"::"`,与 chandler 2026-07-22 修过的是同一类错。改走 `(chandler layout)` 的 `libdirs->arg`/`entry->arg`,分隔符随平台;worker 线格式(`root->arg`/`arg->root`)同此。
5. **`-j` worker 改为「生成自含脚本」** —— bake 的 worker 是 `scheme --script <bake 自己> --compile-one …` 自调用;chandler 的 CLI 是 `.sps` 程序,自调用要连带解决「worker 上哪找 `(chandler …)` 库」。而 worker 干的事只需要 `(chezscheme)`,故改为把 worker 源码生成到 `_build/<mt>/.compile-one.ss`(`write-text-if-changed`),`worker-cmd` 直接 `--script` 它。**副产品**:CLI 不必再留 `--compile-one` 暗门;worker 不依赖 chandler 装在哪。worker 用的可执行文件默认取**父进程所在运行时**(`current-runtime` + `CHANDLER_SKIFF`/`CHANDLER_SCHEME`),而非 bake 那样默认 `"scheme"` 再指望启动器导出 `BAKE_RUNTIME` —— 跨一次构建混用 Chez 版本会出 fasl 不匹配。
6. **改名**:`bake-build-dir`→`build-dir`;`manifest`→`fp-manifest`(chandler 的 "manifest" 是**包清单** `manifest.ss`/`manifest.lock`,同名两义会害人)、连带 `load-/write-/…-path`;`bake-runtime`→`worker-runtime`;`*generate-wpo*`/`*gen-roots*` → parameter。**磁盘文件名 `.bake-manifest` 保持不变** —— 过渡期 bake 子进程仍可能写它,改名只会让双方各自重编一遍(B7 删仓后再改)。
7. **§18f bake 自举整段不搬**(`cmd-bootstrap`/`build-bake-all!`,~50 行)—— 那是「把 bake 自己的 17 个模块编成 `bake-all.so`」,chandler 的安装由自含的 `bootstrap.ss` 负责,无对应物。
8. **新增 `compiler-available?`** —— Petite 把 `compile-library` 绑着但一调就抛 `compile package is not loaded`,错在很深处、话也难懂。探测一次(真编一个最小库到临时文件)后记住,`compile-lib` 入口给出可操作的话:「this runtime has no compiler (Petite does not ship one) — build with `scheme` or `skiff`」。测试里真编译的用例据此在 Petite 上**跳过**而非放宽断言。

**验证**:三运行时 **297/297 全绿**(新增 compile 20 用例;真在临时目录编真库,含 `-j` 真起子进程)。自编译端到端:`load-recipe` 本仓 `recipe.ss` → `invoke-task 'build` → 17 个 `.so`,把 `_build/ta6le` 单独作唯一库根 `(import (chandler))` 成功、整套测试跑在这批对象上 277/277。

**B6a/B6b 实现期决定(2026-07-24)**:

1. **`chandler build` 不再 spawn bake**。旧路径是「在依赖树里生成 `.chandler-build.ss` → `run-check bake -f … build-all` → 删文件」;新路径直接调 `library-task` / `native-task*` 排单、`invoke` 就地编译。少一次子进程往返、少一个写进依赖树的临时文件,错误也不必从子进程 stderr 里捞。**`CHANDLER_BAKE` 与 `tests/mock-bake.sh` 随之作废**(mock 已从测试里移除,文件留待 B7 一并清理)。
2. **授权判定必须在排单之前**(原本就是,但吸收后更要紧):依赖的 native 构建不再隔在子进程里,而是在**本进程** exec。新增回归用例「被拒时一个对象都不该编出来」。
3. **`recipe.ss` 变可选(B6b)** —— 它是**程序**(加载即求值),只对根项目有意义(依赖的 recipe.ss 永不执行,[08 §3](designs/08-bootstrap-security.md))。而大多数项目的 build 段完全可以从清单推出来:`(name)` 给库名与 umbrella、`(srcdir)` 给搜索根、`(native …)` 给 native 任务(**你自己**清单里的 native 是可信的,不需 `--allow-build`)。故:有 `recipe.ss` → 跑它的 `default-task`(且**只跑它**,`test` 之类不被 build 带跑);没有 → 从 manifest 推导。**清单与 recipe 因此不必合并成一个文件**:数据仍只 `read` 不求值,程序仍是可选的单独文件,而「一个文件说清一个项目」在常见场合已经成立。
4. **修掉一处假错**:`build` 原先无条件要求 `lib/src` 存在,而零依赖项目的 `chandler deps` 本就什么都不装 —— 报「lib/src missing; run `chandler deps` first」是假的(deps 明明跑过)。改为只在 lock 里**有依赖**时才检查。自举项目(chandler 自己)正是零依赖,B6 之前 build 不编根项目才没暴露。
5. **测试夹具 `make-native-lib` 补成真能跑的后端**:原先声明 `(build make)` 且没有 `native/` 目录 —— 那时构建被 mock bake 挡着从不真跑。改为 `script` 后端且脚本只按落点契约产出文件(`: > $NATIVE_OUT/…`),**不需要 C 编译器**:这些用例验的是授权、落点不变量与产物搬运,不是 cc。
6. **两个测试改掉「断言全局默认值」的反模式**(`task-engine` 的 `parameter-defaults` / `hooks-default`):`default-task-name`、`rule-order-counter`、各钩子都属于**构建会话**状态,别的 suite 跑完会留下值 —— 断言默认值等于断言测试顺序。改为断言**语义**(可 parameterize、退出即还原、值是过程)。

**验证**:三运行时 **317/317 全绿**。端到端(**PATH 里没有 bake**):
- 造依赖仓(umbrella + umbrella 从不 import 的子库 + `script` 后端的真 native)→ `chandler deps` → `chandler build --allow-build` → `chandler run`,打印 `(answer 7)`;产物 `lib/<mt>/{b.so, b/opt.so, b/native/libb.so}` 齐全,根项目**无 recipe.ss**、从 manifest 推导出 `_build/<mt>/myapp.so`。
- **chandler 编译自己**:仓库副本 + 无 bake 的 PATH → `chandler build` 出 17 个 `.so`,再用这批产物作对象根跑全套测试 **317/317**。

**顺带发现(非本阶段引入,未修)**:branch 依赖在**没有 lock** 时仍可能命中陈旧的 git 镜像缓存 —— 上游 `main` 已经有新提交,`chandler deps` 却物化出旧内容,清掉 `~/.cache/chandler` 后才对。`resolve-branch` 的「尽量走缓存零网络」对 tag/rev 成立,对 branch 不成立(分支会移动)。

**B6c 实现期决定(2026-07-24)**:

1. **`chandler bake` 自带一套 argv 语法**,在 `parse-args` **之前**由 `main` 原样转交 —— bake 的短旗标带值(`-f path` / `-j N`),而 chandler 的解析器把未知短旗标一律当布尔,`-j 4` 会被拆成「布尔 `-j`」+「位置参数 `4`」。子 CLI 自己解析自己的语法,有回归用例钉住。
2. **选项不再是一堆全局 `set!`**(bake 那份是 20 个 `*opts-*` 全局变量),改成解析成 alist 传递;运行期状态仍走 task-engine 的 parameter。
3. **去掉三项**(都已无对应物):`--bootstrap`(bake 把自己 17 个模块编成 `bake-all.so`,§18f 整段未搬)、`-B`(bake 自己就只打一句 "ignored in this version")、`--name/--lib/--force`(是 `bake init` 的选项)。
4. **`bake init`(113 行)不搬** —— 脚手架归 `chandler init`,且 `recipe.ss` 自 B6b 起是可选的,再来一套 init 只会制造 §2 说的那种「同一件事各说一遍」的重复。
5. **`-T` 恒列默认任务**(bake 那份只列有描述的)—— `library-task` 注册的 `'build` 没有描述,于是 bake 的 `-T` 偏偏漏掉最该看见的那一个。
6. `CHANDLER_BAKE` 从帮助里删除(B6a 起无人消费)。

**验证**:三运行时 **333/333 全绿**(新增 cli-bake 15 用例)。CLI 实跑(**PATH 无 bake**):`chandler bake --help/-T/-P/-n/-c` 正常;`chandler bake -j 4` 在仓库副本上跑出波前 level 0–7、17 个 `.so`,再跑一次零重编,`-c` 清掉 18 项。退出码:未知选项 64、缺 recipe 2、未知任务 1、正常 0。

**B5 实现期决定(2026-07-24)**:

1. **loader codegen 文本有两处**(功能不变,只是署名与话术):`;; generated by bake` → `by chandler`;定位失败的话 `run \`bake build\` first` → `chandler build`。原表格写的「codegen 文本不变」是为了对齐 bake 的 `loader-run.sh` Z4/Z5,但 bake 即将删仓、用户见到的工具名只有 chandler,留旧署名反而是错的。**结构与两条硬约束一字未动**(APP_ROOT 候选 / `library-directories` 对象侧兜底 / `_build/<mt>` dev 兜底 / 裸 soname guard;`native-loaded` 引用边)。代价:一次性重生成 + 重编 loader。
2. **`chez-include-dir` 从当前运行时反推**(bake 写死 `command -v scheme`)—— 跑在 skiff 上时,`scheme` 可能是 PATH 上另一个 Chez,拿它的 `scheme.h` 去编 Model B 的 C 代码,ABI 未必一致:**编得过、跑起来崩**。改为跟 `worker-runtime` 同一套(`current-runtime` + `CHANDLER_SKIFF`/`CHANDLER_SCHEME`);布局不匹配时报的是可操作的「设 `CHEZ_INCLUDE_DIR`」。
3. **删掉 native 自带的 `so-ext`**(与 `(chandler layout)` 的完全同义);`%abs` 不再 shell 出去跑 `pwd`,直接 `(current-directory)`。
4. **装配同 B4**:`install-native-hooks!` 显式调用(注册 `current-native-prescan` + recipe 环境 + 复位钩子)—— Chez 惰性实例化,而预扫必须早于任何 recipe form 求值。

**验证**:三运行时 **312/312 全绿**(新增 native-build 15 用例)。native 端到端实跑:`cc` 编 C → 落 `_build/<mt>/mylib/native/greet.so` → 预扫生成 `_build/.gen/mylib/native-loader.ss` → 编 loader 与 FFI 库 → **只给对象根**(`--libdirs _build/ta6le`,源码不在路径里)`env -i` 跑 `(answer)` 得 42(自加载);搬走 native 后报的是 loader 自己的话而非 Chez 的 unbound。落点不变量与未知后端各有回归用例。

#### 阶段 C — 统一资源定位 + per-dep 库路径 + .env(替代原 C1-C7)

> **设计权威:[design 14](designs/14-unified-resources.md)**。原 C1-C7(assembled 命令 + CHANDLER_DEV_ROOT)已被 doc 14 替代:per-dep pairs 消除 `assembled`(dev 期全 live,不需要组装);src-scan 消除 `CHANDLER_DEV_ROOT`(资源直接从源码读)。

| # | 任务 | doc 14 | 状态 | 文件 |
|---|------|--------|------|------|
| C0 | `resolved-libdirs` 改 per-dep pairs;`vendor/`→`_vendor/`;删掉所有往 `lib/` 的拷贝;pack / 全局 install 改从各依赖自己的树取 | P0 | ✅ 已完成 | `chandler/{install,build,pack}.ss`、`chandler/cli/commands.ss` |
| C1 | 统一 `resource-path`:扫 `(library-directories)` 的 **src/obj 两侧** + prefix-fallback;删旧四 API;**资源定位不再依赖 `APP_ROOT`** | P1 | ✅ 已完成 | `chandler/runtime-paths.ss`、`chandler/pack.ss` |
| C2 | `native-load-paths` 改扫所有挂载条目的 obj 侧(不再只扫 `lib/<mt>`) | P2 | ✅ 已完成 | `chandler/install.ss` |
| C3 | `.env` 读取模块(`chandler/env.ss`);`run`/`repl`/`env` 消费(**不碰 build/deps/install**,保住可复现) | P3 | ✅ 已完成 | `chandler/env.ss`(新)、`chandler/cli/{commands,args,main}.ss` |
| C4 | install 落点:resources → `src/resources/<namespace>/`(替代 `share/<namespace>/resources/`) | P5 | ✅ 已完成 | `chandler/layout.ss`、`chandler/install.ss`、`chandler/runtime-paths.ss`、`chandler/cli/commands.ss` |
| C5 | pack 输出 resources 在 `src/resources/<ns>/`(「pack 来源改 `_vendor/`」那半依赖未采纳的 C0,未做) | P6 | ✅ 已完成 | `chandler/pack.ss` |
| C6 | 文档 + skiff-demo 迁移 + `chandler init` 模板加 `.env` 骨架 | 🟡 skiff-demo 已迁移;本仓 README + init 模板待做 | 跨仓 `skiff-demo/*`;`README.md`、`chandler/cli/commands.ss` |

**C4/C5 实现期决定(2026-07-24)**:

> **前置说明**:`designs/14-unified-resources.md` **不存在**(git 全历史里也没有),C0–C6 的「设计权威」缺失。本次只按用户指定采纳 **C4/C5 中与 C0 无关的那一半** —— 资源落点 `share/<ns>/resources/` → `src/resources/<ns>/`。C5 原文的「pack 来源改 `_vendor/<dep>/_build/<mt>/`」依赖未采纳的 C0(`vendor/`→`_vendor/` + per-dep pairs),未做。

1. **落点收敛到一处定义**:`(chandler layout)` 新增 `prefix-resource-dir` / `src-resource-dir` / `resources-dirname`,install / pack / 全局 install / runtime-paths 四处全部改调它 —— 原先是四处各拼一遍 `"share" ns "resources"`。
2. **一个前缀自此只有两层**:`src/`(与 ABI 无关 —— 源码 + 资源)与 `<mt>/`(平台绑定 —— 编译对象 + native)。`merge-lib-to-global!` 因此从合并三棵树减为两棵。
3. **[designs/11 §3](designs/11-runtime-paths.md) 的结论已就地标注反转**,并说明为何该节否决的 `src/<lib>/resources/` 与新方案不是一回事:被否的是「资源散进每个库自己的源码目录、与库搜索树交织」,新方案是「`src/` 下一个保留目录 `resources/`,其内按 namespace 分,资源与库源码永不交错」;而该节第 1 条(不进 `<mt>/`,免得按 mt 重复且误示受 ABI 约束)**依然成立且被满足**。
4. **代价记录在案**:`resources` 这个名字在源码根被占用 —— 一个真名为 `(resources …)` 的库会与它撞。
5. **无源码包因此也带一个 `src/` 目录**,里面只有资源、没有 `.ss` —— 那正是三态同构的代价与收益:`APP_ROOT` 下只有一种拼法,loader 与资源 API 都不分支。

**验证**:三运行时 **333/333 全绿**。端到端(**PATH 无 bake**,用一份现装到临时前缀的 chandler + `CHANDLER_PREFIX`,确保读写两侧都是新代码):
- `chandler deps` → 资源落 `lib/src/resources/resdemo/hello.txt`;`chandler run` 打印 `APP_ROOT=<project>/lib` 并读出内容。
- `chandler build` → `chandler pack --runtime petite` → 包内 `src/resources/resdemo/hello.txt`;`env -i ./bin/resdemo` clean-env 启动读出内容;**整包 `cp` 到别处仍读得到**(`APP_ROOT` 跟着走);`verify-pack --target` **17 ok / 0 bad / 0 extra**。

**C1 实现期决定(2026-07-24)**:

1. **一个 API,app 不再特殊**:`(resource-path '(mylib sub) "schema.json")` / `find-resource-path`。app 本来就是一个库,写自己的库名即可 —— 于是 `app-name` 推断、`APP_NAME`、`.chandler/` 嗅探全部退出资源通路。四个旧 API(`app-`/`lib-` × 严格/可选)删除;`define-resource-path-resolver` 收敛成一种形式。
2. **解析序**:① 顺序扫 `(library-directories)` 每个条目的 **src 侧与 obj 侧**(`<side>/resources/<libpath>/<segs>`)—— 条目序即优先级,故项目前缀自然遮蔽全局装的同名库;② 兜底 `(library-object-filename libref)` 反推前缀,覆盖「库从不在搜索表上的前缀被加载」。
3. **为什么不再需要 `APP_ROOT`**:资源与库住在同一个前缀里,而进程要能 `import` 那个库,该前缀本来就必须在 `library-directories` 上 —— 那张表就是「我在对着哪些前缀跑」的权威答案;再要一个环境变量说同一件事是重复,还多一条会漂移的路径。
4. **`APP_ROOT` 仍然导出,但只服务 native-loader**:生成的 loader 可能在 library-invoke 期就跑,那时 `library-directories` 未必已设([designs/24](../bake/designs/24-native-loader-codegen.md) §约束 3)。两件事自此分开,`run`/`repl`/`activate`/pack 启动器照常交接。
5. **pack 的 bootstrap 改挂 `(src . <mt>)` 对**(原为 `(obj . obj)`):包是源码-less 的,`src/` 里只有资源没有 `.ss`,但资源定位要扫 src 侧。实测 Chez 在 src 侧找不到任何 `.ss`,解析照旧落到 obj 侧,行为不变。

**验证**:三运行时 **336/336 全绿**(runtime-paths 由 18 增至 20 用例:两侧扫描、条目序即优先级、落空继续找下一个、**APP_ROOT 指向别处照样命中**、libref 校验)。端到端:
- `env -i` 起进程、**只给 `--libdirs`、绝无 `APP_ROOT`**(应用打印 `APP_ROOT=<unset>`)→ 读出资源。
- `chandler pack` → clean-env `./bin/resdemo` 与整包搬走后均读出资源;`verify-pack --target` 17 ok / 0 bad / 0 extra。

**顺带修掉一个既有 bug(非本次引入,bake 时代就有)**:重编判据是**内容指纹**,而 Chez 在 `compile-library` 内部解析上游库用的是 **mtime**。源码 mtime 变新但内容不变时(切分支、把源码拷进已建好的树),指纹说「无需重编」,Chez 却在编译**下游**时于内存里重编了上游 —— 产出的下游 `.so` 记的编译实例与磁盘上那个上游 `.so` 对不上。

**症状只在部署态现形**:该批对象只能以 `src::obj` **对**加载;只挂对象侧(pack 启动器、`(prebuilt …)` 消费)就报 `different compilation instance`。`rm -rf _build` 干净重建即恢复 —— 所以它能一直藏着。

**修法**:指纹判「无需重编」但对象比源码旧时,**touch 对象**(内容已由指纹证明相同)而不是重编 —— 既保住「touch 不重编」(designs/07),又让 Chez 的视角与我们一致。Chez 没有 utime 绑定,故用「拷到临时名 + `rename`」做原子替换。落点在 `needed-compile?` 判 `#f` 的那一支:`invoke` 先处理前置再处理目标,故上游在这里被 touch,恰好早于下游的编译。

(另一条路是编译时把自己的根也按「只给对象」挂,让 Chez 根本看不见源码 —— 更彻底,但会把「图里漏了一条边」从静默回退变成硬错,影响面大得多,未采用。)

**回归用例有两处细节决定它有没有牙**(都踩过,写进注释了):① 两次构建必须在**独立进程**里 —— 同进程里上游库从第一次构建起就驻留着,Chez 不会再读源码,分歧根本不发生;② 收尾必须用**只给对象根**的子进程加载 —— 挂成对时 Chez 会从源码重编出一套自洽的实例,同样验不出来。实测:去掉修复后该用例失败(退出码 255),加回即过。

**C2 实现期决定(2026-07-24)**:

与 C1 同一条原则:**进程对着哪些前缀跑,`resolved-libdirs` 就是权威答案**,兜底不该只认其中一个。原先只扫项目自己的 `lib/<mt>`,全局前缀里手放的、无 loader 的第三方 native 一律漏掉。

- 扫描集 = 项目 obj 目录 ∪ 所有挂载条目的 obj 侧(去重)。项目 obj 目录**无条件**在内 —— `resolved-libdirs` 在非 project-mode(没有 lock)时只返回全局前缀,而一个刚 build 完、还没 deps 过的树照样可能有 `lib/<mt>/…/native/`。取并集,严格是旧行为的超集。(这条是被既有用例 `native-fallback-skips-self-loading` 逼出来的:它造的正是「有 lib/ 但没有 lock」的树。)
- `self-loading?` 的过滤不变:带生成 loader 的库照旧跳过(自加载是惰性的),不论它在哪个前缀里。chandler/bake 装的东西**都**带 loader,故新增的扫描实际命中极少、纯属兜底;代价是每次起进程多走几棵 obj 树。

**验证**:三运行时 **337/337**(新增 1 用例:全局前缀里无 loader 的 native 被拾起、带 loader 的仍跳过)。

**D3(`chandler init` 模板)—— 核对后确认无需改动**:`cmd-init` 从来只写 `manifest.ss` + `.gitignore` + 库骨架,**本就不生成 `recipe.ss`**;B6b 让 recipe 变可选之后,这正是想要的形态。`.gitignore` 里的 `.chandler-build.ss` / `.chandler-install.ss` 是已作废的生成物,**保留**(老项目已有这两行,删掉只会变噪声;新项目多两行无害),已在原处注明。

**C0 进度(2026-07-24,未完)**:

**已切换(dev 通路)**:
- `vendor/` → **`_vendor/`**;`resolved-libdirs` 改为**逐依赖一条 `(src . obj)` 对** —— 源在 `_vendor/<name>/<srcdir>`,对象在它自己的 `_build/<mt>/`(`chandler build` 本来就编在那里)。
- **删掉所有往 `lib/` 的拷贝**:`install-dep-sources!`、`install-resources`、`sync-app-prefix!`、build 的 `install-dep-objects!`。`lib/` 目录自此在 dev 期**不存在**。
- **依赖资源不再复制**:live 在 `_vendor/<dep>/<srcdir>/resources/<libpath>/`,由 C1 的 src 侧扫描直接读到。**约定**:依赖仓库把资源摆成 `resources/<libpath>/`(与前缀里 `src/resources/<libpath>/` 同形);manifest 的 `(resources …)` 声明退化为**交付期映射**。
- **项目自己的资源同理**:`<root>/resources/<name>/` 就地被读到(项目源码根本来就挂着)。
- **dev 期不设 `APP_ROOT`**:它只服务 native-loader 候选 1,而 dev 期 native 分散在各 `_vendor/.../_build/<mt>/`,没有单一前缀能覆盖 —— 硬造一个只会让候选 1 恒 miss。候选 2(扫 `library-directories` obj 侧)恰好命中。外层已显式设了则原样透传;pack 仍设(那里是真前缀)。
- `chandler build` 编依赖时,上游按**各自的**预构建根 `(prebuilt <src> <obj>)` 消费(compile 会把它变成「只给对象」,正是避免「不同编译实例」的做法)。

**交付通路(pack / 全局 install)——「pack 无源码、install 是完整前缀」**:

一个依赖在 `_vendor/<dep>/<srcdir>/` 下有三样东西,两条通路各取所需:

| | 取什么 | 落到哪 |
|---|---|---|
| `chandler pack` | `_build/<mt>/**` + `resources/**` | `<pack>/<mt>/` + `<pack>/src/resources/` |
| `chandler install`(全局) | 源码树(除 `_build/`、`.git/`)+ `_build/<mt>/**` | `<prefix>/src/` + `<prefix>/<mt>/` |

**资源不必单独搬** —— 它在源码树里就住在 `resources/<ns>/`,而前缀要的正是 `src/resources/<ns>/`,拷源码树时**自动就位**。这是 C4 选这个落点的收益之一,当时没想到会在这里兑现。

`preflight` 顺带变得更可操作:逐依赖查它自己的 `_build/<mt>/`,报错能指名道姓「是哪个依赖没编」,而不是笼统一句「`lib/<mt>` 不在」。

**验证**:三运行时 **337/337 全绿**。pack 的测试夹具(`fake-dep-objs!`)也改成往 `_vendor/<dep>/_build/<mt>/` 写 —— 先前它伪造 `lib/`,一度让 pack 测试在真实 pack 已经坏掉时仍然是绿的。

**端到端已实跑(2026-07-24,PATH 无 bake,用现装到临时前缀的新 chandler)**:
- `deps → build --allow-build → run`:依赖仓带子库 + native(cc)+ 资源,`(chandler runtime-paths)` 的 `resource-path` 同时读出**依赖资源**与**应用自身资源**,全程无 `lib/`、无 `APP_ROOT` —— `(b 7 opt 8 b-res "…" my-res "…")`。
- `pack --runtime petite`:包内 `src/resources/{b,myapp}/`、`ta6le/` 对象 + native、`ta6le/chandler/` 10 个 runtime `.so`;`env -i ./bin/myapp` clean-env 启动与整包 `cp` 到别处均打印正确结果;`verify-pack --target` **21 ok / 0 bad / 0 extra**。
- 全局 `install --global`:`_vendor` 各依赖树 merge 进前缀,`src/{b.ss,myapp.ss}` + `src/resources/b/data.txt` + `ta6le/{b.so,myapp.so,b/opt.so,b/native/libb.so}` 三层俱全。

**e2e 期修掉的三处**:
1. **`chandler build` 要求 lock 才肯跑** —— 零依赖项目(chandler 自身)从不 `deps`、没有 lock,先前只靠上一轮残留的 lock 蒙混。改为「无 lock = 无依赖要编」,跳过依赖编译直接编项目自身。
2. **`build-project` / `build-one-dep` 仍挂旧的 `lib/` 预构建根**,且缺全局兜底 —— 于是 import `(chandler runtime-paths)`(运行时门,不在 lock)的项目编不过。改为逐依赖 `(prebuilt src obj)` + 末尾全局前缀兜底,与 run 期 `resolved-libdirs` 同一搜索路径。
3. **应用资源 pack 时双层嵌套** `src/resources/myapp/myapp/` —— pack 的 `copy-resources!` 多套了一层 `<app>`,与 dev 期 `resource-path` 扫 `<root>/resources/<libpath>/` 的约定对不上。统一为 **verbatim**:`<root>/resources/**` → `src/resources/**`(`<libpath>/` 已在 `resources/` 里,与依赖资源同一约定)。

**两处既有不一致(非 C0 引入,未修,记录在案)**:
- `install --global` 的落点走 `default-user-libdir`(读 `HOME`),而 chandler 运行时门走 `global-prefix`(读 `CHANDLER_PREFIX`)—— 两个「全局前缀」概念不统一,`CHANDLER_PREFIX` 对 `install --global` 无效(验证时误装进真实 `~/.local/share/chez`,已清)。
- `uninstall --global` 只按注册表删**项目自己**的文件,merge 进去的依赖(`b`)留下 —— 全局 install 记账不含 merged deps。

**文件约定改名(2026-07-24)**:项目构建描述文件 `recipe.ss`(bake 的烘焙术语)→ **`chandler-tasks.ss`**,与数据文件 `manifest.ss` 配对。默认名收敛成 `(chandler recipe)` 导出的常量 `default-tasks-file`(先前硬编码 3 处);`chandler bake` 的 `--recipe` 长旗标 → `--file`(旧名保留作向后兼容别名),`-f` 不变;错误/帮助措辞 `recipe file` → `tasks file`。仓库根自己的 `recipe.ss` 一并改名 + 头注重写。库名 `(chandler recipe)` 与函数 `load-recipe` 保留作内部概念名(改动纯内部,无用户可见收益)。skiff-demo 无此文件(已删 recipe.ss),不受影响。三运行时 360/360;`chandler bake -T/build` 实测读新名正常,旧名报 `tasks file not found`。

**C3 实现期决定(2026-07-24,规格由用户逐条拍板 —— design 14 不存在)**:

1. **优先级:`.env` 覆盖进程环境**。传给子进程的 env alist 里 `.env` 条目排在**最后**(`env-prefix` 是 shell 变量前缀,同名后者胜),chandler 自己交接的 `APP_ROOT` 等在前。实测 `SHELL_OVERRIDE=from-shell chandler run` → 应用读到 `from-dotenv`。
2. **作用面:`run`/`repl`/`env`(exec 由 run 承担,chandler 无独立 exec 命令)。刻意不碰 `build`/`deps`/`install`** —— 那三者受环境变量影响会让同一份源码在不同 `.env` 下产出不同结果,损害可复现性。
3. **来源:项目根 `<root>/.env` + 显式 `--env-file <path>`(同键覆盖 base)。依赖树里的 `.env` 一概不读** —— 依赖是不可信第三方,加载它的 `.env` 等于让依赖偷偷注入 `PATH`/`LD_PRELOAD`,与 [designs/08](designs/08-bootstrap-security.md) 信任模型一致。
4. **语法:`KEY=value` + `#` 注释 + 空行 + 可选 `export ` 前缀;单引号(字面)/ 双引号(`\n \t \r \\` 转义)/ 裸值(去尾部空白);`${VAR}` 展开**(先查本文件更早条目、再查进程环境、都无→空串;单引号内不展开;只认 `${…}`,裸 `$VAR` 原样保留)。malformed 行(无 `=` / 空键 / 非法键名)带**行号**报错。
5. `read-dotenv` 返回**有序 alist**、**不直接 putenv** —— 调用方决定注入子进程还是导出,同进程内也就不污染 chandler 自己的环境。

**验证**:三运行时 **359/359**(新增 env 23 用例)。e2e(PATH 无 bake):`chandler run` 注入 `.env` 且 `${USER}` 展开、`.env` 覆盖 shell 预设值;`chandler env` 导出(`${USER}` 已展开、shell-quoted);`--env-file prod.env` 覆盖 base `.env`。

**skiff-demo 迁移(C6 一半,2026-07-24,跨仓 `/home/david/workspace/skiff-demo`)**:

把示例应用从旧模型(汇总 `lib/` + `chandler-setup.ss` + `APP_ROOT`/`app-resource-path`)迁到 C0/C1/C4 新模型:
- `mdserver/app.sls`:`app-resource-path` → `resource-path '(mdserver)`;资源 `resources/*.md` → **`resources/mdserver/`**(verbatim 约定,app 库 `(mdserver)` 的资源摆在 `resources/<libpath>/`)。
- `serve.ss`:删掉自己操作 `(library-directories)` 的旧代码 —— `chandler run` 全权交接库搜索路径,脚本只 `(import (mdserver))` + `(main …)`。
- **删 `recipe.ss`**:`chandler build` 从 `manifest.ss` 的 `(app (entry (mdserver)))` 推导要编什么,不再需要手写。
- `.gitignore`:`/vendor/` → `/_vendor/`,去掉 `/lib/`。
- README 重写:构建/运行/打包/文件四节全部对齐新模型 + 一段迁移说明。

**迁移期揪出 build-project 一个 bug(已修,chandler 侧)**:`build-project` 用 **manifest name** 找 umbrella `<name>.ss` —— 而 app 的入口库常与清单不同名(skiff-demo 清单叫 `"skiff-demo"`,入口却是 `(mdserver)`),于是一个库都没编、`build-project` 静默空跑。改为:清单有 `(app (entry E))` 时按**入口** `(library-task 'build E)`(编入口闭包,依赖走预构建根不下降,正是旧 recipe 的语义);无 app 的纯 lib 才按 name 找 umbrella。新增回归用例(360)。

**skiff-demo 端到端全通**(PATH 无 bake,skiff 运行时,依赖 chez-markding 经网络 fetch):
- `deps`(整仓 → `_vendor/`)→ `build --allow-build`(chez-markding 107 `.so` + mdserver 3 `.so`)→ `run --script serve.ss`:`docs: …/resources/mdserver`(`resource-path` 扫库路径命中,**无 APP_ROOT**),`/` `/hello` `/features` 均 200、渲染出中文 markdown。
- `pack`:`src/resources/mdserver/` 三个 `.md`、`ta6le/chez-markding/` 107 `.so`、`ta6le/chandler/` 10 `.so`;`verify-pack --target` **131 ok / 0 bad / 0 extra**;`env -i ./bin/skiff-demo`(clean-env)起服务 200、整包 `cp` 到别处 docs 落点随之相对、仍 200。

**C6 剩本仓**:README 的架构章 + `chandler init` 模板注入 `.env` 骨架 + 设计文档(11/13)标注 `resource-path`/`_vendor` 定稿。

**测试夹具泄漏(已修,2026-07-24)**:`mktmp` 约 250 次/轮、多数调用方从不清理 —— 一会话攒 **12160 个目录、7.7G** 撑满 tmpfs,`mktemp` 随即返回空串、测试大面积假失败(`cannot set current directory to ""`),更糟的是**空串让夹具把文件写进 cwd(仓库根),还覆盖了 `recipe.ss`**。修法:harness 持一张临时目录表(`register-test-tmp!`),`run-suites` 在**每条用例后**统一 `rm-rf`;fixtures 与 `fs.ss` 的 mktmp 都登记进去,且**空串当场报错**(不再静默污染 cwd)。实测泄漏从 ~250/轮降到 **0/轮**。

**依赖序**:
- C0–C3 可**先于阶段 B** 落地(不依赖 bake 吸收)——过渡期 bake 子进程仍跑,但 libdirs 已是 per-dep 对、resources 已统一、`.env` 已生效。
- C4–C5 依赖阶段 B4(compile 吸收完成)——install/pack 从 `_vendor/` + `_build/` 取需要进程内编译。
- C6 最后。

**原 C 阶段被消除的任务**:
- ~~C1 `build` 去掉 `install-dep-objects!`~~ — per-dep pairs 模型里 `install-dep-objects!` 整个删除(对象不搬进 lib/)。
- ~~C3 `assembled` 命令~~ — 消除:dev 期全 live,不需要组装步骤。
- ~~C4 `run`/`repl` 自动触发 assembled~~ — 消除:run/repl 直接用 per-dep pairs,无 assembled 可触发。
- ~~C5 `CHANDLER_DEV_ROOT`~~ — 消除:src-scan 直接从 `<src>/resources/` 读,无需 env var。

#### 阶段 D — 收尾(bootstrap/launcher 合一,可同期 B7)

| # | 任务 | 状态 | 文件 |
|---|------|------|------|
| D1 | 两套 bootstrap 合一(chandler `bootstrap.ss` 统一安装编译引擎 + 包管理) | 🔲 待实现 | `bootstrap.ss` |
| D2 | 两套启动器合一(不再有独立 bake 启动器) | 🔲 待实现 | `bootstrap.ss` |
| D3 | `chandler init` 模板:核对后**无需改动**(init 本就不生成 recipe.ss;B6b 后 recipe 可选正是想要的形态) | ✅ 已完成(核对) | `chandler/cli/commands.ss` |

**发布节奏**:A 已完成(消灭漂移);B 逐模块吸收(B1–B5 串行,B6–B7 一次合仓);C0–C3 可先于 B 落地(per-dep pairs + 统一 resource-path + .env,过渡期 bake 子进程仍跑);C4–C6 依赖 B4(进程内编译);D 是 B7 延伸。

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
