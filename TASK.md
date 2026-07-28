# TASK — 代码优化任务清单

来源：2026-07-27 全库分析（公共代码提取 + 算法优化）。按收益从大到小排序。
基线版本：0.1.6（d4965cf）。

- **A / B 部分**（算法性能、公共代码提取）：已完成，见 [完成情况](#完成情况)。
- **C 部分**（Windows 可移植性）：**C1–C8、C10、C11 完成；C9 的套件侧完成，
  两份 CI workflow 已写但都没在 GitHub Actions 上跑过**（Linux 那份的每一步
  在本机原样验过，Windows 那份一步也没跑过）。设计见
  [designs/14-windows-portability.md](designs/14-windows-portability.md)，
  编号与该文 §13 的落地顺序一一对应（C10 = §13 第 8 步）。
  **在 C9 跑绿前，Windows 支持一律标注「未验证」** —— 已落地的部分由平台参数化
  测试在 Linux 上逐字断言，但没有一行在真 Windows 上跑过。

---

## A. 算法 / 性能

### A1. hash.ss 定点化重写 ✅ 已完成，实测 2.8×
- [x] 字运算抽成宏（`w+`/`wxor`/`wand`/`wandnot`/`wor`/`wshl`/`wshr`/`wrotr`/
      `words-ref`/`words-set!`），`meta-cond` 按 `fixnum-width` 选实现：
      ≥37 位走 `fx*` + `fxvector`，否则回落通用 `bitwise-*` + `vector`
      （保住文件头的「可移植」承诺；32 位 Chez fixnum 只有 30 位，
      容不下 5 个 32 位字之和）
- [x] `rotr` 左移前先掩低 n 位，避免 fixnum 溢出
- [x] `K`/`H0` 改为单份 quoted list + `words` 转换，两分支共用常量
- [x] `w` 调度表提到 `sha256-bytevector` 跨分块复用（原来每 64 字节新建一个）
- [x] 验证：4 个标准向量 + 长度 0..300 与改前逐位对拍 + petite.boot 与
      `sha256sum` 一致；反转 meta-cond 条件单独验过回落分支
- [x] `tests/run-tests.sps` 493 passed, 0 failed
- 实测（解释执行）：9.3 MB/s → 25.9 MB/s；回落分支 10.9 MB/s
- 可选跟进（未做）：`pad`（:35-46）与 `sha256-file`（:117-120）整文件读入，
  峰值内存 2× 文件大小；改 64 字节分块流式处理

### A2. build-graph 重复解析 ✅ 已完成，实测 4.4×
- [x] 改为在 `import-graph.ss` 加 `parse-cache`（路径 → lib-node 记忆化），
      而非改 `build-graph` 的契约。理由：昂贵的是 `parse-source`（读文件 +
      抽边），图遍历本身只是哈希查找；共享 `nodes` 表则会让 `library-task`
      返回非本入口可达的节点，改变公开 recipe 面的语义
- [x] `reset-classify-cache!` → `reset-import-caches!`，同时清两张表
      （复位时机相同：codegen 生成源码 / 依赖重铺后磁盘会变）
- [x] 实测（chandler 自身 45 个库文件，模拟 `derive-library-tasks!`）：
      0.044 s → 0.010 s；累计访问 471 节点 / 45 唯一文件 ≈ 10× 重复
- [x] `tests/run-tests.sps` 493 passed, 0 failed

### A3. 消除每文件重复读取 ✅ 已完成
- [x] `build.ss` `library-source?` 改走 `parse-source`：库文件的「首个 datum」
      **就是**整个 `(library …)` 形式，即已读全文，与随后 build-graph 的解析
      完全重复；经 parse-source 后结果进缓存，那一遍白拿
- [x] `dep-native-spec` 删除死绑定 `mf`（`read-manifest` 结果从未使用，白跑
      一次 parse + validate），并与 `project-native-spec` 合并为
      `manifest-native-spec`（两者本是同一逻辑）
- [x] `tests/run-tests.sps` 493 passed, 0 failed
- 未做：`fingerprint-of`（`compile.ss:212`）的第三次读——它要的是**字节**
  哈希，与已解析的 forms 不是一回事；复用需缓存原始 bytevector，收益不明确

### A4. run/test/repl 启动期重复 I/O ✅ 已完成，实测 2.00×
- [x] `native-load-paths` 加二参形接收已算好的 `dirs`；`activate.ss`（activate
      算完立刻传给 activate-natives）、`cmd-run`、`cmd-test`、`cmd-repl`
      四处改为传入。一参形保留，供独立调用
- [x] 拆出 `project-obj-dir`：`native-load-paths` 原先经 `(cdr (project-pair root))`
      拿 obj 目录，而 `project-pair` 的 src 侧要读 manifest —— obj 侧根本不需要，
      白读一次
- [x] 实测（40 个已注册包 × 3 版本的 registry）：1.6 ms → 0.8 ms，
      恰好省掉一整份 `resolved-libdirs`（含 lock 解析 + manifest 读 + registry 全扫）
- [x] `tests/run-tests.sps` 494 passed, 0 failed
- 不做 `read-manifest`/`read-lock` 记忆化：manifest 是小文件，剩下的两次读
  （`proj-srcdir` 与 `interp-kind`，后者还只在无 `--runtime`/`CHANDLER_RUNTIME`
  时才发生）占比很小；而进程级 memo 会让 `init`/`add` 这类「先写后读」的命令
  读到陈旧内容 —— 风险大于收益。昂贵的 registry 扫描已由上面的去重解决

### A5. classify-cache 键改造 ✅ 已完成
- [x] 键从 `(cons ref (lib-roots))` 改为纯 `ref`；roots 变更用「代」作废：
      记下填充时的 roots **列表对象**，查询前比 `eq?`，不同即清表。
      全部写入方（`define-lib-roots` / `build.ss:235` / native gen-root 追加 /
      测试的 `parameterize`）都构造新列表，故 `eq?` 足以认出变更
- [x] `reset-import-caches!` 一并把代重置为 `#f`
- [x] 新增测试 `classify-cache-invalidates-on-roots-change`：两个根下各放一份
      同名库，交替查询验证互不串味 + 「解析不到」方向也按代作废；
      临时去掉作废逻辑确认该测试会失败（非空转）
- [x] `tests/run-tests.sps` 494 passed, 0 failed
- 未做：`compile.ss:71` `non-builtin-edges` 按 node 记忆化（可选项）

### A6. 小型超线性点 ✅ 已完成
- [x] `upstream-prebuilt-roots` 整个删除，改为 `build-deps` 随构建推进增量累积
      upstream 根（建完一个就接上给后面用）。原先每依赖重扫 order 前缀，
      n 个依赖 n²/2 次 `file-directory?`。结果集相同：一个依赖的 `_build/<mt>`
      只在它自己建完时出现，之后不再变
- [x] `string-split` 改索引 + `substring`：1.17 MB 输入 16.8 ms → 5.0 ms（3.4×）
- [x] `string-trim` 同改：28.8 ms → 2.4 ms（12×）；`drop-ws` 随之删除（无引用）
- [x] `string-search` 改逐位置 `string-ref` 比较，不再每位置切 substring
      （原先是 O(n·m) 的**分配**）
- [x] 上述三者用 20 项边界对拍（空串/前导/尾随/连续分隔/全分隔/字符表分隔/
      空 sub/重叠匹配…），新旧实现结果一致
- [x] `parallel-build!` 预先按层分桶（逆序喂入保持桶内原顺序）
- [x] `dedupe-edges` 的 `member` → equal 哈希表
- [x] `select-highest` 预解析成 `(parsed . tag)` 对再 fold
- [x] `resolve.ss` BFS 改逐个 cons + 层末 reverse，层内顺序与先前逐字相同
- [x] `tests/run-tests.sps` 494 passed, 0 failed

---

## B. 公共代码提取

### B1. pack 校验器单一来源 ❌ 评估后不做
读完两侧实现与 `tests/chandler/pack-verifier-parity.ss` 后判断：原方案
（单份 quoted s-expr，进程内 eval、部署侧渲染成串）**弊大于利**，不执行。

- 会把安全关键的校验代码从「编译期检查」退化成「运行期解释执行」：
  未绑定变量、arity 错这类问题推迟到运行时，而且很可能只在校验**失败
  路径**上暴露 —— 恰是最需要它可靠的时候
- 两侧并非同一段代码：一侧返回退出码供 `verify-pack --target` 用，
  另一侧必须直接 `(exit N)` 终止部署进程；可用的 import 也不同
- 清单里的多数子项（`%field1`、native 遍历、`so-ext`、version-match）
  都受同一条「部署态没有 chandler 可 import」约束，本就合并不了
- 现有 parity 测试把生成的源码串 eval 进干净环境，对整张决策矩阵逐条
  比对两份实现，还钉住了刻意保留的差异（caret 语法不支持）。它提供的
  保障不弱于重构能给的，且不牺牲编译期检查

结论：重复是**被构造性验证管住的**，保留现状。

### B2. manifest-vs-磁盘校验合一 ❌ 评估后不做
`cli/commands.ss` 的 `verify-declared-files` 与 `pack/verify.ss` 的
`verify-pack-integrity!` 骨架相似，但差异集中在几乎每一步：条目形状
（`(rel . sha)` vs `(rel (sha256 …) (size …))`）、是否查 size、是否有
schema 校验（INVALID）、排除规则、扫描根（`_vendor/` 子树 vs 整个包根）、
EXTRA 文案、是否统计并打印 ok/extra 汇总。

抽成公共函数要 7 个参数才能覆盖这些差异，而共享骨架本身不到 20 行 ——
抽象比重复更难读。B3 的 `relativize` 已经把两处**真正**逐字相同的那行
统一掉了，剩下的差异是实质性的，保留两份更清楚。

### B3. fs.ss / layout.ss 工具补齐 ✅ 已完成
- [x] `fs.ss` 加 `path-has-segment?` + 常量 `unmanaged-path-segments` +
      `unmanaged-path?`：合并 `cmd-verify` 的 `generated-path?`、install 的
      `vendor-unmanaged-path?`（两者逐字节相同）、fetch 的 `build-tree-path?`
- [x] `fs.ss` 加 `relativize` / `rel-files-under`，替换 4 处
      `strip-prefix abs (string-append X "/")`；删掉 registry.ss 里的私有同名版
- [x] `project-manifest-path` / `project-lock-path` + `manifest-filename` /
      `lock-filename` 下移到 `layout.ss`（纯路径函数，先前住 install.ss，
      要 import 整个 install 才能用，于是各处干脆手写字面量）；
      替换 15 处字面量。install.ss 仍 re-export 两名，既有引用方不受影响
- [x] `manifest.ss` 加 `read-project-manifest`（case-lambda，可给 default），
      替换 3 处「存在则读否则默认」成语
- [x] `layout.ss` 加 `walk-native-dirs`：合并 install 的 `native-sos-under`
      与 pack 的 `native-libs-under` 两份递归。顺带统一了两个行为——
      遍历按名排序（pack 清单要确定性输出，native 预载也不该依赖 readdir
      任意顺序）、按扩展名跳过对象文件不 stat
- [x] `tests/run-tests.sps` 494 passed, 0 failed

### B4. shell 引号统一 ✅ 已完成，是真 bug
- [x] `recipe.ss` 的 `shq` 改为 `shell-quote` 的别名。原实现只包双引号，
      注释称「路径没有 shell 特殊字符」—— 那是假设不是保证：双引号内
      `$` `` ` `` `\` `"` 对 sh 仍然特殊
- [x] **验证过这不是理论问题**：路径含 `$` 时，旧式
      `cd "…/we$ird dir"` 被 sh 展开成 `…/we dir`，cd 失败退 2；
      改后单引号形正常。影响面是 compile 的 worker 命令
      （`compile.ss:578-584`、`:607`）与 native-build 的 cmake/make/script
      三个后端（`:211-262`）——全是真实路径
- [x] 两份 `env-prefix` 合并到 `proc.ss` 并导出（保留 native-build 需要的
      #f 值过滤，`CHEZ_INCLUDE` 可选正靠它）
- [x] 新增 2 个回归测试：`env-prefix` 的引用与 #f 跳过、以及含
      空格/`$`/反引号/引号的值端到端穿过 /bin/sh 后原样抵达子进程
- [x] `tests/run-tests.sps` 496 passed, 0 failed

### B5. 机械替换 ✅ 已完成（逐条核对过语义，3 项因不等价而跳过）
- [x] `env.ss` `char-index-from` → `util.ss` `char-index` 三参形
      （原注释「util 没有从某位起找字符」有误）
- [x] `import-graph.ss` `dep-find-clause` → `sexp.ss` `field`
- [x] `build.ss` `canonical-inline` → `util.ss` `datum->string`
- [x] `install.ss` `opt` 别名删除，7 处调用改直接 `alist-ref`
- [x] `pack/manifest-writer.ss` `strip-ext` → Chez `path-root`
      （逐例验过：`greet.so`/`a.b.c`/`foo`/`foo.`/`.hidden` 结果全同）
- [x] 27 处 `(fprintf (current-error-port) …)` → `eprintf`
- [x] `compile.ss` 两个 register-task 合并成 case-lambda 带可选 `kind`
- [x] `util.ss` 加 `name->string`，替换 4 处 symbol/string 归一
- [x] `abspath` 提到 `layout.ss`，合并 3 处成语
- [x] `tests/run-tests.sps` 496 passed, 0 failed

**核对后跳过（语义不等价，换了会引入 bug）**：
- `recipe.ss` `file->string` / `file->lines` ✗ → `fs.ss` `read-file-string` /
  `read-lines`：fs 版对**不存在的文件**返回 `""` / `'()`，recipe 版抛错。
  recipe 读不到文件应当响亮失败，不该静默拿空内容
- `recipe.ss` `path-ext` ✗ → Chez `path-extension`：无扩展名时 recipe 版返回
  `#f`、Chez 版返回 `""`；`.hidden` 时 recipe 版返回 `".hidden"`、Chez 版返回
  `"hidden"`。path-ext 是 recipe 面公开 API，契约就是「没有扩展名给 #f」
- `compile.ss:516` 的 `fprintf` ✗ → `eprintf`：它在 quasiquote 的 worker 脚本
  datum 里，那份要作为独立脚本跑，`eprintf` 在其中未绑定。
  `pack/run-sps.ss` 两处同理（在生成的源码**字符串**里）

### B6. bootstrap.ss 策略镜像防漂移 ✅ 已完成（走 parity 测试）
按 pack verifier 的先例走 **parity 测试**而非代码生成：bootstrap 的自包含是
硬约束（同 B1），纯管道复制（dirname/join-paths/rm-rf）保留不动。

- [x] 新增 `tests/chandler/bootstrap-parity.ss`（9 条）。做法与
      pack-verifier-parity 同构：**不重新实现** bootstrap 的逻辑（那只会变成
      第三份副本），而是把 bootstrap.ss 当**数据**读进来（先剥 shebang 行）、
      按名字抽出那几个 `define`、eval 进干净的 `(chezscheme)` 环境再比对。
      依赖（join-paths/win?/getenv*/home）同样从 bootstrap.ss 抽
- [x] 覆盖：① `target-libdir`/`target-bindir` × user/system/prefix 对
      `registry` 的 `default-*`；② `interp` 对 `choose-interp`，覆盖
      默认跟随 / CHANDLER_RUNTIME 压过 / 可执行文件覆盖 / 空串视为未设 /
      非法值两侧都拒；③ bootstrap 的 `q` 对 `shell-quote`（含端到端穿 sh）
- [x] **验证非空转**：故意制造 3 处分叉（libdir 表改字、裸 getenv、
      `q` 退回双引号），分别报 1/3/2 条失败，还原后全绿

期间修掉两个真问题（都在 bootstrap 的策略侧，与库侧已分叉）：
- **`q` 只包双引号** —— 与 B4 同一 bug 的第三份。验证时看到旧实现让
  `` `id` `` **真的执行了命令**，不只是路径拼错，是命令注入面。
  改为单引号转义（自包含，与 `shell-quote` 同语义）
- **裸 `getenv`** —— 库侧用 `getenv*`（空串视为未设，因为 Chez 的 putenv
  删不掉变量、还原只能置 ""）。bootstrap 用裸 getenv，`CHANDLER_SKIFF=""`
  会让它拿 `""` 去 exec 一个空命令名。已加自包含的 `getenv*` 并对齐
- [x] `scheme --script bootstrap.ss --bootstrap-only` 端到端跑通，
      产出的 `_bootstrap/bin/chandler --version` 正常（改动都在这条路径上）

### B7. 测试样板 ✅ 已完成
- [x] `fixtures.ss` 加 `write-file-tree` / `with-file-tree` / `with-proj`：
      合并 **5 份**文件树夹具（原分析只列了 4 份，`native-build.ss` 里还有
      第五份 `with-proj`）
- [x] stdout 吞噬合并为三个**各有名字**的函数，不用布尔开关
      （调用点上的 `#t` 说明不了任何事）：
      `run-quiet`（换端口）/ `silently`（换端口 + `*quiet*`）/
      `capture-output`（返回吞下的文本）。原先是 5 份散在 3 个文件里
- [x] `when-compiler` 合并 3 份（`compile.ss` 那份原名 `needs-compiler`）
- [x] 顺带去掉 `build.ss` 已无用的 `(chandler compile)` import
      （`cli-make.ss` 的 task-engine import 仍需要，它用着 `exit-ok`）
- [x] 测试 506 passed, 0 failed；清空 `_build` 从零重编亦通过

---

## C. Windows 可移植性

来源：2026-07-27 全库平台相关代码走查。设计与理由全部在
[designs/14-windows-portability.md](designs/14-windows-portability.md)，
本节只列可勾选的动作 —— **不要在这里重复设计论证**，改主意先改设计文档。

**总目标**：pack 分发态与 install 态只依赖 `cmd.exe`（Windows 必有），
不依赖 PowerShell / MSYS / Cygwin；开发态（`-j` 并行）才允许用 pwsh。

**当前状态**：Windows 支持一律标注为「未验证」，直到 C9 的 CI 跑绿。

### C1. `.registry/<name>.active` sidecar（D35）✅ 已完成
> 设计 §8.1。纯增量，POSIX 侧先受益（awk 下线），不动任何 Windows 代码就能测。

- [x] 写入点**只有** `(chandler registry io)` 的 `write-registered!` /
      `remove-registered!` 两个 —— 三个业务入口（install/uninstall/switch）都经它们，
      故 sidecar 不可能漏更新，且天然落在 D21 的 per-prefix 锁内。
      内容 = 单行版本号 + **结尾换行**
- [x] 原子写：提取 `fs.ss` 的 `write-text-atomic`（temp 与目标同目录 + Windows 先删
      + 失败清残件）。`sexp.ss` 的 `write-canonical-file` 原本内联了一份逐字相同的
      逻辑，一并改为调它 —— 单一出处，顺带把 sexp.ss 那段缩到一行
- [x] 顺序 = **先写权威 `.ss`，再写 sidecar**。中途崩溃 → sidecar 陈旧（doctor 报），
      权威文件始终完整；反过来会出现「registry 说 v1、启动器跑 v2」且无人知晓
- [x] lib 不写 sidecar（无 active、无启动器）；`remove-registered!` 一并清 ——
      孤儿 `.active` 会让启动器指向已不在 registry 里的版本
- [x] `doctor` 新增 issue `active-sidecar-drift`，覆盖三种形态：缺失（含旧版装的包）、
      陈旧、lib 上有多余 sidecar。`#f` 与「文件不存在」同形，故直接 `equal?` 比
- [x] POSIX shim 的 awk 下线 → `IFS= read -r ACTIVE < "$REGFILE"`；
      ps1 侧的正则同步下线 → `Get-Content -TotalCount 1`（C3 会整个换掉，
      但留着一份读 `.ss`、一份读 `.active` 的分叉没有道理）
- [x] shim 缺失分支的措辞改准：原文案是 `not registered`，但对**升级上来的旧安装**
      是误诊（包是注册着的，只是没有 sidecar）。改为
      `not installed, or installed by an older chandler; run: chandler install`
- [x] 测试 +18（506 → 524，0 failed）：registry 侧 13 条（写入/换行/lib 不写/
      switch 跟随/两种卸载/空白读成 #f/三种 drift/sidecar 不被当 registry 扫）、
      cli 侧 5 条**端到端实跑** sh 启动器（stub runtime 打印收到的参数）
- [x] **验证非空转**：三处故意分叉各自变红 —— 去掉 sidecar 写入 → 8 红；
      去掉 doctor drift 检查 → 3 红；shim 退回读 `.ss` → 3 红
- [x] 端到端手测：真装 hello 1.0.0 → 启动器跑通、doctor 干净 → 装 2.0.0
      （首装的 active 不被抢）→ `switch` → **启动器文件未重写**但下次启动即换版本
      （D17 稳定 shim 不变量保住）→ 删/改 sidecar → doctor 报 drift → 重装修复
- [x] 清空 `_build` 从零重编亦通过

**迁移**：D35 之前装的包没有 sidecar，启动器退 70 并提示重装；`doctor` 会报
`active-sidecar-drift`，重装或 `chandler switch` 一次即修复。**不做读路径自愈** ——
`read-registered` 在 `run`/`build`/`repl` 的热路径上且不在锁内，让它写文件是错的。

### C2. 资源 segment 拒绝 `\`（P1-2，安全）✅ 已完成
> 设计 §6 末段。一行的事，且是安全边界，不等整个 Windows 计划。

- [x] `fs.ss` 加 `path-sep-char?` / `has-path-sep?`（单一出处，C6 会接着用），
      `runtime-paths.ss` 的 `validate-resource-segment` 改走它
- [x] 测试 4 种绕过写法：`a\b`、`..\..\secret`、`..\../secret`（混合分隔符）、
      `\etc\passwd`。**两个 API 都测** —— 路径穿越不该因为「可选版本」降级成静默 `#f`
- [x] **验证非空转**：改回只拒 `/` → 变红

### C3. 启动器 `.ps1` → `.cmd`（D34）✅ 已完成
> 设计 §8.2–8.7。依赖 C1。做完之后 Windows 就「装得上、发得出」。

- [x] install 模式 Windows shim 改 `.cmd`（`app-launcher-cmd`）：直线代码 +
      底部错误标签，无内嵌块、无延迟展开、无正则、**不 `cd`**（UNC 下可用）；
      退出码与 POSIX 侧逐条对齐（70 / 64 / 127）
- [x] pack 模式改 `.cmd`（`launcher-cmd-skiff` / `launcher-cmd-stock`）；
      `boots-flags` **两侧共用同一个函数**，只在 cmd 侧出口把分隔符归一成 `\`
- [x] **CRLF**：`fs.ss` 加 `write-text-crlf`（幂等，不重复转换），两族写入侧都走它；
      模板里也直接写 `\r\n`，双保险
- [x] **ASCII-only**：cmd.exe 按 OEM 代码页读批处理，不是 UTF-8 —— 生成的注释里
      原本有个 em dash，会显示成乱码，改成 `--`
- [x] `launchers.ss` 的 win 分支去掉 `chmod`（`.cmd` 不需要）
- [x] `remove-app-launcher!` 改为删**三种**形态：sh / `.cmd` / **`.ps1`**。
      旧安装的 `.ps1` 不带走，PATH 上就躺着一个指向已删包的僵尸启动器
- [x] `bin/chandler.cmd`（开发期 wrapper，P0-5）。sh 版的 `_prog_ok` 能力探测
      **刻意不实现**（要把一段 Scheme 源码经 stdin 喂进候选运行时，cmd 里得绕临时
      文件，而它挡的是一个早已过期的 skiff stub）—— 差异是有意的，写在文件注释里
- [x] 取消 `bootstrap.ss` 的「Windows 跳过冒烟测试」：`.cmd` 能被 `system` 直接调起，
      于是自举的最后一环在 Windows 上也真的被验证，而不是印一行提示了事
- [x] **launcher-parity 新 suite（14 条）**：sidecar 路径 / runner 路径拼法 /
      运行时发现顺序 / 五个退出码 / 环境变量 / 不嵌 version / pack 的 boot 链 /
      `.exe` 后缀 / CRLF / ASCII / 反斜杠路径 / `exit /b` 转发 / 不 `cd`，外加
      `known-divergences` 一条**显式钉住有意的差异**（cmd 无 `exec`、`%*` vs `"$@"`）
- [x] `uninstall-removes-all-launcher-forms` 端到端测试（经 `main`，三种形态都清）
- [x] **验证非空转**：四处故意分叉各自变红 —— cmd shim 退回读 `.ss`、cmd 模板改回
      LF、`boots-flags` 出口不归一、`remove-app-launcher!` 不删 `.ps1`
- [x] 端到端手测：install → 启动器实跑 → doctor → **pack → pack 启动器实跑** →
      uninstall 后 bindir 清空
- [x] 测试 524 → 542，0 failed；清空 `_build` 从零重编亦通过
- [x] 文档：`designs/08` §1/§3/§4/§6/§9 全面对齐；两个 README 的 Windows 段重写

**parity 测试自己抓到的第一个问题**：初版按「候选名在全文首次出现的位置」排运行时
发现顺序，sh 侧排出 `(chez skiff scheme)` —— 因为 `case` 分支里的 `chez)` 出现在
发现循环之前。那测的是排版不是策略。改为各自认准发现构造本身（sh 的 `for _c in …`、
cmd 的 `where <cand>` 行）。

**顺带修的文档腐烂**（都不是本次改动引入的，但就在要改的段落里）：
- `designs/08` §4 描述的 pack 启动器与实现早已对不上（文档写 `readlink -f` /
  `PACK_ROOT` / `[ -x ]` 检查 / `boot/<mt>/`，实际是 `CDPATH= cd` / `HERE` /
  无检查 / `lib/chez/`）。既然要改 §4.2，就把 §4.1–4.3 一并按代码校准
- 两个 README 都还在推荐 `bash tests/powershell-run.sh`，而那文件在 `1e88e2d`
  就被删了。改为指向新的 launcher-parity suite

### C4. 换行符与 hash 跨平台一致（D38，P1-3）✅ 已完成
> 设计 §9。独立于其它项，不做则跨平台协作随机报错。

- [x] 仓库根加 `.gitattributes`：默认 `* -text`（不猜），源码/数据 `text eol=lf`，
      `*.cmd` / `*.bat` `text eol=crlf`。防 `core.autocrlf=true` 在 checkout 时改字节
- [x] **写侧显式钉死 eol**：`fs.ss` 加 `text-transcoder`
      = utf-8 + `(eol-style none)`，`write-text` / `write-text-atomic` /
      `read-file-string` / `read-lines` 与 `sexp.ss` 的 `read-datum-file` 全部改走它
- [x] `sha256-file` **不做任何归一化**（保持原样）—— 它是文件真实字节的指纹，
      归一化会让 `chandler verify` 失去意义
- [x] 测试 7 条，断言全部落在**字节**上（`get-bytevector-all`）而不是读回的字符串 ——
      若读写两侧都做同样的变换，两个方向的 bug 会互相抵消而测不出来
- [x] **验证非空转**：把 transcoder 换成 `(eol-style crlf)`（就是在模拟
      Windows 上 `native-eol-style` 若为 crlf 的危害）→ **11 条变红**

**为什么不是「用二进制端口」而是「显式 transcoder」**：二进制端口要在每个调用点
自己做 UTF-8 编解码，等于把编码逻辑散到各处。显式 transcoder 一处定义、全仓复用，
且读写对称（`write-text-if-changed` 的比较依赖这条对称性）。

**顺带消掉一个「待核实」**：设计里原本挂着「Chez 的文本端口在 Windows 上是否做
`\n → \r\n` 转换」。答案不必再查了 —— 显式 `(eol-style none)` 之后，
`native-eol-style` 是什么都不影响结果。**不去依赖一个答案，好过去猜它。**

### C5. `proc.ss` 平台派发子进程层（D33，P0-1）✅ 已完成
> 设计 §5。最大一块。**前提事实**：Chez 没有不经 shell 的 spawn
> （`open-process-ports` 实测同样收 shell 命令串，`&&` 会被解释），
> 所以只能把 cmd 的引用规则做对，不能绕开。

- [x] 导出面不变，内部按 `windows-shell?` 分派：
  - [x] 参数引用 `cmd-quote`：`"…"` 包裹 + MSVCRT 反斜杠规则
        （`"` 前与**结尾**的连续反斜杠加倍）。全包在引号里，cmd 的
        `& | < > ^ ( )` 那层**自动安全**，不需要额外 `^` 转义
  - [x] 环境注入：`set "K=v" && cmd`（cmd 完全不认 `K=v cmd`，会当程序名）
  - [x] cwd：`cd /d "d" && ` —— **`/d` 不能少**，跨盘符会静默不切过去
  - [x] `which`：`where.exe <prog>` 取首行（对齐 `command -v` 的语义）
  - [x] `real-path`：Windows 直接返回原路径
