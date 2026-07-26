# 11 — CLI 命令面

> 状态: 已实现(v3 + v4),对齐 `chandler/cli/main.ss` 的 `command-table` 与 `chandler/cli/commands.ss` 的各 cmd-* 实现。
> v3 中心设计见 [06-installed-layout.md](06-installed-layout.md) §11,决策记录见 [TASK.md](../TASK.md)。

## 1. 一句话目标

统一的 CLI 命令集 + 全局旗标 + 标准化退出码,覆盖项目开发期(`init` / `add` /
`deps` / `build` / `run` / `repl`)和全局安装期(`install` / `uninstall` / `switch` /
`list` / `doctor` / `pack` / `verify-pack`)全部操作。

## 2. 命令一览

`chandler -T` 输出的 `commands:` 行与 `command-table` 是**唯一事实源**;加命令
只动 `chandler/cli/main.ss` 的 `(command-table ...)`,`list-tasks` 派生自它,
不会再出现「命令表列了但 `dispatch` 没接」或反之的不一致。

| 命令 | 作用 |
|------|------|
| `init [--lib\|--app] [--name=N]` | 生成骨架 `chandler-manifest.ss` + `chandler-tasks.ss`(默认 lib;`--app` 写 `(app …)`) |
| `add <name> <url> [--tag\|--rev\|--branch\|--path]` | 添加 git 依赖;`--path` 直挂源目录(不进 `_vendor/`) |
| `remove <name>` | 移除依赖 |
| `deps [--production] [--offline] [--force] [--update] [--list\|--tree]` | 解析 → 写 lock → git 依赖 checkout 到 `_vendor/`;`--list`/`--tree` 只读不写 |
| `build [--allow-build[=a,b]] [--verbose]` | 进程内编译依赖闭包 + native → 各 `_vendor/<dep>/_build/<mt>/` |
| `install [--user\|--system\|--prefix=DIR] [--force] [--adopt]` | 装项目库 + 依赖到全局前缀(中心 `.registry/` 登记);app 自动建命令行入口 `bin/<app>`(稳定 shim,D17)+ `.chandler/run.sps`(lock 驱动,D18) |
| `uninstall --name=<n> [--version=<v>]` | 干净卸载(`rm -rf <vroot>` + 更新 `.registry/` + 删 shim) |
| `list` | **列出全局已装包**(active 版本标 `[active]`;D16 中心 registry 读出) |
| `tree` | **`deps --tree` 的别名**:显示 lock 闭包 |
| `run --script <s.ss> [args…]` | 挂库搜索路径后跑脚本(锁驱动 per-dep `src::obj` 对) |
| `exec -- <cmd…>` | 设 `CHEZSCHEMELIBDIRS` + `.env` 后透传任意命令(D25 补实现) |
| `env` | 输出 `eval "$(chandler env)"` 友好的 `export CHEZSCHEMELIBDIRS=…` + `.env` 导出 |
| `repl [--runtime skiff\|chez]` | 交互 shell,自动挂库路径(项目优先 + 全局兜底) |
| `make [task]` | 跑 `chandler-tasks.ss` 的任务(`build` / `test` / …);自带 argv 语法,在 main 里先于解析转交子 CLI |
| `switch <name> <version>` / `--latest` / `--list` | **切换 app 的 active version**(D19);`--latest` 选该 name 最高 version(semver 数值序,D26) |
| `doctor` | 体检:见 §6 |
| `pack [--runtime r] [--out dir] [--name N] [--version V] [--entry '(<lib>…)'] [--main N] [--lib]` | 组装自包含分发包(app pack:payload + envelope;`--lib` 只打 payload) |
| `verify-pack [--target] <dir>` | 校验分发包(D24 严格化:files 字段必须含 `sha256`+`size`,EXTRA 致命) |
| `verify` | **CI 校验**:读 lock,扫 `_vendor/`,逐文件比对 `lock.(files ...)` sha256;MISSING/CHANGED/EXTRA → 65(D25 补实现) |

### 2.1 命令语义

#### init

```sh
chandler init [--lib|--app] [--name=N] [--entry '(<lib>…)'] [--main <sym>] [--force]
```

生成骨架 `chandler-manifest.ss` + `chandler-tasks.ss` + `.gitignore` + `.env`。
`--lib` / `--app` 互斥,都不传 = 默认 lib(无 `(app ...)`)。已存在则拒绝,
除非 `--force`。

