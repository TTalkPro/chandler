# TASK — 代码优化任务清单

来源：2026-07-27 全库分析（公共代码提取 + 算法优化）。按收益从大到小排序。
基线版本：0.1.6（d4965cf）。

- **A / B 部分**（算法性能、公共代码提取）：已完成，见 [完成情况](#完成情况)。
- **C 部分**（Windows 可移植性）：未开始。设计见
  [designs/14-windows-portability.md](designs/14-windows-portability.md)，
  编号 C1–C9 与该文 §13 的落地顺序一一对应。

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
- [x] **验证非空转**：五处故意分叉各自变红 —— 不加倍结尾反斜杠、env 前缀退回
      `K=v` 形、`cd` 漏 `/d`、不再拒字面引号、bootstrap 的 `q` 不分派
- [x] 端到端回归：install / pack / doctor / bootstrap 自举 / fetch(git) suite /
      **含 `$` 与空格的路径下 build**（B4 修过的那类）
- [x] 测试 548 → 561，0 failed；`scheme` 与 `petite` 都跑；清空 `_build` 从零重编亦通过
### C6. 路径原语认 `\`（D36，P1-1）
> 设计 §6。依赖 C5 的实跑才能验证。**这是静默错误**，比崩溃危险。

- [ ] `fs.ss` 加单一出处的 `path-sep-char?`（`/` 或 `\`），下游全改走它：
      `last-slash`(:32) → `parent-dir` / `base-name`、`path-join*`(:26)、
      `path-has-segment?`(:166)、`relativize`(:180)、`rel-files-under`
- [ ] `path-has-segment?` 修好后，`unmanaged-path?` 才能认出 `_build` / `.git`
      —— 否则 install 清单与 `chandler verify` 会把生成物和 `.git` 当受管文件
- [ ] `relativize` 处理**分隔符不一致**的前缀匹配：按段拆分比较，
      不做裸字符串前缀比较
- [ ] `absolute-path?`(:45) 收紧：`[A-Za-z]` + `:` + 后跟分隔符
      （当前只要第二字符是 `:` 就算绝对，POSIX 上 `a:b` 会误判）
- [ ] 测试：混合分隔符路径穿过全部六个函数

### C7. 环境、临时目录、文件系统语义
> 设计 §7、§10。

- [ ] `system-temp-dir`（`fs.ss:188`）：`TMPDIR` → `TEMP` → `TMP` → 平台默认
      （当前 Windows 上全部临时文件写向不存在的 `/tmp`）。
      **另一半已在 C5 修掉**：`make-temp-dir` 撞上不存在的 temp 根不再死循环，
      而是给出「设 TMPDIR / TEMP / TMP」的可操作错误 —— 于是这条即便没做完，
      失败方式也已经从「转到天荒地老」变成「一句话说清」
- [ ] `fetch.ss:24` `default-cache-root`：Windows 走 `%LOCALAPPDATA%\chandler\cache`，
      与 `registry.ss` 的 `default-user-libdir` 同一套判别
- [ ] `move-file`（`fs.ss:110`）：目标存在先删再 rename，与 `sexp.ss` /
      `pack/core.ss` / `staging.ss` 对齐。修掉 `touch-file!`
      （`compile.ss:295`）在 Windows 上被 `ignore-errors` 吞掉的静默失效
- [ ] `copy-exe!`（`pack/core.ss:183`）补 win 分支，不调 `chmod`
- [ ] `rm-rf`（`fs.ss:88`）：遇只读文件（git 的 `.git/objects/**`）先清只读属性
      再重试一次；**仍失败不再吞** —— 让调用方知道没清干净
- [ ] 被占用文件（已 `load-shared-object` 的 DLL、运行中的 exe）：
      **响亮失败** + 可操作提示（「有进程正在使用 X，关闭后重试」），不留静默残件
- [ ] NTFS 大小写不敏感 / 保留名（`aux`/`con`/`nul`/`prn`）：
      `install` 与 `doctor` 报错，**不自动改名**（改名会让库名与磁盘路径失去对应）
- [ ] `.env` 键大小写差异：记录已知行为，不做归一化

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
- [ ] **留给 C5/C7**：`-j` 在 Windows 退化为串行的说明（D37 还没实现，
      现在写上去就是提前描述一个不存在的行为）

### C9. 测试套件去 shell 依赖 + Windows CI
> 设计 §12。**前面所有工作的验收关口** —— 不做这步，Windows 支持就是「没人跑过」。

- [ ] 测试套件里的 `sh -c` / `/tmp` 硬编码抽象掉
      （`tests/chandler/proc.ss`、`cli.ss:367`、`sexp.ss:10`、`lock.ss:56`、
      `registry.ss:296`、`registered.ss:219`）
- [ ] Windows CI：跑 `bootstrap.ss` + `run-tests.sps` + 一次 `pack` 后实跑
- [ ] CI 绿之前，README / 设计文档里 Windows 支持一律标注「未验证」

### C 部分的验证纪律

三条，与 A/B 部分已经确立的做法一致：

1. **平台参数化优先** —— 能在 Linux 上断言生成结果的，就不要等到 Windows 才发现。
   `shell-quote` / `env-prefix` / 路径原语 / 两族启动器模板全部适用。
2. **parity 测试必须验证非空转** —— 故意制造分叉，确认它会红。
   B6 就是这么发现 `bootstrap.ss` 的 `q` 让 `` `id` `` 真的执行了命令。
3. **静默失败一律改成响亮失败** —— C6 / C7 里多数问题的危害不是「挂了」，
   而是「没挂但结果是错的」（清单收错文件、目录没清干净、mtime 没更新）。

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