- [x] **无法安全传递的当场硬错**：字面 `"` 与换行/回车。cmd 不认反斜杠转义，
      一个裸引号就让引号配对错位，后面的 `& | > ^` 落到引号外变成 cmd 控制字符 ——
      那不是「路径传错」，是**命令注入面**
- [x] **`%` 刻意放行**：cmd 只展开**已定义**的 `%VAR%`，而 URL 编码（`%20`）
      随处可见，一律拒会造大量假阳性。真撞上同名变量时 git 会拿着变形 URL 明确报错，
      不是静默走错。限制写在 designs/14 §3.3
- [x] `make-temp-dir` 修**死循环**：先前对任何 mkdir 失败都重试，temp 根不存在时
      会转到天荒地老。现在只在目标已存在时换名重试，其余原样抛，并先确保 temp 根存在
- [x] `bootstrap.ss` 的 `q` 同步分派（`q-sh` / `q-cmd`），`boot-cli-cmd` 的 Windows
      env 前缀也改走 `q-cmd` —— 先前把 `boot-prefix` 裸贴进引号里
- [x] `-j` 在 Windows 退化为**串行 + 明确提示**（D37）。串行分支**不短路**，
      一批里后面的命令照跑，与并行分支「全部 wait 完再汇总」的可观察行为一致
