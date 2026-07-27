# 00 — 设计原则与核心模型

> 本文是 Chandler 的"宪法"。所有其他设计文档必须遵守本文的不变量与术语。本文优先级最高;冲突时以本文为准。
>
> **v3 + v4 当前权威**。v2 是历史(D1–D7 仅作决策沿革展示),v3 增量 D13–D19,v4 增量 D20–D30。

## 1. 一句话定位

Chandler 是 **git-first** 的 Chez Scheme 包管理器。它把 R6RS 库装进**版本化中央仓库**,以**中心 `.registry/` + 稳定 shim 启动器 + lock 驱动 `run.sps`** 让每个已安装的 app 在运行时精确锁定自己依赖的版本,与 Bundler 模型同构但少一层间接。

- **Skiff**(轻舟)= 运行时(Chez + libuv)
- **Chandler**(船具商)= 包管理器 + 构建器,管**依赖获取、编译、安装、打包、激活**
- **bake** = 编译引擎,被 chandler 内嵌消费(已合入 `chandler-tasks.ss`,无独立二进制)

启动入口收口至**两条路**:

- **项目期**:`chandler run <script>` 实时算 `resolved-libdirs` + `--libdirs` 交给子进程,无中间 artifact。
- **全局期**:启动器(`~/.local/bin/<app>`)= **稳定 shim**(D17),运行时读 `<libdir>/.registry/<name>.ss` 找 active,把 control 交给 `<vroot>/.chandler/run.sps`(D18,lock 驱动精确挂 `library-directories`)。

dev 模式由 `chandler run` 直接交接,**无 setup 层、无 chandenr-setup.ss**;已安装 app 走启动器 shim + lock 驱动 run.sps,同构。

## 2. 源模型:git 为单一本机源(D12 暂缓)

依赖的来源在 manifest 里用 `source` 字段表达:

| 源 | 形式 | 编译 |
|----|------|------|
| **git**(默认且唯一实装) | `(git "<url>")` + tag/rev/branch pin | chandler build 在本地编译 |
| **prebuilt**(D12 暂缓) | `(prebuilt (mt <mt> (url "<url>") (sha256 "<hex>")) ...))` | 中央仓库已编译,client 只下载解包 |

**git 是默认且本机实现的唯一源**。`prebuilt` 在 schema 里仍合法(老 manifest 不破),但 resolve 阶段**显式报错** `prebuilt source not yet supported; use git`(D27)——关掉之前静默吞掉形成的后门,补实现是 v5 范畴(见 §11)。

两者产物**字节级一致**(见 §4.4),区别只在 lock 的 `(source ...)` provenance 字段。

## 3. 核心抽象:Versioned Package

Chandler 的一切操作围绕一个核心抽象 —— **versioned package**:

- 三元组 `(name, version, mt)` 唯一标识一份已编译的库/app 实例
- 每个 versioned package 是**自包含的** —— 独立可装/可卸/可 pack
- name 是 R6RS library name 的顶层标识符(`(mylib)`、`(http)`)
- version 是 semver 字符串(`"1.2.0"`),从 git tag 或 manifest 显式声明得来
- mt 是 Chez machine-type(`ta6le`、`a6le` 等),ABI 绑定

**多版本共存语义**:

- **文件系统层**:支持。中央仓库可同时存 `http/1.2.0/` 与 `http/2.0.0/`,app 各自指向;`chandler list / switch` 操作这些 version(D19)。
- **进程内**:仍是硬单版本(继承 R6RS 约束)。每个 app 的 `run.sps` 只挂自己 lock 声明的版本对(D18),互不干扰。

**Registry 中心化**(I3 v3):`<libdir>/.registry/<name>.ss` 是每个 name 的**单一真相源**,记录该 name 的所有 version + active + 安装元数据。`list` / `switch` / `doctor` / 启动器 shim 全走它。无 per-version registry、无 index 派生缓存。

## 4. Unified Layout v3

### 4.1 libdir(install 落点)

