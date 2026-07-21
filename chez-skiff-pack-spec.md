# Skiff 应用打包与部署规范(pack spec)

> **定位**:把一个 Skiff 应用**整体**打成**无源码**安装包的格式与部署契约。产物由 `bake pack` 生成、依赖闭包由 [Chandler](chez-chandler-git-lib-manager-design.md) 提供、运行时由 `skiff --app` 消费。**本文档是 pack 的单一权威**;[bake 文档](chez-bake-build-tool-design.md) 只保留命令入口与指针。
>
> **目标**:应用 + 全部依赖 + native + 运行时 → 无源码、可安装、可运行的包;支持**按模块打补丁**;跨平台(含 Windows)。
> **非目标**:standalone 单 exe(明确不走,见 bake「交付物模型」);源码分发(那是 Chandler/git 的事)。

## 1. 两种打包模式

**per-module `.so` 为主力、重点优化;单 boot 保留**。native `.so`/`.dll` 两模式都单独随包;两模式都需 `bin/skiff` 运行时;一 `(Skiff 版本 × machine-type)` 一套包。

| | 模式 2:per-module `.so`(主) | 模式 1:单 boot(保留) |
|---|---|---|
| Scheme 层形态 | 每库一 `.so`,一整棵镜像树 | `make-boot-file` 合成单 `app.boot` |
| 优化重点 | 模块化、可**单独打补丁**、懒加载、增量更新小 | 极速冷启动、原子、支持跨模块 `.wpo` 全程序优化 |
| 放弃 | 跨模块 `.wpo` 内联(各库仍各自完整优化) | 单模块补丁(改一处重打整包) |
| 适合 | 需按模块灰度/热补的部署 | 不可变镜像、追求峰值性能 |

CLI:

```
bake pack --mode modules --target ta6nt    # Windows 64,per-module(主)
bake pack --mode modules --target ta6le    # Linux 64
bake pack --mode boot    --target ta6osx   # macOS,boot 模式
```

## 2. 包布局

### 模式 2(per-module,主)

```
myapp-1.0-<mt>/
├─ bin/  skiff[.exe]   myapp[.cmd]          运行时 + 启动器
└─ lib/
   ├─ myapp.so   myapp/**/*.so              应用编译树(= build/<mt>/ 剥源码搬入)
   ├─ <dep>.so   <dep>/**/*.so              各依赖编译树(Chandler 编译闭包)
   ├─ native/<mt>/*.{so,dll,dylib}          C FFI(activate/--app 统一加载)
   └─ pack.manifest                         清单:文件 + 哈希 + (chez-version, machine-type)
```

### 模式 1(boot)

```
myapp-1.0-<mt>/
├─ bin/  skiff[.exe]   myapp[.cmd]
└─ lib/
   ├─ app.boot                              make-boot-file 合 petite+scheme+skiff运行时+应用+全部依赖
   ├─ native/<mt>/*.{so,dll,dylib}          C FFI(boot 装不下 C 库,须并排)
   └─ pack.manifest
```

### 扩展名规则(跨平台不变量)

- **Chez 编译产物恒为 `.so`**(所有平台;Chez fasl,由 Chez loader 载入,非 OS 动态库)。
- **native C 库随 OS**:Linux `.so` / macOS `.dylib` / Windows `.dll`。
- 推论:Windows 包里 Chez 是 `.so`、C 是 `.dll`,**天然不撞**;难点 4 的「两种 `.so` 同名」混淆**只在 Linux** 存在。

## 3. `pack.manifest` 格式

s-表达式(与 `manifest.ss`/`recipe.ss` 一致,部署态只读、易 `read`)。承载三件事:**目标绑定**(加载/补丁前校验)、**入口**、**文件清单 + 哈希**(完整性 + 单文件补丁校验)。

```scheme
(pack
  (format 1)                                ; 清单格式版本(前向兼容;运行时不识别更高版即拒)
  (app "myapp") (version "1.0.3")
  (mode modules)                            ; modules | boot
  ;; 目标绑定:加载/补丁前校验(策略见 §5)
  (target (skiff-version "0.4.1")
          (chez-version  "10.3.0")
          (machine-type  ta6nt)
          (skiff-compat  ">=0.4 <0.5"))     ; 可选:放宽 skiff-version 为范围;缺省=精确匹配
  (runtime  "bin/skiff.exe")
  (lib-dirs "lib")                          ; 库搜索根(相对包根)
  (entry (library (myapp)) (main main))     ; modules:入口库 + main 过程
  ;; boot 模式改为:(entry (boot "lib/app.boot") (main main))
  (native (sqlite "lib/native/ta6nt/sqlite.dll")   ; load-native 名 → 路径(§4 统一加载)
          (osi    "lib/native/ta6nt/osi.dll"))
  (files                                     ; 每文件:路径 + sha256 + size + 归属注解
    ("bin/skiff.exe"               (sha256 "a1b2…") (size 2451968))
    ("lib/myapp.so"                (sha256 "…") (size 10240) (lib (myapp)))
    ("lib/myapp/core/thing.so"     (sha256 "…") (size 4096)  (lib (myapp core thing)))
    ("lib/native/ta6nt/sqlite.dll" (sha256 "…") (size 1200128) (native sqlite))))
```