- [x] **平台参数化测试 13 条**：`windows-shell?` 是 parameter，于是 Windows 那半边
      在 Linux 上逐字断言。覆盖普通/结尾反斜杠、空格、cmd 元字符、`%` 放行、
      三类硬错、`set "K=v" &&` 形与 `#f` 跳过、`cd /d`、`real-path` 恒等
- [x] **bootstrap-parity 补 Windows 侧**（2 条）：两份 `q` 在 cmd 分支上逐字对拍，
      以及「对无法安全传递的输入都拒」。bootstrap 是 Windows 上装 chandler 的唯一入口，
      它的引用错了后面什么都不用谈
- [x] **与参考实现交叉验证**：12 个输入（含 UNC `\\server\share`、多个结尾反斜杠、
      空串）与 MSVCRT 规则的独立实现逐字比对，**全部一致**
- ⚠️ **但只验了 MSVCRT 这一层。** Windows 的命令行要过**三层**，最先经手的是
      `cmd /c` 自己的首尾引号剥离 —— 那一层当时整个没考虑到，于是所有带参数、
      无 cwd/env 前缀的调用在 Windows 上都是坏的。C11 修掉并补了往返验证
- [x] **验证非空转**：五处故意分叉各自变红 —— 不加倍结尾反斜杠、env 前缀退回
      `K=v` 形、`cd` 漏 `/d`、不再拒字面引号、bootstrap 的 `q` 不分派