#### deps

```sh
chandler deps [--production] [--offline] [--force] [--update]
chandler deps --list
chandler deps --tree   # = `chandler tree`
```

- 默认:解析 + 写 lock + git checkout 到 `_vendor/`
- `--list` / `--tree`:只读 lock,**不写**
- `--update`:删旧 lock 重解析;`--force`:覆盖已存在的 `_vendor/<dep>/`
- 顶层 **chandler 运行时门**(N5):`chandler-manifest.ss` 不含 `(chandler ">=X")`
  时 warning;`--strict` → 拒绝

#### build

```sh
chandler build [--allow-build[=a,b]] [--verbose]
```

按 lock 拓扑序就地编译 → 各 `_vendor/<dep>/_build/<mt>/`(进程内,不 spawn)。
native 需 `--allow-build`(绑构建描述哈希写入 `.chandler-approvals`,详见
[12-security.md](12-security.md))。

#### install

```sh
chandler install [--user|--system|--prefix=DIR] [--force] [--adopt]
```

- 装项目库 + 依赖到全局前缀(per-prefix 锁 + staging 整目录 promote + 中心
  registry 原子写,D20 + D21 + D22)
- app 自动建稳定 shim 启动器(`<bindir>/<app>` POSIX / `<bindir>/<app>.ps1` Windows)
  + `<vroot>/.chandler/run.sps`(lock 驱动挂精确 dep 版本,D17 + D18)
- 首次 install 自动设 active = 此 version;后续 install 不自动改 active
- 同 name 已装其他版本 → 新增 version 条目;同 version 重装 → 替换条目

详见 [04-install.md](04-install.md)。

#### uninstall

```sh
chandler uninstall --name=<n> [--version=<v>] [--keep-modified]
```

- 不带 `--version`:删 name 的所有 version + shim
- 带 `--version`:只删该 version;若它是 active,active 清空(下次启动报错)

#### switch(D19)

```sh
chandler switch <name> <version>
chandler switch <name> --latest
chandler switch --list
```

- `<name> <version>`:改 `.registry/<name>.ss` 的 `(active ...)`,shim 不重写
  (下次启动自动用新版本)
- `--latest`:选该 name 最高 version,**semver 数值序**(`major.minor.patch`,
  含 prerelease 排序,D26);不是字符串序(`9.9.0` < `10.0.0` 才正确)
- `--list`:列所有 app + 当前 active
- 切前校验:目标 version 已注册 + vroot 在盘上 + app 有 `.chandler/run.sps`
  (否则 `missing-vroot` / `missing-runner` 报错,D26)
- 同 name 已装其他版本时,**多版本共存**无需重装

#### pack

```sh
chandler pack [--runtime r] [--out dir] [--name N] [--version V]
              [--entry '(<lib>…)'] [--main <sym>] [--lib]
```

- app pack:payload + envelope(boot/<mt>/ + bundled runtime + 启动器)
- **D29**:创建走 temp sibling + rename(`<out>.tmp.<pid>/` → `<out>/`),失败
  不污染已存在的同名目录
- `--lib`:只打 payload,无 envelope
- entry 必须显式:manifest 的 `(app (entry …))` 或 `--entry`;都没有 → 拒绝

详见 [05-pack.md](05-pack.md)。

#### verify-pack(D24)

```sh
chandler verify-pack [--target] <dir|pack.manifest>
```

- pack.manifest 顶层必须是 `(pack ...)`(`expect-tag` 受控错,非 65)
- `(files ...)` 必须存在且非空;每 entry 必须 `(rel sha256 size)` 三件套
- 完整性:MISSING / CHANGED / INVALID / **EXTRA 全部计入 bad**(EXTRA 致命,
  v2/v3 只报告不致命)
- `--target`:machine-type / chez-version / skiff-version|skiff-compat 三维比对
- 返回 bad = 0 → 0;bad > 0 → 65;format 太新 → 70;target 不符 → 78

## 3. 全局旗标