```
<libdir>/                                    例:~/.local/share/chez/
├── .registry/                               中心注册表(D16)
│   ├── <name>.ss                            每 name 一份,管 versions + active
│   └── staging/                             事务暂存,从 version root 挪出
│       └── <name>-<version>/                install 期间的临时树,成功后整目录 promote(D22)
│
├── <name>/                                  例:myapp、mylib
│   └── <version>/                           version root(I1:自包含)
│       ├── src/
│       │   ├── <name>.ss                    库入口源码
│       │   └── <name>/                      子库 + 资源同居(D13 method B)
│       │       ├── <sub>.ss
│       │       └── resources/               该库的资源(method B)
│       │           └── <file>
│       ├── <mt>/                            例:ta6le
│       │   ├── <name>.so                    编译对象
│       │   └── <name>/*.so                  子库对象
│       └── .chandler/
│           ├── chandler-manifest.ss         此 lib 的清单快照(D14 命名)
│           ├── chandler-manifest.lock       闭包 + files+sha256(D15,吸收 v2 registry)
│           └── run.sps                      app 才有(D18 lock 驱动)
```

**已删除**(v2 → v3):

- `<root>/.chandler/format.ss`(format 进入 `<name>/<version>/.chandler/chandler-manifest.ss` 或留作 plan)
- `<root>/.chandler/registry/index.ss`(派生缓存,被中心 `.registry/` 取代)
- `<vroot>/.chandler/registry.ss`(per-version files+sha256,被 lock 的 `(files ...)` 吸收,D15)
- `<vroot>/.chandler/source.ss`(provenance 进入 lock 的 `(source ...)` 与 `.registry/<name>.ss` 的 `versions.<v>.source`,D15)
- staging 残留路径(挪进 `<libdir>/.registry/staging/`,D22)

### 4.2 bindir(命令行入口)

**POSIX**(遵循 XDG,不在 libdir 内):

```
~/.local/bin/
└── <app>                                    稳定 shim,读 .registry/ 找 active(D17)
```

**Windows**(在 libdir 内):

```
%LOCALAPPDATA%\chez\bin\
└── <app>.ps1                                PowerShell shim,同上
```

### 4.3 Envelope(仅 app pack 根追加)

```
<pack-root>/                                = <out>/<name>-<version>-<mt>/
├── bin/
│   ├── <app>[.ps1]                          pack 启动器(指 bundled runtime)
│   └── <mt>/<runtime>[.exe]                 bundled skiff/scheme
├── boot/<mt>/*.boot                         bundled boot 文件
│
├── <name>/<version>/                        payload —— 与 install 字节级一致(I2)
│   ├── src/
│   │   ├── <name>.ss
│   │   └── <name>/resources/                资源随源码(D13 method B)
│   ├── <mt>/                                对象树(过滤 .bake-manifest/.wpo)
│   └── .chandler/
│       ├── chandler-manifest.ss
│       ├── chandler-manifest.lock           pack 不写 .registry/(部署态无需事务)
│       └── run.sps                          pack 模式:追加 verifier + native walk
│
├── <dep-name>/<dep-version>/...             各 dep 的 payload(同构)
├── chandler/<chandler-ver>/                 chandler 运行时门(独立 namespace)
│
└── pack.manifest                            pack 根级元数据
```

**libdir / `_vendor/` 永不带 envelope**。envelope 只在独立 app pack 出现。

### 4.4 四态字节级一致性(I2 v3 真正成立)

| 形态 | 根 | payload(`<name>/<version>/{src,<mt>,.chandler}/`) | envelope |
|------|----|------|----------|
| 中央仓库 install | `<libdir>/` | ✓ | `.registry/` + `bin/<app>`(POSIX)/ `bin/<app>.ps1`(Win) |
| 项目 `_vendor/` | `<project>/_vendor/<dep>/` | ✓(live) | — |
| App pack 解开 | `<pack-root>/` | ✓ | `bin/` + `boot/` + `pack.manifest` |
| Lib pack 解开 | `<lib-pack-root>/` | ✓ | — |

