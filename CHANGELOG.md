# Changelog

本文件记录用户可见的变更。设计决策的完整记录在 [designs/00-design-principles.md](designs/00-design-principles.md) 的决策表。

## 未发布

Windows 可移植性工作的第一步(设计见
[designs/14-windows-portability.md](designs/14-windows-portability.md))。

### 变更

- **Windows 启动器改用 `.cmd`,`.ps1` 下线**(D34)。`.cmd` 只依赖每台 Windows 必有的
  `cmd.exe`:不受 ExecutionPolicy 管,`.CMD` 也在默认 `PATHEXT` 里(于是 cmd、
  PowerShell、被别的程序 spawn 三种情形都能直接调 `<app>`)。**`chandler pack` 打出的
  包因此不再要求用户装 PowerShell** —— 这是先前分发态最硬的一道门槛。

  顺带修掉一个「裸机上必挂」的 bug:旧 `.ps1` 模板用了 PowerShell 6+ 的 `Join-Path`
  多段形式,而 Windows 预装的是 **5.1**,那一行直接报错。

- **启动器改读 `.registry/<name>.active` 纯文本 sidecar**(D35)。此前 shim 要自己
  解析 `<name>.ss` 里的 `(active "<v>")` —— sh 侧一段 awk、PowerShell 侧一段正则,
  两份实现、两份 bug 面,还让启动器与 registry 的文件格式绑死。现在 `install` /
  `switch` / `uninstall` 顺带维护一个单行文本文件,两边各一行读取即可。
  `.ss` 仍是唯一权威,`.active` 是它的派生投影。
- **`chandler doctor` 新增 `active-sidecar-drift` 检查**:sidecar 缺失、陈旧、
  或 lib 上有多余 sidecar,三种都报。
- **`bin/chandler.cmd`**:Windows 上的开发期入口(先前只有 sh 版)。
- **`bootstrap.ss` 的冒烟测试在 Windows 上不再跳过** —— 启动器成了可直接执行的命令,
  自举的最后一环于是在两个平台上都真的被验证。

- **子进程层按平台分派引用规则**(D33)。`shell-quote` / `env-prefix` / 工作目录切换 /
  `which` / `real-path` 在 Windows 上走 cmd.exe 的规则:参数用 `"` 包裹 + MSVCRT
  反斜杠规则、环境走 `set "K=v" && `、`cd` 带 `/d`(不带它跨盘符会静默不切过去)、
  `which` 走 `where.exe`。**git / native 构建 / pack / run / exec 全线经此。**

  无法安全传递的参数(字面 `"`、换行)**当场硬错**而不是悄悄传错 —— cmd 不认反斜杠
  转义,一个裸引号就让引号配对错位,后面的 `& | > ^` 变成 cmd 的控制字符。

- **`-j` 并行编译在 Windows 上退化为串行**(D37),并明确提示。cmd 没有「同时起 N 个、
  全部等完、汇总状态」的等价物;`-j` 是开发便利,不值得为它把 PowerShell 拉进依赖。

- **换行与字节一致性**(D38)。chandler 写文件改用显式 `(eol-style none)` 的
  transcoder,写什么字符就是什么字节,不再随平台的 `native-eol-style` 漂移;
  仓库根新增 `.gitattributes` 钉住 checkout 侧。两边都堵才管用 ——
  lock 的 `manifest-sha256` 与 install/pack 的 per-file sha256 都是**字节**指纹,
  写侧一旦漂移,跨平台协作时 `verify` 会持续假失败而两边文件「看起来」一模一样。

- **路径原语同时认 `/` 与 `\`**(D36)。Chez 在 Windows 上返回反斜杠形路径,
  而只认 `/` 的原语不会崩、只会**悄悄给出错误答案**。其中最要命的一处:
  `path-has-segment?` 认不出 `_build` / `.git` 段,于是 `chandler install` 的文件
  清单和 `chandler verify` 会把构建产物与仓库元数据当成受管文件收进去 ——
  全程不报错。`relativize` 也从裸前缀匹配改为按段比较,并把结果的分隔符归一到
  `/`(这些相对路径要写进 lock 并跨平台比对)。

- **临时目录认 `TEMP` / `TMP`**;git 缓存在 Windows 上落到 `%LOCALAPPDATA%`。

- **NTFS 名字可移植性检查**。保留设备名(`con`/`prn`/`aux`/`nul`/`com1-9`/`lpt1-9`,
  大小写不敏感且**带扩展名也算**)在 Windows 上 install 硬错、其它平台警告;
  只差大小写的包名(`Foo` vs `foo`)**所有平台都硬错** —— 那不是「Windows 上不行」,
  而是「这两个包在那里是同一个」,继续装必然互相覆盖。`chandler doctor` 两条都报。
  **不自动改名**:改名会让包名与磁盘路径失去对应,错误现场离原因更远。

### 修复

- **`rm-rf` 删不掉东西时不再假装成功**。此前遇到只读文件(Windows 上 git 的
  `.git/objects/**` 就是只读)或被占用的文件会静默留下残件,调用方以为清干净了,
  残件要到下一次操作才炸。现在先清只读位重试一次,仍失败则报错并说明原因。

  > 根因值得一记:Chez 的 `delete-file` / `delete-directory` **失败时返回 `#f`
  > 而不抛异常**。所以原先那圈 `ignore-errors` 其实什么都没接住 —— 静默不是它
  > 造成的,而它让代码**看起来**已经考虑过失败了。

- **`chandler run` / `deps` 等在临时目录不存在时不再死循环**。`make-temp-dir`
  先前对任何 `mkdir` 失败都重试,撞上不存在的临时目录根就会一直转;现在只在
  目标已存在时换名重试,其余原样抛,并给出「设 TMPDIR / TEMP / TMP」的可操作提示。
- **资源定位的路径穿越校验补上反斜杠**。`resource-path` / `find-resource-path`
  此前只拒绝含 `/` 的 segment,于是 `(resource-path '(app) "..\\..\\secret")` 能绕过
  全部四条检查 —— 反斜杠既不是 `/`、整串也不等于 `..`、更不是绝对路径。
  Windows 上 `\` 同样是分隔符,现在两者都拒。

### 升级注意

- **已装的包需要重装一次**。0.1.6 及更早版本装的包没有 sidecar,新启动器会退 70 并
  提示 `not installed, or installed by an older chandler; run: chandler install`。
  `chandler doctor` 会把它列为 `active-sidecar-drift`;重装或对该包
  `chandler switch` 一次即修复。
- **Windows 用户**:重装一次会把 `%LOCALAPPDATA%\chez\bin\<app>.ps1` 换成 `<app>.cmd`;
  `chandler uninstall` 会把残留的 `.ps1` 一并带走。
- `.cmd` 的固有限制(cmd 决定的,npm / yarn 的 Windows shim 同款):参数里含 `%`
  会被变量展开、未加引号的 `& | < > ^` 会破;`Ctrl+C` 会弹
  `Terminate batch job (Y/N)?`。

> **Windows 支持仍标注「未验证」** —— 子进程层(`proc.ss`)与路径原语尚未适配,
> 且还没有 Windows CI。进度见
> [designs/14-windows-portability.md](designs/14-windows-portability.md)。

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