- [x] 端到端回归：install / pack / doctor / bootstrap 自举 / fetch(git) suite /
      **含 `$` 与空格的路径下 build**（B4 修过的那类）
- [x] 测试 548 → 561，0 failed；`scheme` 与 `petite` 都跑；清空 `_build` 从零重编亦通过
### C6. 路径原语认 `\`（D36，P1-1）✅ 已完成
> 设计 §6。**这是静默错误**，比崩溃危险。

- [x] `fs.ss` 的 `path-sep-char?`（C2 已加）下游全部改走它：`last-slash` →
      `parent-dir` / `base-name`、`path-join*`、`path-has-segment?`、`relativize`
- [x] 新增 `path-segments`（按任一分隔符切段）与 `normalize-seps`（归一到 `/`）
- [x] **`path-has-segment?` 是危害最大的一处**：先前只按 `/` 切，Windows 上
      `C:\proj\_build\x.so` 是**一整段** → `unmanaged-path?` 恒假 →
      install 清单与 `chandler verify` 把生成物和 `.git` 收成受管文件，全程不报错
- [x] `relativize` 改**按段比较**，不做裸字符串前缀匹配（root 是我们拼的 `/` 形、
      abs 来自 Chez 的 `\` 形，前缀必然对不上，"相对路径"其实是绝对路径）。
      返回值分隔符归一到 `/` —— 这些路径要写进 lock 并**跨平台比对**，
      一边 `_vendor/g/g.ss`、一边 `_vendor\g\g.ss` 的话同一棵树算出两份清单
- [x] `parent-dir` 补盘符根:`"C:/foo"` 的父目录是 `"C:/"`（盘根），不是 `"C:"`
      （drive-relative 的「当前目录」，含义完全不同，`ensure-dir` 会往那上面递归）
- [x] `absolute-path?` 收紧为「字母 + `:` + 分隔符」
- [x] **顺带堵上收紧带来的洞**：`runtime-paths` 原先靠 `absolute-path?` 拒
      `C:foo`；收紧后 `C:foo` 不再算绝对，会从检查之间漏过去。改为在资源段里
      **一律拒 `:`**（顺带挡住 NTFS 的备用数据流 `file:stream`）
- [x] 测试 7 条，覆盖纯反斜杠 / 混合分隔符 / 盘符根 / 段判定 / relativize 四态 /
      absolute-path? 六种形态
- [x] **验证非空转**：四处故意分叉各自变红 —— `path-has-segment?` 退回只按 `/`、
      `last-slash` 退回只认 `/`、`relativize` 退回裸前缀、`absolute-path?` 退回宽判

### C7. 环境、临时目录、文件系统语义 ✅ 已完成
> 设计 §7、§10。

- [x] `system-temp-dir`：`TMPDIR` → `TEMP` → `TMP` → 平台默认，空串视为未设
- [x] `fetch.ss` `default-cache-root`：Windows 走 `%LOCALAPPDATA%\chandler\cache`，
      与 `registry.ss` 的 `default-user-libdir` 同一套判别；`XDG_CACHE_HOME`
      显式设置时仍优先（两平台一致）
- [x] `move-file`：目标存在先删再 rename，与 `sexp.ss` / `pack/core.ss` /
      `staging.ss` 对齐
- [x] `copy-exe!`（`pack/core.ss`）：Windows 上不设执行位（那里没有执行位）；
      POSIX 侧改用 Chez 自带的 `chmod`，少起一个进程也不再经过 shell
- [x] `rm-rf`：只读文件清只读位后重试一次（用 Chez 自带 `chmod`，**不 shell-out**
      —— fs 是最底层库不能 import proc，手拼 `system` 等于把 B4 修掉的
      「自己写一份引用」重新引进最底层）；仍失败则**抛**，并说明「只读或被占用」
- [x] NTFS 名字可移植性，**不自动改名**（改名会让包名与磁盘路径失去对应）：
      保留设备名（`con`/`prn`/`aux`/`nul`/`com1-9`/`lpt1-9`，大小写不敏感、
      **带扩展名也算**）在 Windows 上 install 硬错、POSIX 上警告；
      大小写撞名（`Foo` vs `foo`）**两平台都硬错**（那不是「Windows 上不行」，
      是「这两个包在那里是同一个」）。`doctor` 两条都报（它是可移植性审计）
- [x] `.env` 键大小写：记录已知行为，不做归一化（归一化会让 `.env` 在两个平台上
      行为不同，而显式声明的键本就该原样使用）
- [x] 测试 11 条（fs 5 + registry 6）
- [x] **验证非空转**：`rm-rf` 吞失败 / `system-temp-dir` 只认 `TMPDIR` /
      install 不查名字，三处各自变红

**实测发现，值得单独记**:Chez 的 `delete-file` / `delete-directory` **失败时
返回 `#f` 而不抛**（要抛得传 `error?` 第二参）。所以 `rm-rf` 里原先那圈
`ignore-errors` 其实什么都没接住 —— 静默不是它造成的，是这条默认语义造成的，
而 `ignore-errors` 让代码**看起来**已经考虑过失败了。这类「防御性代码防了个寂寞」
比没有防御更难发现。