`<name>/<version>/{src,<mt>}/.chandler/{chandler-manifest.ss, chandler-manifest.lock}` 在四态下字节级一致。`.chandler/run.sps` 内容按模式略不同(install / pack),合理。

## 5. 六条不变量

所有其他设计文档必须满足:

### I1. Version 自包含

每个 `<name>/<version>/` 是独立可装/可卸(`rm -rf`)/可 pack(`tar` 子树)的单位。卸载一个 version 永不留下孤儿文件。

### I2. Payload 字节级统一

install / pack / lib-pack / `_vendor/` / prebuilt 解包产出结构相同的 `<name>/<version>/{src,<mt>,.chandler/}`。payload 对容器无感。**v3 真正成立**(v2 有 4 处不一致已修复)。

### I3. Registry 中心化(D16 取代 v2 I3)

- `<libdir>/.registry/<name>.ss` 是 name 的所有 versions + active + 安装元数据的**唯一真相源**。
- **不再有** per-version `registry.ss`,也不再用派生 index 缓存。
- 读写操作:**原子**(temp + rename + fsync,D20),**互斥**(`<libdir>/.registry/.lock` 目录锁,D21)。
- 启动器 shim、`chandler list`/`switch`/`doctor`、`uninstall` 全走 `.registry/<name>.ss`。

### I4. Envelope 仅 app pack

`bin/` / `boot/` / `chandler-runtime/` / `pack.manifest` 只在独立 app pack 出现。libdir、`_vendor/`、lib pack 永不带。**lib pack = payload only,app pack = payload + envelope**。

### I5. Provenance 记录(D15 调整承载点)

- **lock** 的 `(files ...)`(相对 `<vroot>` 路径 + sha256)+ lock 的 `(deps ... (source ...))` + `.registry/<name>.ss` 的 `versions.<v>.source` 三处协作记录:文件级 hash + 依赖来源 + 安装元数据。
- **不再**有 `<vroot>/.chandler/source.ss`(v2 形态)。
- 支持安全审计、复现、mt-gating。

### I6. 原子性与互斥(D20 + D21)

- **原子写**:`.registry/<name>.ss` 与其他 `.ss` 文件写入走 `temp + rename + fsync`(temp 必须与目标同目录,保证 rename 原子)。v4 pack 创建也走 temp sibling + rename(D29)。
- **进程互斥**:`install`/`uninstall`/`switch` 在 `<libdir>/.registry/.lock` 目录锁下串行执行。锁用 `create-directory` 原子性抢占 + 指数退避 + 超时 + staleness 检测(pid 不活且超阈值即强抢)。
- 留给使用者的语义:**同一 libdir 同时只能跑一个写操作**;读操作不受影响。

## 6. 三种运行模式(无 `(chandler setup)` 列)

| 模式 | 触发 | 库定位机制 | 启动器 |
|------|------|----------|--------|
| **dev** | `chandler run <script>` 在项目根 | 实时算 `resolved-libdirs`(per-dep `(src . obj)` 对),`--libdirs` 传给子进程 | — |
| **install** | `~/.local/bin/<app>` 启动器 | shim 读 `.registry/<name>.ss` 找 active;`<vroot>/.chandler/run.sps` 读 lock 构造 `library-directories` | 稳定 shim |
| **pack** | 解开的 pack 的 `bin/<app>` | 同 install,但 run.sps 进入 pack 模式(加 verifier + native walk) | 启动器指向 bundled runtime |

dev/install/pack **三条路径都不依赖 `(chandler setup)`**(D4 取消):dev 由 `chandler run` 直接交接;install/pack 由启动器 shim + run.sps 完成同构工作。

## 7. 启动器与 run.sps(取代原 Bundler §7)

启动模型两点核心:

1. **稳定 shim 启动器**(D17)
   - `install` 生成一次,后续 `install` / `switch` / `doctor` / `uninstall` **永不重写**。
   - 运行时读 `<libdir>/.registry/<name>.ss` 解析 `(active "<v>")`,交接给 `<vroot>/.chandler/run.sps`。
   - `chandler switch` 只改 `.registry/<name>.ss` 的 `(active ...)`,所有新进程**立即**用新版本;老进程不受干扰(已挂 lock 不变)。

2. **lock 驱动的 run.sps**(D18)
   - 位置:`<vroot>/.chandler/run.sps`(**仅 app 有**,lib 不生成)。
   - 读 `chandler-manifest.lock` → 把自己 + lock 声明的每个 dep 的精确 version 挂上 `library-directories`(每条 `(src . obj)` 对)。
   - install 与 pack 两套 run.sps 内容略不同(pack 模式追加 verifier + native walk + runtime 检测)。

**Bootstrap paradox 解决**(lib 同 setup 的悖论):pack 在 envelope 里 `chandler-runtime/` bundle 一份 chandler;启动器先以 Chez 原生 `--libdirs` 指向它,让运行时能跑起来;之后再由 run.sps 接管挂 lock 库路径。install 模式则用宿主系统的 chandler。

dev 模式**完全不走 run.sps**:无 lock 由项目维护,`chandler run` 直接 `--libdirs` 传子进程即可。

## 8. 跟 R6RS / Chez 的关系

| 事项 | R6RS / Chez | Chandler |
|------|------------|---------|
| 多版本共存(同进程内) | **禁止**(import 路径抛异常) | 单进程内仍然单版本(继承 R6RS 约束) |
| 多版本共存(文件系统) | 不规定 | 中央仓库支持多 version 共存(`.registry/<name>.ss` 管) |
| 版本选择(import 时) | 仅 `and`/`or`/`not` + 精确 + prefix | 不用 Chez version ref,完全由 `run.sps`(lock 驱动)/`chandler run`(实时算)构造 `library-directories` |
| 版本号格式 | 整数列表 `(1 0 0)` | 字符串 semver `"1.0.0"`(在 path component 与 registry 内使用) |
| library-directories | list of `(src . obj)` | 直接复用,run.sps / `chandler run` 构造这个 list |

Chandler **不依赖** R6RS library version reference 语法。版本选择完全在 Chandler 层(resolve + run.sps/shim),R6RS library 声明不带 version annotation。

## 9. 术语表

| 术语 | 定义 |
|------|------|
| **libdir** | 库前缀,如 `~/.local/share/chez/`(POSIX)、`%LOCALAPPDATA%\chez`(Windows)。中心 `.registry/` 所在地 |
| **bindir** | 命令行入口目录,如 `~/.local/bin/`(POSIX);Windows 在 libdir 内 `chez/bin/` |
| **prefix** | 任何能被解析为 §4.1 根布局的目录(libdir / pack-root / `_vendor/`) |
| **version root**(**vroot**) | `<libdir>/<name>/<version>/`,自包含的 mini-prefix(I1) |
| **中心 registry** | `<libdir>/.registry/`,管 installed name 的所有 version + active + 写锁(I3、D16、D21) |
| **per-version lock** | `<vroot>/.chandler/chandler-manifest.lock`,含闭包 + `(files ...)` 文件清单 + sha256(D15) |
| **active version** | app 在 `.registry/<name>.ss` 的 `(active "<v>")`,决定 `bin/<app>` 指向哪个 vroot 的 run.sps |
| **shim launcher** | 稳定启动器(§10),跨 install/switch 不变,运行时读 `.registry/<name>.ss` |
| **payload** | `<name>/<version>/` 子树,所有形态字节级一致的部分(I2) |
| **envelope** | app pack 根额外追加的 `bin/`、`boot/`、`chandler-runtime/`、`.chandler/pack.ss`(I4) |
| **versioned package** | `(name, version, mt)` 三元组对应的实例,即一个 `<name>/<version>/` 目录 |
| **mt** | Chez machine-type,如 `ta6le`(threaded x86_64 LE)、`a6le`(ARM64 LE) |
| **resolve** | 从 manifest 计算 `chandler-manifest.lock` 的过程 |
| **materialize** | 把 lock 里的 dep 落地为文件系统上的 `<name>/<version>/` |
| **provenance** | 来源记录:lock 的 `(files ...)`(文件级 sha256)+ lock 的 `deps.(source ...)` + `.registry/<name>.ss` 的 `versions.<v>.source`(v2 的 `<vroot>/.chandler/source.ss` 不复存在) |
| **self-contained** | 一个目录不依赖外部环境即可工作(version 自包含、pack 自包含) |
| **(chandler setup)** | **已取消**(D4)。请改用"启动器 shim + run.sps"或"dev 模式 `chandler run`" |