| 旗标 | 说明 |
|------|------|
| `-C <dir>` | 切工作目录(`current-directory` 之前) |
| `--offline` | 离线模式(只从缓存) |
| `--production` | 跳过 dev-deps |
| `--force` | 强制覆盖(同 version 重装 / `deps` 覆盖 `_vendor/`) |
| `--allow-build[=<libs>]` | 授权 native 构建(可指定库名列表) |
| `--keep-extra` | 保留 vendor 中非 lock 来源的目录 |
| `--verbose` | 详细输出 |

> v2 删:`--allow-prebuilt-native`(prebuilt 在 resolve 阶段已显式报错,
> D27 — schema-允许但实现暂缓的备选不需要这面旗)。
> v2 删:`list --global` / `doctor --global`(`list` / `doctor` 本身就是全局语义)。

## 4. 环境变量

| 变量 | 作用 |
|------|------|
| `CHANDLER_HOME=<dir>` | chandler runtime prefix;启动器自动设,一般不用管 |
| `CHANDLER_RUNTIME=skiff\|chez` | 选**哪一种**运行时;非法值 → 退出码 64,不静默忽略 |
| `CHANDLER_SKIFF=<exe>` | skiff 可执行文件(名或路径);找不到即 127 不回退 |
| `CHANDLER_SCHEME=<exe>` | Chez 可执行文件(名或路径);找不到即 127 不回退 |
| `CHEZSCHEMELIBDIRS` | 库搜索路径(`run` / `repl` / `exec` / `env` 自动设,格式见 [06 §3](06-installed-layout.md)) |
| `SKIFF_ALLOW_VERSION_SKEW=1` | `verify-pack --target` / `run.sps` 启动期放宽 skiff-version 维(只放宽这一维) |

### 4.1 运行时优先级

`run` / `exec` / `repl` / **启动器** / **bootstrap 安装脚本** 共用一套:

```
--runtime 旗标  >  CHANDLER_RUNTIME  >  manifest(明确 chez-only→chez / skiff-only→skiff)  >  默认:跟随 chandler 当前所在(默认 skiff)
```

**显式覆盖照单执行**:指定了 `CHANDLER_SKIFF` / `CHANDLER_SCHEME` 就只用它,
找不到即失败,**不**静默回退。**自动发现**则需能力探测:名为 `skiff` 的候选
须真跑一段 R6RS 程序并以 `(skiff-version)` **自证是 skiff** 才会被选中,
避免一个能跑程序但不是 skiff 的同名可执行文件被误用。

## 5. 退出码(sysexits 风格)

| 码 | 常量 | 含义 |
|----|------|------|
| 0 | `EX_OK` | 成功 |
| 64 | `EX_USAGE` | 用法错误(参数错、非法旗标、缺少必需参数) |
| 65 | `EX_DATAERR` | 数据错(manifest/lock 格式错、doctor/verify/verify-pack 失败、`add`/`remove` 操作失败) |
| 66 | `EX_NOINPUT` | 文件不存在(`chandler-manifest.ss`、`chandler-manifest.lock` 等) |
| 70 | `EX_SOFTWARE` | 内部错 / install 损坏(运行时不兼容;启动器发现失败) |
| 73 | `EX_CANTCREAT` | 冲突,无法创建(目录冲突、文件已存在且 `--force` 未指定) |
| 77 | `EX_NOPERM` | 权限不足(prebuilt / native 未授权;锁目录创建失败) |
| 78 | `EX_CONFIG` | 配置错(`verify-pack --target` 三元组不符) |
| 127 | — | 找不到 runtime(skiff/scheme 不在 PATH,且未显式覆盖) |

> v3 调整:`verify` / `doctor` / `verify-pack` / `switch --latest`(lock 解析错)
> 都归 **65 EX_DATAERR**;`prebuilt` 不再单独占 77,改 D27 在 resolve 阶段
> 显式报错 → 65。

## 6. `chandler doctor` 检测项

`doctor` 直扫 `<libdir>/.registry/*.ss`(用 `list-registry-files`,不解析不过滤),
逐个自己解析(D23);坏文件必须变成 `malformed-registry` issue,不能被
`list-registered-names` 剔掉。返回 issue 列表 = 0 时退出 0,否则 65。

