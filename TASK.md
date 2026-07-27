# TASK — 代码优化任务清单

来源：2026-07-27 全库分析（公共代码提取 + 算法优化）。按收益从大到小排序。
基线版本：0.1.6（d4965cf）。

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

### B6. bootstrap.ss 策略镜像防漂移 ⬜ 未做
- [ ] `bootstrap.ss:153-171` libdir/bindir 表镜像 `registry.ss:39-57`；
      解释器选择逻辑共 4 份（`bootstrap.ss:187`、`cli/runtime-env.ss:27`、
      `cli/commands.ss:313`、`compile.ss:478`）
- [ ] 纯管道复制（dirname/join-paths/rm-rf 等）保留不动（自包含红线）；
      两块策略代码加 parity 测试，或构建时从库代码生成
      `bootstrap-prelude.ss`
- 建议按 pack verifier 的先例走 **parity 测试**而非代码生成：bootstrap 的
  自包含是硬约束（同 B1），而 parity 测试已被证明是管住这类重复的有效手段

### B7. 测试样板 ⬜ 未做（低优先）
- [ ] `with-proj` 两份逐字节重复（`tests/chandler/compile.ss:34`、
      `cli-make.ss:18`）+ 两份文件树 fixture → `fixtures.ss` 提
      `with-file-tree`
- [ ] stdout 捕获 3 份、compiler 门 3 份 → 提入 harness/fixtures

---

## 完成情况

A 部分（算法/性能）：A1–A6 全部完成。
B 部分（公共代码提取）：B3/B4/B5 完成；B1/B2 评估后判定不做（理由见各节）；
B6/B7 未做。

实测收益汇总：

| 项 | 改前 | 改后 | 倍数 |
|---|---|---|---|
| SHA-256（petite.boot 2.16 MB） | 9.3 MB/s | 25.9 MB/s | 2.8× |
| build-graph（45 个库文件） | 44 ms | 10 ms | 4.4× |
| resolved-libdirs + native-load-paths（40 包 registry） | 1.6 ms | 0.8 ms | 2.0× |
| `string-trim`（1.17 MB） | 28.8 ms | 2.4 ms | 12× |
| `split-lines`（1.17 MB） | 16.8 ms | 5.0 ms | 3.4× |
| classify-libref 单次查询（20 条 roots） | 1.23 µs | 0.025 µs | 49×（分析代理实测） |

另修一个真 bug（B4）：`shq` 不转义，含 `$` 的路径会让 compile worker 与
native-build 的三个后端 `cd` 失败。

测试：494 → 496（新增 3 个：classify-cache 代际作废、env-prefix 引用与
#f 跳过、env-prefix 端到端穿 /bin/sh），0 failed。

改动全部留在工作区，未提交。
