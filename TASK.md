# Chandler 实现任务清单

> 本仓库**只实现 Chandler**(包管理器)。bake 在另一仓库实现——凡涉及编译动作(`compile-tree`/`native`)Chandler 只做**排单 + 子进程调用 + porcelain 契约**,以 mock bake 测试(见阶段 10)。
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
manifest.ss  manifest.lock  Chandler 自身依赖清单(自举:零外部依赖)
recipe.ss                   bake 构建描述(另仓 bake 消费)
install.sh                  薄壳:运行时发现 → chandler install-self
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

---

## 里程碑

| M | 完成阶段 | 可演示 |
|---|---------|--------|
| M1 | 0-2 | `chandler init` 生成清单;清单/锁解析+校验有测试 |
| M2 | 3-5 | `init→add→install→verify` 对本地 git 仓端到端跑通 |
| M3 | 6-7 | `chandler run app.ss` 激活依赖并运行;完整 CLI |
| M4 | 8-10 | 全局安装/卸载、bake 排单(mock)、install.sh 自举 |

## 进度

**全部 11 个阶段(0–10)完成,M1–M4 全部达成。** 环境:Chez 10.4.1 / ta6le。

- 测试:`tests/run-tests.sps` **132 用例全绿**(17 个 suite:util/fs/sexp/layout/version/manifest/lock/proc/fetch/resolve/install/activate/cli/registry/build/selfinstall)。**`scheme`、`petite`、已部署的 `skiff` 三运行时均 132/132**——chandler 自身即跑在 skiff 上(启动器能力探测通过后优先 skiff)。
- **skiff 端到端验证**:skiff 应用(manifest 声明 `(skiff …)`)经 chandler-on-skiff 走 `init→add→install→verify→run` 全通;`chandler run` 依 manifest 自动选运行时(skiff-only→skiff、chez→chez),应用运行期自证落在正确运行时。
- 端到端验证:`init→add→install→verify→list→tree→run→exec` 经二进制跑通;`(activate)` 真实挂载并 import 依赖;全局 `install/uninstall/list/doctor`;`build` 排单经 mock bake + 授权哈希绑定;`install-self` 装 `~/.local` + 自卸载自洽(启动器 skiff 优先运行时发现)。
- 实现的库:`(chandler)` umbrella + 底座 `util/fs/hash/proc` + `sexp/layout/version/manifest/lock/fetch/resolve/install/registry/runtime/activate/build/cli.{args,commands,main,selfinstall}`;测试夹具 `(chandler test fixtures)`。
- 对外共享面(bake 反向依赖):`(chandler lock/registry/layout/sexp)` 导出干净,不 import bake。

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