字段说明:

- **`target` 三元组**是 per-module 补丁安全的落点:补丁 `.so` 或整包加载前,skiff 比对自身 `(skiff/chez 版本, machine-type)`,不符报错——把「补丁必须同 ABI」变成硬校验。
- **`(lib (a b))` 注解**把 `.so` 关联到库名:补丁工具"按库名定位文件",并校验闭包完整(所有被 `import` 的库都在清单里,不缺件)。
- **`(native name)`** 关联到 `load-native` 名,供 §4 统一加载定位。
- **哈希 sha256**:安装/补丁时校验;全树哈希校验**按需**(`skiff --verify` 或补丁时),不在每次启动跑。

## 4. 运行时加载:`skiff --app`

启动器薄 shim → 调 `skiff --app pack.manifest`,**部署态加载逻辑集中在运行时**:

```scheme
(let ([m (read-pack-manifest path)])
  (verify-target! m)                 ; §5:skiff/chez 版本 + machine-type 匹配否,不符即退出报错
  (compile-imported-libraries #f)    ; 部署态:只 fasl 载入,永不重编
  (library-directories (list (in-pack m (pack-lib-dirs m))))
  (for-each (lambda (n) (load-shared-object (in-pack m (cdr n))))  ; 统一自动载入声明的全部 native
            (pack-natives m))        ; 与 Chandler activate 同策略:infra 载 native,库只写 foreign-procedure
  ((entry-main m)))                  ; import 入口库并调 main
```

要点:

- **只载不编**:`(compile-imported-libraries #f)`——部署态无编译器,遇到"只有源码无对象"直接报错而非尝试编译。
- **native 统一加载**:infra 一次性 `load-shared-object` 全部声明的 native(与 [Chandler `activate`](chez-chandler-git-lib-manager-design.md) 同策略);之后任何库的 `foreign-procedure` 全局可解析,**库自身不 load native**。
- **懒加载**:仅被 `import` 的 Chez 库才 fasl 载入,冷启动成本 ∝ 实际闭包。
- **boot 模式**:代码已在 `app.boot`(启动器多传 `--boot`),`--app` 只做校验 + native 加载 + 调 main。

## 5. `verify-target!` 失败处理策略

部署态**无编译器、无源码**,目标不匹配**无法就地补救**。唯一正确策略:**加载任何 `.so`/boot 之前** fail fast、fail loud、fail actionable,且**零副作用**(不 mutate `library-directories`、不 load 任何东西)。三分量严重性不同,分开定策:

| 分量 | 判定规则 | 不匹配 | 依据 |
|------|---------|--------|------|
| `machine-type` | **必须精确相等** | 致命,不可恢复 | 架构/OS/线程绑定,fasl 根本无法载入 |
| `chez-version` | **必须精确相等** | 致命,不可恢复 | fasl ABI 绑版本;即便不查,Chez loader 也会拒 |
| `skiff-version` | 默认精确;pack 声明 `(skiff-compat <range>)` 则按范围 | 致命(超范围) | Skiff 库 API 兼容性;有 ABI 承诺时可放宽 |

失败时:

1. **最先执行、前置于一切加载**——失败即退出,进程绝不进半加载态。
2. **专用退出码**(供 installer/orchestrator 分支,sysexits 风格):

   | 码 | 含义 |
   |----|------|
   | `78`(EX_CONFIG) | target 三元组不匹配(平台/版本不兼容) |
   | `70`(EX_SOFTWARE) | `(format N)` 比本运行时支持的新 |
   | `65`(EX_DATAERR) | 完整性校验失败(§6,与 target 分开) |

3. **可执行诊断**——逐项 **expected(pack) vs actual(runtime)** + 病因 + 修复:
   - `machine-type` 不符 → "下错平台包了,请取 `<machine-type>` 构建。"
   - `chez`/`skiff` 版本不符 → "此包为 Skiff X / Chez Y 构建,当前运行时 Skiff X' / Chez Y';装匹配运行时或重打包。"
4. **结构化输出**——诊断同时以 s-表达式发 stderr(或 `skiff --verify` 返回 diff),供更新器**自动取正确包**。
5. **不自动降级、不 best-effort**——错配 fasl = 崩溃/静默损坏,必须拒绝;**无 `--force`** 覆盖 `machine-type`/`chez`(物理上也载不了);仅 `skiff-version` 留开发用逃生阀 `SKIFF_ALLOW_VERSION_SKEW=1`(默认关、触发即大字告警)。

## 6. 完整性校验(hash,独立于 target)

- **target 是"能不能跑"的快速门**(3 字段);**`files` 的 sha256 是"文件是否损坏"**(退出码 `65`)。两者分开、诊断分开。
- 触发时机:安装时、`skiff --verify`、以及**打补丁时**(校验新 `.so` 未损坏);**不在每次启动全树哈希**(太贵)。