**一条 POSIX 上验证不了的**:`move-file` 先删目标那行，去掉后测试照样绿
（POSIX 的 rename 本来就原子覆盖）。测试注释里写明了它守的是契约、
而非 Windows 那条语义 —— 那条只能等 C9。**没有假装已经验证过。**

### C8. 文档修正（大部分随 C3 一起做了）
> 原计划单列，但 C3 改完之后 README 的 Windows 一节就**是错的** ——
> 留着等 C8 等于故意让文档说假话，所以随 C3 一起改了。

- [x] `README.md` / `README.en.md` 前置环境表：PowerShell 划掉，改为「不需要」
- [x] Windows 安装小节整段重写：代码块从 PowerShell 语法改成 cmd 语法
      （原来写着 `$env:PATH = …`，在 cmd 里根本不成立），路径 `.ps1` → `.cmd`
- [x] 「Windows 已知限制」：`%` 参数失真、未加引号的 `& | < > ^`、
      Ctrl+C 的 `Terminate batch job (Y/N)?`
- [x] 从旧版升级的说明（重装一次换成 `.cmd`；`uninstall` 会清 `.ps1`）
- [x] 两个 README 里对已删文件 `tests/powershell-run.sh` 的引用 → launcher-parity
- [x] `-j` 在 Windows 退化为串行的说明（D37）：C5 落地后补上，两个 README 的
      「Windows 已知限制」各加一段 —— 退化是**有提示**的（`compile.ss:640`
      在 `-j N>1` 且非 quiet 时打一行 stderr），构建结果与串行一致

