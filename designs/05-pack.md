# 05 — pack = install --prefix + envelope

> 状态: 已实现(v3 + v4 健壮性),对齐 `chandler/pack.ss`。
> v3 中心设计见 [06-installed-layout.md](06-installed-layout.md),决策记录见 [TASK.md](../TASK.md)。

## 1. 一句话目标

pack 把闭包物化为**自包含分发包**:payload 与 `chandler install` 走**同一条管线**
(I2 by construction),app pack 在其上追加 envelope(bundled runtime + boot + 启动器
+ pack.manifest)。包布局仿 `~/.local/{share/chez,bin,lib}` 的 FHS 形状 —— pack 解开
就是一个自带运行时的安装前缀,不存在「pack 专用」的第二套路劲规则。

## 2. 核心等式:D2 决策

```
pack = install --prefix=<pack>/share/chez + envelope
```

- **阶段 1(payload)**:`install-project-payload!`(与 `cmd-install` 同一函数),
  `register?=#f` → 走 `install-payload-global`(直拷,无 staging、无 `.registry/`)。
  注册表是安装机私有状态(含构建机绝对路径),不进可再分发包。
- **阶段 2(envelope,仅 app pack)**:pack 模式 run.sps + bundled runtime exe →
  `bin/` + boot → `lib/chez/` + 启动器 → `bin/<app>` + `pack.manifest`。

## 3. 包布局(FHS 式)

平台绑定物集中在两处:`boot/<mt>/*.boot` 与各 vroot 的 `<mt>/` 层。`<mt>` 已在
包目录名里(`<name>-<version>-<mt>`),bin/boot 下**不再**嵌 `<mt>` 层——`boot/<mt>/`
只走一次 mt 分类(同 `ta6le/`、`a6le/` 之类一份一份摆齐)。

```
dist/<name>-<version>-<mt>/
  bin/
    <app>                  ← POSIX 启动器(sh,稳定 shim 风格;指 bundled runtime)
    <app>.ps1              ← Windows 启动器(PowerShell)
    <runtime>[.exe]        ← bundled runtime 可执行文件(skiff / scheme / petite)
  boot/<mt>/               ← 与各 vroot 的 <mt>/ 对齐
    petite.boot [+ scheme.boot] [+ skiff.boot]
  share/chez/              ← payload 根(= install 的 libdir)
    <name>/<version>/
      src/                 ← 源码 + 资源(method B:资源随源码树自动落位)
        <name>.ss
        <name>/**(含 resources/)
      <mt>/                ← 编译产物 + native(ABI 绑定)
        <name>.so
        <name>/**
      .chandler/
        chandler-manifest.ss   ← 应用清单快照(无源清单时合成最小清单)
        chandler-manifest.lock ← lock 快照(run.sps 挂 dep 的依据;零依赖项目可无)
        run.sps                ← 入口 runner(pack 模式,见 §5)
    <dep>/<pin-val>/       ← 依赖闭包,版本目录名 = lock 的 pin val
      src/  <mt>/
    chandler/<chandler-ver>/ ← chandler runtime 子集(运行时门;独立 namespace)
  pack.manifest            ← 包元数据 + 目标三元组 + native 清单 + files+sha256
```

**lib pack(`--lib`)无 envelope**:只有 `share/chez/` payload(也装在 `share/chez/`,
与 app pack 同根),到阶段 1 为止。

## 4. payload 与 install 完全一致(I2 不变量)

- app 自身:`enumerate-lib` 枚举(`<name>.ss` + `<name>/**` → `src/`;`_build/<mt>/`
  deliverables → `<mt>/`)— 与 install 同一文件集,字节级一致。
- 依赖:`merge-lib-to-global!` 逐 dep 从 `_vendor/<dep>/` 拷源码树(除 `_build`/`.git`)
  + `_build/<mt>/` 对象 → `share/chez/<dep>/<pin-val>/{src,<mt>}/`。版本目录名 =
  `locked-dep-pin-val`(branch pin → 分支名,tag pin → tag 名)。
- 资源:v3 method B(D13),`<src>/<libpath>/resources/` 与库源码同居,随源码树拷贝
  自动落位 —— pack 不需要任何资源专用代码。
- chandler runtime 子集:manifest 声明 `(chandler "<range>")` 时,从
  `_vendor/chandler/_build/<mt>/` 取(deps 期已就地编译,与 build 同源 → 编译实例
  一致,不会 "different compilation instance"),装进 `share/chez/chandler/<version>/`。

## 5. 统一 runner run.sps(install/pack 共用)

`run-sps-content` 生成单份 runner,install/pack 仅差 pack 追加段:

1. **根推导**:run.sps 恒在 `<libdir>/<name>/<version>/.chandler/run.sps`,
   4× path-parent = `%root`(install 模式 = libdir;pack 模式 = share/chez)。
   pack 模式再 +2 层得 `%pack-root`(pack.manifest 所在)。
2. **lock 驱动(D18)**:读 `.chandler/chandler-manifest.lock` 的 `(deps ...)`,
   每 dep 取 `(pin (kind "val"))` 的 val 拼 `%root/<dep>/<val>/src::<mt>` 挂
   `library-directories`(版本目录名与 install 布局一致;lock 缺失 = 零依赖,不报错)。
3. **pack 追加段**(顺序固定,校验先于一切状态变更):
   - manifest 读取:不可读 / 非 `(pack …)` → **65** EX_DATAERR
   - format 检查:`(format N)` > `pack-format-supported`(=1) → **70** EX_SOFTWARE
   - target 三元组:machine-type / chez-version 永不放宽,不符 → **78** EX_CONFIG;
     `(skiff-version "X")` 精确:stock runtime 必 78;`(skiff-compat "<range>")`
     区间匹配,唯独全开 `">=0.0.0"`(stock 包默认)在 stock/skiff 上都通过;
     `SKIFF_ALLOW_VERSION_SKEW=1` 只放宽 skiff 维(WARNING + 通过);
     缺 `(target …)` → **65**
   - `%load-natives` 递归扫对象树加载 native(兜底;生成的 native-loader 正常先到)
   - 失败诊断 = 人读行 + 单行 s-expr(`(chandler-pack-error …)`),显式 `(exit N)`,
     绝不走 Chez error(不进 debugger)
4. **入口**:`(eval (list '<main> (list 'quote args)) env)`,env 含 `(chezscheme)`
   + 入口库;main 契约 argv → exit-code,`(exit rc)` 传给启动器。

## 6. 启动器(`bin/<app>`)

sh / ps1 双发,纯相对路径定位(`HERE=$(dirname $0)/..`),不设任何路径环境变量
(D8:APP_ROOT 已去除)。pack 启动器指**bundled runtime**(在 `bin/` 下),与
install 的稳定 shim(指**系统 runtime** + 运行时发现)不是同一份模板 —— 详见
[08-launchers.md](08-launchers.md)。

- **stock(scheme/petite)**:`scheme -b boot/<mt>/petite.boot [-b …/scheme.boot]
  --program share/chez/<name>/<ver>/.chandler/run.sps`
- **skiff**:`SKIFF_BOOT_DIR=$HERE/boot/<mt> exec bin/skiff --program <run.sps>`
  (skiff 按 exe 相对找 boot,包内布局对不上它的默认,必须显式指)

启动器参数原样透传(`"$@"` / `$PackArgs`),退出码 = run.sps 的 `(exit rc)`。

## 7. pack.manifest

```scheme
(pack
  (format 1)
  (app "<name>") (version "<version>")
  (target (chez-version "<v>") (machine-type <mt>)
          (skiff-version "<v>"))            ; 仅 skiff 包;stock 包写 (skiff-compat ">=0.0.0")
  (runtime (kind skiff|scheme|petite) (exe "bin/skiff")
           (boots "boot/<mt>/petite.boot" …))
  (lib-dirs "<mt>")                          ; 各 vroot 下的对象层名(无 lib/ 前缀)
  (entry (library (<lib> …)) (main main))
  (native (<soname> "share/chez/<dep>/<pin>/<mt>/<libpath>/native/<file>") …)  ; 可省
  (files ("<relpath>" (sha256 "<hex>") (size <n>)) …))  ; pack.manifest 自身除外
```

- native 相对路径按**组装后的树**实扫(含应用自己的 native),带 `share/chez/` 前缀,
  消费方(infra)在 import 入口库前统一 `load-shared-object`。
- `(files …)` 按需校验(`verify-pack` / 打补丁前),不在每次启动跑 —— 启动只做廉价的
  目标三元组比对。

## 8. pack 流水线(`chandler/pack.ss` `pack`)

```
preflight(缺 _build / 缺 dep 对象 / 缺声明的 native → 当场报错,指出该跑哪个命令)
  → 创建临时目录 <out>.tmp.<pid>/(D29 原子落地,失败时 rm -rf,不污染最终目录)
  → 阶段 1:install-project-payload!(register?=#f,直拷,无 staging、无 .registry/)
           + copy-chandler-into-pack!(声明了运行时门时)
           + write-app-manifest!(清单快照 / 合成)
           + 入口 .so 存在性检查(失败 rm -rf tmp,不污染最终目录)
  → 阶段 2(仅 app):写 pack 模式 run.sps
           + 定位并拷 runtime exe → bin/,boot → boot/<mt>/
           + 写启动器 bin/<app>[.ps1]
           + 写 pack.manifest(最后写,故不自哈希)
  → 完工:rename <out>.tmp.<pid>/ → <out>/(单次原子落地,覆盖时若 <out> 已存在
    走 backup 回滚路径)
```