## 7. 补丁 / 更新模型(per-module 的核心价值)

- 替换 `lib/<name>/foo/bar.so` → **下次进程启动生效**(Chez 不做进程内热替换,重启为模型)。
- 补丁前跑同一 `verify-target!`(§5):新 `.so` 的 `(chez-version, machine-type)` 不符运行时即**拒绝写入**补丁树;再跑 sha256 完整性(§6)。
- 粒度:默认一库一 `.so`(最细、最可补丁);热路径可**合并子树为单 `.so`** 换更少文件载入(牺牲可补丁性)——per-module 唯一的性能旋钮。
- **Windows 补丁友好度分化**:Chez `.so` 由 Chez loader 载入、**不被 OS 当 DLL 锁,可替换**;native `.dll` 使用中被锁,补丁需进程未占用。

## 8. 启动器

薄 shim:定位包根 → 调 `skiff --app`。两平台对称,几乎无逻辑。

POSIX(`bin/myapp`):

```sh
#!/bin/sh
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)   # 包根 = bin/..
exec "$here/bin/skiff" --app "$here/pack.manifest" "$@"
```

Windows(`bin\myapp.cmd`):

```bat
@echo off
setlocal
set "HERE=%~dp0.."
"%HERE%\bin\skiff.exe" --app "%HERE%\pack.manifest" %*
exit /b %errorlevel%
```

- **boot 模式**:多传 `--boot "$here/lib/app.boot"`(代码在 boot 里,`--app` 只做校验 + native 加载 + 调 main)。
- `"$@"` / `%*` 透传应用参数;`%~dp0` 是脚本所在 `bin\`,`%~dp0..` 即包根。
- bake 按 target 出对应启动器:`*nt` 出 `.cmd`,其余出 sh;都由 `bake pack` 写进 `bin/`。

## 9. 跨平台 / Windows

| 维度 | Linux | macOS | Windows |
|------|-------|-------|---------|
| machine-type | `ta6le`/`a6le` | `ta6osx`/`tarm64osx` | `ta6nt`/`a6nt` |
| Chez 编译产物 | `.so` | `.so` | `.so`(Chez fasl,非 OS!)|
| native C 库 | `.so` | `.dylib` | `.dll` |
| 运行时可执行 | `skiff` | `skiff` | `skiff.exe` |
| 启动器 | sh 脚本 | sh 脚本 | `.cmd`/`.bat` |
| 库路径分隔符 | `:` | `:` | `;` |
| native 符号导出 | 默认导出 | 默认导出 | 须 `WINDOWS_EXPORT_ALL_SYMBOLS` |
| native 运行时依赖 | glibc | 系统库 | 须带 VC/UCRT redist |
| 替换已加载文件 | 可 | 可 | Chez `.so` 可;native `.dll` 被锁 |

Windows 三个必须处理的坑:

1. **符号导出**:MSVC 默认不导出 DLL 符号,native `CMakeLists.txt` 须 `WINDOWS_EXPORT_ALL_SYMBOLS ON`(见 [bake CMake 模板](chez-bake-build-tool-design.md)),否则 `foreign-procedure` 拿不到入口。
2. **运行时依赖**:native `.dll` 依赖 MSVC 运行时,包内带 vcruntime/ucrt 或声明依赖 VC++ Redistributable;**传递依赖 DLL 须与主 `.dll` 同目录或在 PATH**。
3. **交叉编译受限**:Chez 产物绑 machine-type,出 `ta6nt` 包通常需**对应平台的构建机**(Chez 交叉编译支持有限)。Chandler 在该平台提供已编译依赖闭包,native 由 cmake 在该平台出 `.dll`。**不能在 Linux 上一键出 Windows 包**。

## 10. 与 bake / Chandler 的关系

`bake pack` **不引入新编译能力,只组装**:

| 组件 | 来源 |
|------|------|
| `lib/<app>/` 编译树 | [`bake build`](chez-bake-build-tool-design.md) 的 `build/<mt>/` 剥源码 |
| 各依赖 `.so` 树 | [Chandler](chez-chandler-git-lib-manager-design.md) 编译闭包(消费方 build) |
| `native/<mt>/*` | native 后端(make/cmake/script)产物 |
| `app.boot`(模式 1) | bake「交付物模型」的 `make-boot-file` |
| `bin/skiff` | Skiff 运行时二进制 |
| 启动器 + `pack.manifest` | `bake pack` 生成 |

## 相关文档

- [chez-skiff-runtime-design.md](chez-skiff-runtime-design.md) —— Skiff 运行时
- [chez-skiff-library-layout.md](chez-skiff-library-layout.md) —— 库布局规范(编译树 1:1 镜像的来源)
- [chez-bake-build-tool-design.md](chez-bake-build-tool-design.md) —— bake 构建/安装/`bake pack` 入口 / native 构建 / CMake 模板
- [chez-chandler-git-lib-manager-design.md](chez-chandler-git-lib-manager-design.md) —— Chandler 依赖闭包 / `activate` 统一加载 native