### C9. 测试套件去 shell 依赖 + CI ⚠️ 套件侧已完成，Windows CI 尚未跑绿
> 设计 §12 / §12.1。**前面所有工作的验收关口** —— 不做这步，Windows 支持就是「没人跑过」。

- [x] **临时目录去子进程**：`make-temp-dir` 从 `proc.ss` 下移到 `fs.ss`（它一次子进程
      都不起），harness 加 `mktmp` 统一「造 + 登记」。两处 `mktemp -d` 子进程下线 ——
      那个程序 Windows 上没有，失败时还静默返回空串（于是夹具把内容写进仓库根）
- [x] **硬编码 `/tmp` 清掉**：`sexp.ss`（还是个从来没人清的固定文件名）与 `lock.ss`
      改为每用例一个临时目录；`registry.ss:296` / `registered.ss:219` 是**纯字符串**
      （一次也不落盘），字面量改成不像临时目录的形状 + 注释说明，免得下一个人
      以为那里需要一个真存在的路径
- [x] **端到端探针换成 Scheme 运行时本身**（harness 的 `run-probe`）：`sh -c` /
      `echo` / `pwd` / `true` / `false` 在 Windows 上一个都没有，而换成批处理也不行
      —— cmd 的 `%*` 给的是**原始命令行尾部**（我们加的引号还在）、`%1` 又脱一层
      引号，两者都证明不了「参数原样进了 argv」，而那恰恰是 `cmd-quote` 要保证的事。
      `proc` 的 argv / env / cwd / stderr / 退出码五条端到端**两平台都跑**
- [x] **启动器端到端两族共用**：`cli.ss` 的 5 条 shim 用例按平台渲染 sh 或 `.cmd`
      并实跑，差异只在夹具函数里。模板对拍证明不了 `set /p ACTIVE=<file` 真能读出
      版本号，正如它也证明不了 `IFS= read -r`
- [x] **只在 sh 语义下成立的断言用 `when-posix` 明确跳过**（不是放宽），并在注释里
      写明对侧由谁守：`bootstrap-parity` 穿 sh 那条、`proc` 的单引号不展开两条、
      `fs` 的「用目录 w 位造一个删不掉的文件」那条
- [x] **顺带收口的 shell-out**（生产侧，同一类问题）：三处 `chmod +x` 子进程 →
      `fs` 的 `make-executable!`；`mkdir -p` → `ensure-dir`；native-build 的
      `command -v` → `proc` 的 `which`、两处手拼 `cd X && ` → `cd-prefix`
      （Windows 上要 `cd /d`，漏了会静默不切盘）；pack 两个版本探针的
      `sh -c "… < /dev/null"` → `run-capture` 的 `(env . …)` / `(stdin . null)`，
      空设备名由 `fs` 的 `null-device` 按平台给出
- [x] 新增 5 条测试（579 → 584）：`make-temp-dir` 唯一且可写、`null-device` 的平台
      形态、`make-executable!` 的 x 位与 Windows 空操作、stdin 重定向接文件、
      `'null` 解析成空设备
- [x] **验证非空转**：三处故意分叉各自变红 —— `sh-quote` 退回双引号（新端到端
      用例全红）、`make-executable!` 变空操作、stdin 选项不接线。
      `null-device` 那条只有在 Windows 上才验得到 Windows 分支，
      **没有假装它在 Linux 上也被验过**
- [x] Windows CI：`.github/workflows/windows.yml` —— scoop 装 Chez → `run-tests.sps`
      → `bootstrap.ss --prefix=…`（它自带启动器冒烟）→ 装出来的 `.cmd` 实跑 →
      最小 app 的 `build` + `pack` + **执行包里的 `.cmd`**。pack 那步的夹具放在
      `tests/fixtures/packsmoke/`（真文件，不内联进 YAML —— here-string 要同时满足
      YAML 的块缩进和 PowerShell 的「终止符顶格」，两条规则打架），整条命令序列
      先在 Linux 上原样跑通过再写进 workflow
- [x] Linux CI：`.github/workflows/linux.yml` —— **与 Windows 那份同构的三步**，
      外加一遍 Petite（README 把它列为跑套件的方式之一；而「跳过」这件事本身也会坏 ——
      一条本该被 `when-compiler` 跳过的用例若在 Petite 上跑起来，就是
      `compiler-available?` 判错了，只有真在 Petite 上跑才看得见）。
      两个 workflow 共用 `tests/fixtures/packsmoke/` 夹具，不各写一份 ——
      C9 的整件事就是「同一套断言在两个平台上跑」，Linux 这边悄悄少跑一步，
      那句话就不成立了