> **v4 D29**:旧行为是 `rm -rf <root>` 后原地写,失败时留半成品目录或污染已存在的同名目录;v4 改**临时 sibling + rename**(temp 命名 `<out>.tmp.<pid>/`,与目标同目录保证 rename 原子),失败时直接删 temp,不动目标。
>
> pack 不走 per-prefix 进程锁(D21 的范围是 `install-global` / `uninstall-global` / `switch-active`):pack 创建的是新目录,与正在使用的全局前缀不冲突;临时目录里的写失败可由 D29 temp sibling 自管。

- **pack 只组装,不编译**:编译由 `chandler build` 进程内完成;native 无法在消费方
  现编,缺件必须打包期就停。
- **entry 必须显式**:manifest 的 `(app (entry …))` 或 `--entry`;都没有 → 拒绝
  (lib 不该被悄声打成 app 包;曾经的 bug 把包名当入口库名,跑到启动才炸)。
- 产物是**目录**,不 tar —— 压缩/上传是消费方的事。

## 9. pack verify(`chandler verify-pack <dir> [--target]`)

v4 D24 严格化:完整性校验的本意是发现任何偏差,容差会变成注入窗口。

1. **pack.manifest 顶层**:必须存在 + 必须为 `(pack …)`(用 `expect-tag`,
   非 pair 抛受控错 → **65** EX_DATAERR)。旧行为把 datum 错当低级 cdr 错。
2. **format**:`(format N)` > `pack-format-supported`(=1) → **70** EX_SOFTWARE
3. **`(files …)` 字段**:**必须存在且非空**;缺失 / 空 / 非列表 → **65**
   —— 没有文件清单的包无法证明完整性(旧行为把缺失当空表 → 所有文件成 EXTRA
   却不计 bad → 对任何包都开绿灯)。
4. **`(files …)` 每 entry 必须 `(rel sha256 size)` 三件套**:缺 `sha256` 或
   缺 `size` → fatal(计入 bad,旧行为是默默当 INVALID 但不致命)。
5. **完整性比对**(全部计入 bad,致命):
   - `MISSING`:声明了但盘上没文件
   - `CHANGED`:声明了但 sha256 不符
   - `INVALID`:声明了但 rel 不可辨 / sha256 缺失 / size 缺失(schema 不合格
     的 entry 不让同名文件被二次计 EXTRA)
   - **`EXTRA`**:`(files-under root)` 中未被声明的文件 —— **致命**(v4 起计入 bad;
     v2/v3 只报告不致命,EXTRA 可能是注入窗口)。report: `N ok, M bad, K extra`。
6. **`--target`(opt-in)**:machine-type / chez-version / skiff-version|skiff-compat
   三维比对,不符 → **78** EX_CONFIG;`SKIFF_ALLOW_VERSION_SKEW=1` 只放宽 skiff 维
   (与 run.sps 启动期同一套规则,同一矩阵)。

返回退出码:bad = 0 → 0;bad > 0 → 65;format 太新 → 70;target 不符 → 78。

## 10. pack vs install 差异

| 维度 | pack | install |
|------|------|---------|
| 前缀 | `dist/<name>-<ver>-<mt>/share/chez` | `~/.local/share/chez`(或 --prefix) |
| 注册表 | **无**(register?=#f,可再分发) | 中心 `.registry/`(D16) |
| 拷贝方式 | 直拷(install-payload-global) | staging 原子落位(install-global) |
| runtime 来源 | bundled `bin/<runtime>` + `boot/<mt>/*.boot` | 系统 runtime(运行时发现,D17 shim) |
| 入口 | 启动器 → bundled runtime → run.sps(pack 模式) | 稳定 shim → 系统 runtime → run.sps |
| run.sps | + pack.manifest 校验 + native 加载 | 仅 lock 驱动挂路径 |

## 相关文档

- [00-design-principles.md](00-design-principles.md) — D2/D5 决策、I2 不变量、payload/envelope 定义
- [06-installed-layout.md](06-installed-layout.md) — v3 中心设计(布局、registry、method B、lock 驱动)
- [04-install.md](04-install.md) — install 流水线(被 pack 复用)
- [08-launchers.md](08-launchers.md) — 启动器生成
- [09-runtime-paths.md](09-runtime-paths.md) — 资源定位 API(method B)
