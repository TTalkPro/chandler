# Changelog

本文件记录用户可见的变更。设计决策的完整记录在 [designs/00-design-principles.md](designs/00-design-principles.md) 的决策表。

## 未发布

Windows 可移植性工作的第一步(设计见
[designs/14-windows-portability.md](designs/14-windows-portability.md))。

### 变更

- **启动器改读 `.registry/<name>.active` 纯文本 sidecar**(D35)。此前 shim 要自己
  解析 `<name>.ss` 里的 `(active "<v>")` —— sh 侧一段 awk、PowerShell 侧一段正则,
  两份实现、两份 bug 面,还让启动器与 registry 的文件格式绑死。现在 `install` /
  `switch` / `uninstall` 顺带维护一个单行文本文件,两边各一行读取即可。
  `.ss` 仍是唯一权威,`.active` 是它的派生投影。
- **`chandler doctor` 新增 `active-sidecar-drift` 检查**:sidecar 缺失、陈旧、
  或 lib 上有多余 sidecar,三种都报。

### 升级注意

- **已装的包需要重装一次**。0.1.6 及更早版本装的包没有 sidecar,新启动器会退 70 并
  提示 `not installed, or installed by an older chandler; run: chandler install`。
  `chandler doctor` 会把它列为 `active-sidecar-drift`;重装或对该包
  `chandler switch` 一次即修复。

## 0.1.6

一轮以**代码审计**为主的发布:修掉 6 个 bug(其中 3 个是长期存在、只是没人踩到的),
消除若干平方级算法与重复实现,收缩公共 API 面。无新增命令。

### 修复

- **`.env.tests` 不再泄漏到 `run` / `repl` / `exec` / `env`**。此前只要项目根存在
  `.env.tests`,这四个命令都会静默加载它 —— 对着测试数据库跑生产脚本这种事,不该由
  一个约定文件的存在与否决定。现在只有 `chandler test` 读它(README 一直是这么写的,
  是实现没对齐)。
- **`chandler init` 生成的 `.gitignore` 补上 `/_vendor/` 与 `/dist/`**。此前只有已废弃的
  `/vendor/` `/lib/`,新项目会把整棵依赖 checkout 和 `chandler pack` 的输出提交进 git。
- **`chandler build` 之后 `chandler deps` / `chandler verify` 不再失败**。构建产物落在
  vendored checkout 里的 `_build/`,被 git 报成 untracked,于是 `deps` 以
  「has local changes; refusing to overwrite」挡住重跑、`verify` 判脏。`dirty?` 现在
  忽略 `_build/` 下的条目。
- **`chandler verify` 不再对任何真实项目恒失败**。lock 的 `(files …)` 生产侧此前未实现,
  空声明配上 EXTRA 扫描会把 `_vendor/` 下每个文件(含整个 `.git/`)都判成「不在 lock 里」。
- **path 依赖没有 `chandler-manifest.ss` 时 `chandler deps` 不再崩溃**。`git-provider`
  该分支返回的值数与解构不符,Chez 直接抛。
- **`TMPDIR` 含空格不再破坏并行构建与 `run/capture`**;`recipe.ss` 残留的硬编码 `/tmp`
  改走 `system-temp-dir`。

### 变更

- **全局兜底每包只挂一个版本**(D31):app 取 `(active …)`、lib 取盘上最高 semver。
  此前把每个包的**每个**版本都挂进 `library-directories`,生效的是「最后登记的那个」
  —— 偶然结果,且让 `chandler switch` 在 `run` / `repl` / `build` / `test` 上完全失效。
- **`chandler deps` 现在记录 `_vendor/` 的文件清单与 sha256 到 lock 的 `(files …)`**
  (D32,D15 的生产侧),路径相对项目根。`chandler verify` 据此做内容校验。
- **`chandler verify` 现在跑两道检查**:git 态(HEAD == lock 的 rev、工作区无脏改动)
  + 内容哈希。lock 没有 `(files …)`(v2 老 lock、或尚未重跑 deps)时跳过后者。
- **`BAKE_OPTIMIZE_LEVEL` → `CHANDLER_OPTIMIZE_LEVEL`**,旧名保留为过渡别名。

### 性能

- `files-under` 由平方级改为线性;`native` 兜底扫描按对象树形状剪枝并按扩展名免 stat
  (实测 4200 文件的前缀 10.2ms → 3.6ms)。
- 注册表由「解析两遍」改为一遍(40 包 × 3 版本实测 1.7×)。
- `chandler build` 的循环不变量外提:此前每个依赖都要重读一次 lock、重扫一次全局前缀。
- `toolchain-id` 记忆化(此前每次算指纹都 fork 两个子进程问编译器版本)。
- `string-join` / `topo-sort-sos` 去平方级;`verify` 与 `verify-pack` 的 declared 表改
  hashtable 索引;`sexp` 的行内渲染超预算即早退。

### API(仅影响 `import` chandler 库的代码)

- 删除:`manifest-resources`、`manifest-runtime-subset`、`locked-dep-resources`、
  `lock-ref`、`lock-file-sha256`、`registered-clear-active`、`registered-version-entry`、
  `library-name->path`、`machine-type-string`(用 `current-machine-type`)、
  `string-subst`、`strip-leading`、`rel-to`、`bake-version`(用 `chandler-version`),
  以及 `compile` / `import-graph` / `registry` 若干仅内部使用的导出。
- 新增:`(chandler fs)` 的 `absolute-path?`(含 Windows 盘符);
  `(chandler runtime-paths)` 的 `define-resource-path-resolver`(此前定义了却漏导出)。
- `manifest` 与 lock 的 `(resources …)`、manifest 的 `(runtime-subset …)` 字段不再被解析
  —— 旧文件写了仍解析成功(未知字段忽略),只是不再被读取。

### 文档

- `README.en.md` 全面重写:此前仍描述外部 `bake`、`recipe.ss`、`manifest.ss`、
  汇总 `lib/`、`APP_ROOT`、`install-self` 等早已废弃的架构。
- `designs/06` 补 §9.5(全局兜底选版规则)与 `(files …)` 的双基准表;
  `designs/11` 补 `verify` 两道检查的分工与三处必须一致的排除规则。

## 0.1.5 及更早

未维护变更日志;见 git 历史与 `designs/` 下的决策表。