- [x] **Linux 装 Chez 只能从源码建**：Ubuntu 仓库里的 chezscheme 是 **9.5.8**、
      够不着 `(chez ">=10.0")`，而 cisco/ChezScheme 的 release 只挂**源码** tar.gz
      和一个 Windows 安装器，没有 Linux 二进制。走 mise（它的 chezscheme 插件下载
      官方源码 `./configure --threads && make install`）—— 产出的正是开发者本地
      那份（`ta6le`，README 推荐的 `mise use chezscheme` 同一条路）。
      `--disable-curses` / `--disable-x11` **刻意不用**：那样建出来就不是同一个配置，
      而 CI 的意义正在于跑同一份东西；改为装 `libncurses-dev` / `libx11-dev`
      （Chez `BUILDING` §PREREQUISITES 的两条）。mise-action 默认缓存装好的树
- [x] CI 绿之前，两个 README / 设计文档里 Windows 支持一律标注「未验证」

**两份 workflow 的验证程度不一样，别混为一谈**：

- **Linux 那份逐步在本机原样跑过**（三步 + Petite 那遍 + `set -eu` 的失败分支），
  唯二没跑的是 `apt-get` 与 `mise-action` 这两个装环境的步骤
- **Windows 那份一步也没跑过** —— 我没法从这里执行它。第一次推上去多半要调 scoop
  那一步（Windows runner 上装 Chez 的方式）。**在它绿之前，Windows 支持照旧标
  「未验证」**，C9 的验收那一半仍然欠着

### C10. native `script` 后端的 Windows 分支（D39）✅ 已完成
> 设计 §12.2。C9 收尾时点出的缺口，单独做掉。

**问题**：`run-script-backend` 写死 `sh <script>`。Windows 上没有 sh，于是声明了
`(build (script …))` 的依赖根本建不起来，而报出来的还是 cmd 的一句
「'sh' 不是内部或外部命令」—— 既不提 native-task，也不提该怎么办。

**为什么不能只换个解释器**：脚本是**用别的语言写的**，`sh build.sh` 换成
`cmd /c build.sh` 不会让 sh 脚本变得能跑；要求 Windows 用户装 sh 又和「只依赖
cmd.exe」的底线冲突。**一个包要两边都能建，就得两边各带一份脚本 —— 这是事实，
不是我们造出来的复杂度。**

- [x] `(script …)` 收**一个或多个**脚本，按扩展名挑第一个本平台能跑的：
      Windows 认 `.cmd` / `.bat`（大小写不敏感）用 `call` 起；POSIX **除**这两者
      之外一律交 `sh`。`(build (script "build.sh" "build.cmd"))` 两边都能建
- [x] **`call` 不能省**：cmd 里不带 `call` 调另一个批处理时控制权**不返回** ——
      后面的命令不执行、errorlevel 也不回传。这类问题不会崩，只会让失败的构建
      看起来成功了
- [x] **POSIX 侧刻意不要求 `.sh`**：现存的包写 `(script "build")` / `"mk.bash"`
      都合法，收紧扩展名等于无端把它们判死。只排除 `.cmd` / `.bat` 就够
- [x] 挑不出来 → **config 错**，当场说清本平台认什么、该补什么，而不是把命令
      扔给 shell 让它用自己的话报错
- [x] **顺带修掉一处静默失效**：`toolchain-id` 用
      `cc --version 2>/dev/null | head -1` 取工具链版本 —— 那是 POSIX shell 写法，
      Windows 上 `/dev/null` 不是路径、`head` 不是程序，整条命令失败后被 guard
      吞成 `""`。于是**指纹里的工具链分量恒为空**：换了编译器也不会让 native 产物
      失效，而这个函数存在的唯一理由就是那个。改走 `run-capture` + 在 Scheme 里
      取首行；**逐字节比对过 POSIX 上结果不变**，故已有指纹不失效、不触发重建
- [x] `pick-script` / `script-command` 都是纯函数并导出，两侧用 `windows-shell?`
      参数化在 Linux 上逐字断言（`cd /d` / `set "K=v" &&` / `call` 三处差异）
- [x] 夹具的 native 依赖同时带 `build.sh` 与 `build.cmd`，于是 build / pack 的
      native 端到端用例**两平台跑同一组断言** —— C9 里加的那道 `when-native-script`
      POSIX 门随之删掉
- [x] 测试 584 → 589（5 条）；`scheme` / `petite` / `skiff` 三个运行时都跑
- [x] **验证非空转**：三处故意分叉 —— Windows 分支退回 `sh`、挑脚本不看平台、
      挑不出来时不报错。**第三处第一次没变红**：后端跑完还有一道「产物在不在
      落点」的核验，那条也会抛，于是 `assert-raises` 被它喂饱了。改成断言
      **stderr 里的诊断文本**（说清了平台、声明了什么、该补什么）之后才真的
      红 —— 一条只看「抛没抛」的用例，在有第二个抛点的地方等于没写

### C11. 照 bake 的真机经验复查（D40 / D41）✅ 已完成
> 设计 §3.4、§11b。来源：`~/workspace/bake` 的 Phase L —— 它已在真 Windows 上跑过
> 四轮，D67–D73 是那四轮换来的。逐条比对后采纳 6 条、结论已一致 2 条、不采纳 2 条。

**其中一条是 chandler 当时就有的 P0 真 bug。**

- [x] **D40 — Windows 命令行是三层不是两层**（bake D68）。`cmd /c` 在把命令行交给
      解析器**之前**先看首字符：是引号（且不满足「恰好两个引号 + …」那个特例）就
      **剥掉第一个与最后一个引号**。而我们生成的命令行必然以引号开头（程序名被
      `cmd-quote` 包了），参数一多就有四个以上引号 —— 特例永不成立，必然踩中：
      `"where" "git" >"…"` 剥成 `where" "git" >"…`，命令名成了 `where" "git"`。
      **凡是「有参数、且没有 `cd /d …` / `set "K=v" …` 前缀」的调用在 Windows 上
      全是坏的** —— fetch 的所有 git 调用、`which`、`run-foreground`
      （`run`/`exec`/`repl`）、版本探针、recipe 的多参数 `run`
- [x] 对策：首字符是引号时整行再包一对；**包裹必须作用在含重定向的最终整行上**
      （只包参数段的话，「最后一个引号」变成重定向路径的收尾引号，剥掉它把路径
      拆坏）。故全仓 `system` 出口收敛成 `proc` 的 `shell-system` 一个；
      `bootstrap.ss` 另有自包含副本，由 bootstrap-parity 逐字对拍。
      包完之后引号数恒 ≥ 4 ⇒ cmd 的保留特例**永不成立**，行为是确定的，
      不依赖「中间那串是不是可执行文件」这种运行期判断（单独有一条断言钉住）
- [x] **补上缺的那种验法**（bake D69）：把 `cmd /c` 的剥离规则**独立实现一遍**
      （`cmd-c-strip`，刻意与被测实现反向写：它加，这里减）做往返。
      C5 只对 MSVCRT 那层做过交叉验证、没对这一层做 —— 这正是漏掉的原因。
      教训写进 §3.4：**往返验证能证明「转义符合我理解的规则」，证明不了
      「我理解的规则就是全部的规则」**
- [x] **D41 — 跳过必须报出来**（bake 的 `run-all` 结尾 MUST）。`when-posix` /
      `when-windows` / `when-compiler` / `needs-toolchain` 先前都是**静默**跳过，
      于是「N passed」在另一个平台上是个假象。改为逐条记名 + 原因，汇总行变成
      `N passed, M failed, K skipped` 并按原因分组列出。
      **立刻见效**：petite 那一遍原来藏着 **22 条** 跳过（全是 no-compiler），
      而我上一轮刚把「跑一遍 petite」写进 Linux CI 当作额外覆盖