## 10. 设计决策记录

### 10.1 v2 历史(D1–D12)

| # | 决策 | 状态 | 备注 |
|---|------|------|------|
| D1 | `.chandler/` 进 version 目录(`<name>/<version>/.chandler/`) | 历史 | 仍成立 |
| D2 | pack = install --prefix + envelope(app pack) | 历史 | 仍成立 |
| D3 | lib 可 pack(`--lib`) | 历史 | 仍成立 |
| D4 | `(chandler setup)` 走 Bundler 模型 | **撤销** | 改为启动器 shim + run.sps(本文 §7) |
| D5 | pack bundle chandler-runtime | 历史 | 仍成立(解决 bootstrap paradox) |
| D6 | mt 嵌套(`<name>/<version>/<mt>/`),非复合 key | 历史 | 仍成立 |
| D7 | 不考虑老版本兼容(v2.0 是 breaking) | 历史 | 仍成立 |
| D8 | 去除 `APP_ROOT` 环境变量 | 历史 | 资源定位不依赖环境变量(走 library-directories) |
| D9 | `manifest.ss` → `chandler-manifest.ss` | 历史 | 已被 D14 接续 |
| D10 | 统一 runner `run.sps` | 历史 | 仍成立(在 v3 经 D18 强化为 lock 驱动) |
| D11 | install resources 落点 fix | **撤销** | v3 改用 method B(D13),不再单独拷资源 |
| D12 | prebuilt 实现 | **暂缓** | schema 仍允许,resolve 阶段显式报错(D27);v5 重启 |

### 10.2 v3 增量(D13–D19)

| # | 决策 | 状态 | 理由 |
|---|------|------|------|
| D13 | 资源 method B:`<src>/<libpath>/resources/` | ✅ | libpath 已在库名里,资源与源码同居;manifest 删 `(resources ...)` 字段 |
| D14 | 文件命名统一 `chandler-` 前缀 | ✅ | `chandler-manifest.lock` 与 `chandler-manifest.ss` 命名空间一致 |
| D15 | lock 吸收 registry 的 `files+sha256`(Method Y) | ✅ | `<vroot>/.chandler/` 只剩 manifest + lock + run.sps;`<vroot>/.chandler/source.ss` 删 |
| D16 | 中心 `.registry/<name>.ss` 管 versions + active | ✅ | 多版本共存、切换、list/doctor 的单一真相源 |
| D17 | 启动器 = 稳定 shim,运行时读 `.registry/` | ✅ | switch 不需重写 launcher;瞬时生效 |
| D18 | `run.sps` lock 驱动 library-directories | ✅ | 多版本 lib 共存时,各 app 挂自己 lock 声明的版本,互不干扰 |
| D19 | `chandler switch` 命令 | ✅ | 多版本管理的用户入口 |

### 10.3 v4 增量(D20–D30)