| Issue 类型 | 触发 |
|-----------|------|
| `malformed-registry <path> <err>` | `.registry/<name>.ss` 不可读 / 解析失败 |
| `name-filename-mismatch <file> <name>` | `.registry/foo.ss` 内 `(name bar)`,名字与文件名不一致 |
| `duplicate-version <name> <version>` | 同 name 重复登记同一 version 字符串 |
| `kind-mismatch <name> <existing> <incoming>` | 已登记 kind 与 incoming kind 不一致(install 时也会拦) |
| `missing-vroot <name> <version>` | registry 记了 version 但盘上 `<libdir>/<name>/<version>/` 不存在 |
| `missing-runner <name> <version>` | app 在 registry 但 `<vroot>/.chandler/run.sps` 不存在 |
| `missing-active <name> <active>` | `(active "<v>")` 指向的 vroot 不存在 |
| `orphan-vroot <name> <version>` | 盘上有 `<libdir>/<name>/<version>/` 但 registry 未登记 |
| `stale-staging <path>` | `<libdir>/.registry/staging/<name>/<version>/` 有残留(某次 install 中断) |

每个 issue 一行,stderr 输出:`  <type> <args...>`,末尾 `doctor: N issue(s) found`。
用户按类型决定修复动作(补装 / 卸载 / 删 staging / 修 registry),无自动修复。

## 7. 版本输出格式

```sh
$ chandler --version
chandler <ver> (<runtime> <ver>) (<chez> <ver>)
```

```
$ chandler --version
chandler 0.1.4 (skiff 0.1.2) (chez 10.4.1)   # 跑在 skiff 上
$ CHANDLER_RUNTIME=chez chandler --version
chandler 0.1.4 (chez 10.4.1)                  # 跑在标准 Chez 上
```

> skiff 自 0.1.1 起以内置 `(skiff-version)` 自证版本,故 skiff 上能精确报出;
> Chez 版本恒报。

## 8. 用户可见输出语言

CLI 帮助、错误消息一律**英文**。风格取 Unix 诊断惯例:**小写、简短、不加句号**。

```
chandler-manifest.ss not found; run `chandler init` first
invalid CHANDLER_RUNTIME (want: skiff|chez)
no Scheme runtime found (install skiff or Chez Scheme)
```

> 源码注释(`;;` / `;;;`)与本仓文档保持中文;仅**用户可见输出 + 生成物**头注释
> 用英文。详见 README「语言约定」一节。

## 9. 子命令帮助

```sh
chandler help                    # 列命令清单(usage)
chandler <cmd> --help            # 各命令的具体旗标
chandler -T                      # 只列命令名(派生自 command-table)
```

## 10. 与 v2 的命令面差异

| 命令 | v2 | v3 + v4 |
|------|----|---------|
| `init` | 默认 app | 默认 lib;`--app` 显式声明 |
| `add` | git + `--prebuilt` | git only;prebuilt 在 resolve 报错(D27) |
| `install <pack.tar.gz>` | 支持 | **删**:prebuilt 暂缓 |
| `list` | "已锁依赖" + `--global` 二义 | "全局已装包"(D16);locked deps 用 `deps --list` |
| `tree` | 全局 deps tree | `deps --tree` 的别名(D25) |
| `switch` | — | **新**(D19) |
| `verify` | — | **新**(D25):`_vendor/` 与 lock 一致性 |
| `exec` | — | **新**(D25):`CHEZSCHEMELIBDIRS` + `.env` 后透传命令 |
| `doctor` | sha256 漂移(per-version) | center registry + 多 issue 类型(D23) |
| `verify-pack` | EXTRA 只报告 | **致命**(D24);`files` 字段强制含 `sha256`+`size` |
| `install --allow-prebuilt-native` | 旗标 | **删**:prebuilt 暂缓 |
| `uninstall --keep-modified` | — | 保留 user 改过的源文件(新) |

## 相关文档

- [06-installed-layout.md](06-installed-layout.md) §11 — v3 CLI 命令总表
- [04-install.md](04-install.md) — `install` 详细流水线(per-prefix 锁 / staging / 原子写)
- [05-pack.md](05-pack.md) — `pack` / `verify-pack` 详细流水线
- [08-launchers.md](08-launchers.md) — 启动器与 `--program run.sps` 交接
- [09-runtime-paths.md](09-runtime-paths.md) — `resource-path` / `find-resource-path` + method B
- [10-dev-mode.md](10-dev-mode.md) — dev 模式命令(`run` / `repl` / `exec` / `env`)
- [12-security.md](12-security.md) — `--allow-build` 授权模型