- [x] **临时目录兜底**（bake 实测）：Windows 侧原先回落到 `C:\Windows\Temp`
      —— **普通账户没有写权限**。改为 per-user 的
      `%USERPROFILE%\AppData\Local\Temp`，四个都没有就明确报错。
      选择逻辑抽成纯函数 `choose-temp-dir`，Windows 那半边在 Linux 上逐条断言
- [x] **`make-temp-dir` 在 POSIX 侧建 0700**（bake 的 `%mkdir-private`）：
      `run-capture` 把子进程 stdout/stderr 落在那里，而那里面是 git 的输出 ——
      **带凭据的 remote URL 就在其中**，共享 `/tmp` 默认 0755 同机可读。
      「已存在即换名重试」那条不依赖权限位，依赖 mkdir 的「已存在即失败」
- [x] **D72 — 判「平台不适用」前先分清缺的是能力还是某个具体手段**：
      `rm-rf` 删不掉那条**不再在 Windows 上跳过** —— Windows 有「删不掉的文件」
      这个能力，缺的只是「chmod 0500 父目录」这个手段。改为两平台各用自己的夹具
      （POSIX 去 w 位 / Windows 持有打开句柄），守同一条契约。
      **Windows 那半边尚未实测**：若 Chez 在那边开文件时带了 `FILE_SHARE_DELETE`，
      这条会因为「删成功了」而红 —— 那也是有用的信息，比跳过强
- [x] 补上 bake D67 更锋利的论证（注释）：不看 `COMSPEC`/`OS` 的理由是
      **Git Bash 下父 shell 是 sh，而 Chez 的 `system` 仍走 `%COMSPEC%` 拉 cmd
      —— 判平台要判子进程 shell 是谁**
- [x] 测试 589 → 595（6 条：cmd /c 往返 4 条 + 临时目录选择链 + bootstrap 对拍）
- [x] **验证非空转**：三处故意分叉各自变红 —— `cmd-outer-quote` 变恒等
      （往返那条报出的正是被截断的 `where" "git`）、bootstrap 那份变恒等、
      以及先前几轮的分叉复跑
- [x] 三个运行时全绿；bootstrap 自举 + pack 实跑端到端复跑

**不采纳的两条，理由是场景不同而非疏漏**：

- **`%` 的处置**：bake 在多参数形式下**拒绝**含 `%` 的参数，chandler **放行**。
  bake 引的是 recipe 作者写的命令，chandler 引的是 git URL 与路径，而 `%20`
  这类 URL 编码随处可见，一律拒会造出大量假阳性。取舍见 designs/14 §3.3
- **D73**（Windows 的 broken pipe 因 `_dosmaperr` 未收录 109 而报
  `invalid argument`）：chandler 全库没有按错误文案分派的地方，不适用

### C 部分的验证纪律

六条。前三条与 A/B 部分已经确立的做法一致，后三条是 C11 从 bake 的真机四轮
里换来的（`~/workspace/bake` Phase L / D67–D73）：

1. **平台参数化优先** —— 能在 Linux 上断言生成结果的，就不要等到 Windows 才发现。
   `shell-quote` / `env-prefix` / 路径原语 / 两族启动器模板全部适用。
2. **parity 测试必须验证非空转** —— 故意制造分叉，确认它会红。
   B6 就是这么发现 `bootstrap.ss` 的 `q` 让 `` `id` `` 真的执行了命令。
3. **静默失败一律改成响亮失败** —— C6 / C7 里多数问题的危害不是「挂了」，
   而是「没挂但结果是错的」（清单收错文件、目录没清干净、mtime 没更新）。
4. **平台相关代码要两种验法，缺一不可**（bake D69）。**静态**：把对方的解析规则
   独立实现一遍做往返，平台无关、任何机器都能跑。**动态**：真过一遍 shell 拉起
   真外部程序，只验当前平台，但覆盖了静态验法证明不了的那一段 —— shell 自己那层。
   C5 只做了静态的一半（MSVCRT），漏掉的 `cmd /c` 那层是 bake 在**真机**上撞出来的：
   **往返验证能证明「转义符合我理解的规则」，证明不了「我理解的规则就是全部的规则」。**
5. **跳过必须报出来**（D41）—— 一条被平台/环境门挡掉的用例，与它跑过并通过，
   在「N passed」里长得一模一样。静默跳过让另一个平台上的绿色变成假象。
6. **判「某场景在 X 平台不适用」之前，先分清缺的是「操作系统能力」还是
   「某个具体命令/手段」**（bake D72）。缺手段就换个夹具，别归到平台组去 ——
   **平台组该尽量小**。bake 一度把 broken pipe 判为 Windows 不适用，实际缺的
   只是 `head`；chandler 这边是 `rm-rf` 删不掉那条，缺的只是「chmod 0500 目录」。

---

## 完成情况

A 部分（算法/性能）：A1–A6 全部完成。
B 部分（公共代码提取）：B3/B4/B5/B6/B7 完成；B1/B2 评估后判定不做
（理由见各节 —— 两者的「重复」要么受硬约束无法合并且已有构造性验证兜底，
要么抽象成本高于重复本身）。

实测收益汇总：

| 项 | 改前 | 改后 | 倍数 |
|---|---|---|---|
| SHA-256（petite.boot 2.16 MB） | 9.3 MB/s | 25.9 MB/s | 2.8× |
| build-graph（45 个库文件） | 44 ms | 10 ms | 4.4× |
| resolved-libdirs + native-load-paths（40 包 registry） | 1.6 ms | 0.8 ms | 2.0× |
| `string-trim`（1.17 MB） | 28.8 ms | 2.4 ms | 12× |
| `split-lines`（1.17 MB） | 16.8 ms | 5.0 ms | 3.4× |
| classify-libref 单次查询（20 条 roots） | 1.23 µs | 0.025 µs | 49×（分析代理实测） |

另修三个真 bug，都是同一类「假设代替保证」：

1. **B4 — `recipe.ss` 的 `shq` 不转义**：注释写「路径没有 shell 特殊字符」，
   但双引号内 `$` `` ` `` `\` `"` 对 sh 仍然特殊。含 `$` 的路径会让 compile
   worker 与 native-build 的三个后端 `cd` 失败
2. **B6 — `bootstrap.ss` 的 `q` 同一 bug 的第三份**：验证时看到旧实现让
   `` `id` `` **真的执行了命令** —— 不只是路径拼错，是命令注入面
3. **B6 — `bootstrap.ss` 用裸 `getenv`**：库侧用 `getenv*`（空串视为未设，
   因 Chez 的 putenv 删不掉变量、还原只能置 ""）。`CHANDLER_SKIFF=""` 会让
   bootstrap 拿 `""` 去 exec 一个空命令名

测试：494 → 506，0 failed。新增 12 个：
- classify-cache 代际作废（A5）
- env-prefix 的引用与 #f 跳过、端到端穿 /bin/sh（B4）
- bootstrap-parity 9 条（B6）

三个新增的 parity/回归测试都验证过**非空转** —— 故意制造分叉后确认它们会红。