| # | 决策 | 状态 | 理由 |
|---|------|------|------|
| D20 | registry 原子写(temp + rename + fsync) | ✅ | temp 必须与目标同目录以保 rename 原子;写中崩溃不破坏 `.registry/<name>.ss` |
| D21 | per-prefix 进程锁(`<libdir>/.registry/.lock` + staleness) | ✅ | 用 `create-directory` 原子性抢占;指数退避 + 超时;过期强抢;写操作串行 |
| D22 | staging promote 改整目录单次 rename | ✅ | 避免逐文件 move 在中途崩溃造成半截 vroot;`staging/<name>-<version>/` 整目录挪到 `<libdir>/<name>/<version>/` |
| D23 | doctor 重写:直扫 `.registry/*.ss` + 多种 issue | ✅ | 不再依赖过滤列表;新增 malformed-registry / orphan-vroot / kind-mismatch / name-filename-mismatch / duplicate-version / missing-runner |
| D24 | verify-pack 严格化 | ✅ | 强制顶层 `(pack ...)` tag + `(files ...)` 非空且每项带 `sha256`+`size`;`EXTRA` 文件 fatal |
| D25 | 补实现 `chandler verify` 与 `chandler exec` | ✅ | verify 是 CI 关键;exec 是常见操作。`tree` 作为 `deps --tree` 别名收口 |
| D26 | install kind 校验 + switch 验 vroot + `--latest` semver | ✅ | 同名 lib/app kind 冲突报错;switch 到无 vroot / 无 run.sps 的版本报错;`--latest` 走数值序 |
| D27 | prebuilt 在 resolve 阶段显式报错 | ✅ | 关掉静默半开后门,推进用户用 git;schema 仍允许旧 manifest 不破 |
| D28 | 重写本文档(00-design-principles.md)对齐 v3+v4 | ✅ | 本任务 |
| D29 | pack 创建改 temp sibling + rename | ✅ | 包构建中崩溃不污染同名旧包;与 D20 同思路 |
| D30 | registry 格式迁移路径(D8 范畴) | 暂缓 | 目前只认 `format 1`;升级函数占位,实现推 v5 |
| D31 | dev 期全局兜底每包只挂一个版本(app 取 `active`,lib 取最高 semver) | ✅ | 先前挂全部版本,生效的是「最后登记的那个」——偶然结果,且让 `chandler switch` 在 dev 期完全失效(见 [06 §9.5](06-installed-layout.md)) |
| D32 | D15 生产侧:`chandler deps` 写 lock 的 `(files …)`,基准 = 项目根 | ✅ | 依赖树校验没有单一 `<vroot>` 可作基准;`.git/` 与 `_build/` 三处排除规则必须一致(见 [11 §verify](11-cli.md)) |

## 11. 不在本设计范围

明确**不解决**的问题:

- **远程 registry server**(crates.io / hex.pm 那种)—— Chandler 是 local-only,git URL 即"索引";prebuilt 通过 URL 直链下载,不经过中心索引服务。
- **跨平台 pack**(一个 pack 多 mt)—— per-mt pack,跨平台由 CI 分别构建。
- **自动升级**(lock 变化触发 auto install)—— 拒绝 Bundler 的 auto-upgrade,显式 `install`。
- **内容寻址存储**(content-addressed store,Nix 式)—— 接受重复,Scheme 库体积小,disk 便宜;sha256 漂移靠 `chandler verify` 兜底。
- **Chez library version annotation**(`(library (foo (1 0 0)) ...)`)—— 不用,版本完全在 Chandler 层。
- **prebuilt 远程分发**(v5 范畴)—— D12 暂缓,D27 关掉旧后门;真要分发走 git + CI。
- **registry 格式自动迁移**(D30 占位)—— 当前只认 `format 1`;遇到老格式不静默升级,需手工重装或调用升级函数(实现中)。
- **lock 自动 resolve**(auto-update on `chandler deps`)—— 拒绝;用户显式 `add` / `update`。

## 相关文档

- [README.md](README.md) — 所有设计文档的索引
- [06-installed-layout.md](06-installed-layout.md) — v3 中心设计(目录布局 + registry 形态 + lock schema)
- [01–12 各专项设计](README.md)— 详见索引;本文为它们的共同宪法
