# bake —— Chez Scheme 应用的构建/任务编排工具设计

> 定位:任务编排 + 编译流水线 + **安装**工具,类比 Rake(DAG/增量)+ babashka(用宿主语言写脚本、启动快)。是 **Skiff** 运行时生态里的构建工具,承担 [chez-markding 那种 `Makefile`](chez-skiff-library-layout.md) 的角色并泛化。
> 前提:**只考虑自成体系**(只服务我们自己),不追求生态通用性 —— 这反而是最大的解放:很多通用工具必须头疼的问题,可以用**约定**直接绕过。
>
> **前置约定**:项目按[库布局规范](chez-skiff-library-layout.md)组织(umbrella `<name>.ss` + 同名子库树,搜索根=仓库根)。bake 建立在此约定上:遍历库树编译、按结构安装。依赖获取归 [Chandler](chez-chandler-git-lib-manager-design.md),bake 只管**本项目自身**的构建与安装。
>
> **配套工具**:[Chandler](chez-chandler-git-lib-manager-design.md) —— 库管理器。分工:`chandler` 供货(拉取/安装依赖,读 `manifest.ss`)→ `bake` 编译应用(读 `recipe.ss`)。两份清单**各自独立、互不共享**。

## 关键认知:Rake 的宏 + babashka 的快启动,几乎白得

- **babashka 存在的全部理由是 JVM 启动慢**,它用 GraalVM native-image 花大力气把 Clojure 压成毫秒级启动。而 **Chez 本身原生编译、单位数毫秒启动**,再把工具自己编成 boot/whole-program 后基本"即启"。babashka 最难那部分,不用做。
- **Rake 的 `task`/`file`/`rule` 本质是宏**。构建文件用 Chez 写,DSL 就是几个宏,拿到的是**完整 Scheme**(宏、模式匹配、真数据结构),而非 YAML/TOML 残废配置。这正是 babashka `bb.edn`、Rake `Rakefile` 的路子 —— 构建文件就是宿主语言程序。

所以风险不在"能不能做",而在**如何正确建模 Chez 的编译语义**(难点 3/6/7)。

## 名字

**`bake`**:build + Rake 双关,强调"编译 = 烘焙"这个**动作**。这个双关本身足够独立、好记,故**不强行套航海主题**(生态其余部分:运行时 `skiff`、包管理器 `chandler` 走航海命名,`bake` 独立保留 build+Rake 的理由)。构建文件叫 **`recipe.ss`**(菜谱 = 做法/构建步骤,bake 独用);依赖/项目清单归 Chandler 的 `manifest.ss`,两者互不共享。

> 备选:`cake`(强调成品,但撞名 C# Make 的知名构建工具 Cake)、`chake`(Chez+rake,直白难看)、`roux`(法餐基础酱料,寓意打底)。曾考虑改航海名 `rig`(装配索具),后决定保留 `bake`。

## DSL 草案(示意,非最终 API)

构建文件叫 `recipe.ss`,被工具 `load` 进来求值:

```scheme
;; recipe.ss —— 示意
(define-lib-roots "src")               ; 库搜索根,决定 (a b) → src/a/b.sls

(file "build/main.so" '("src/main.sps")
  (lambda (t deps)
    (compile-program (car deps) t)))    ; 包 maybe-compile-*,自动 mtime 判新

(task 'build '(compile-libs "build/main.so"))

(task 'test '(build)
  (lambda () (run "scheme" "--script" "test/run.ss")))

(task 'exe '(build)                      ; 交付物:见下面三种模式
  (lambda () (link-whole-program "build/main.so" "dist/app")))

(default-task 'build)
```

CLI:`bake`(默认 build)、`bake test`、`bake install`、`bake -T`(列任务)、`bake exe`。三条基元同 Rake:`task`(phony,靠依赖)、`file`(靠目标 mtime vs 依赖)、`rule`(模式规则,如 `.sls → .so`)。执行时拓扑排序、每任务只跑一次。

**shell 原语 `run` / `sh`**:任何 `task`/`file`/`rule` 体内都可跑外部命令——`(run "prog" arg …)`(免 shell,推荐)与 `(sh "cmd …")`(过 shell,支持管道/展开)。这是你在**自己** `recipe.ss` 里跑任意脚本(codegen、lint、打包)的标准出口。注意信任边界:`recipe.ss` 是你自己的代码,`run`/`sh` 随便用;而**依赖**的 native 构建脚本(见下)是别人的代码,须 `--allow-build` 授权。

## 安装:`bake install`(chez-markding Makefile 缺的那一环)

把[库布局规范](chez-skiff-library-layout.md)的 `<name>.ss` + `<name>/` 树 + `native/<mt>/*.so` 复制到目标库目录,**保持"仓库根=搜索根"结构**,使 `(import (<name> ...))` 在系统任意位置可解析:

| 目标 | 落点 | 触发 |
|------|------|------|
| 用户级(默认) | `~/.local/share/chez/lib/<name>{.ss,/}` | `bake install` |
| 系统级 | `/usr/local/share/chez/lib/<name>{.ss,/}`(需 root) | `bake install --global` |

- **已装文件清单**:安装时写一份 manifest(装了哪些文件),`bake uninstall` 据此干净删除——填掉 Chandler 难点 1 说的"全局安装清不干净"。
- **发源码 vs 带 `.so`**:默认发源码(可移植),消费方首次编译;`--with-compiled` 附带当前 `machine-type` 的 `.so`(见难点 4 ABI 取舍)。
- **native**:`native/<mt>/*.so` 原样随装,供 `(load-native …)` 加载。

## 自定义原生构建:要不要 Chez 头文件

FFI 包带 C/C++ 源码时,bake 跑用户自定义构建(Makefile / 脚本)产出 `native/<mt>/*.so`。**要不要给构建注入 Chez 头文件,取决于该包的 FFI 模型——两种模型必须分开对待。**

### 模型 A:纯 C ABI —— 不需要任何 Chez 头(默认)

C 库只暴露普通 C 函数与 C 类型,Scheme 侧用 `foreign-procedure` 做全部 marshaling。**C 代码不知道 Chez 存在,就是普通 `.so`**。libuv / sqlite / openssl 全属此类,占 FFI 场景约 95%。

- 好处:`.so` 可移植、可独立测试、与 Chez 版本解耦;构建是一次完全普通的 C 编译。
- bake **不注入任何 Chez 变量**,保持构建环境干净。

### 模型 B:C 直接操作 Scheme 对象 —— 必须 `scheme.h` + `equates.h`

当 C 用 `ptr` 类型、调 `Sinteger()`/`Scons()`/`Sstring()`、`Slock_object()` 锁对象防 GC、`Sforeign_callable_entry_point()`、`Sactivate_thread()` 时,必须包含 Chez C API 头。**Swish 的 `osi.c` 即此类**(`Slock_object`/`Sinteger`/`container_of`)。

- 代价:`scheme.h`/`equates.h` **按 Chez 版本 + machine-type 生成**,不跨版本稳定 → 用模型 B 的包天然 ABI 绑定(呼应难点 4),且构建时必须拿到**正在用的那个 Chez** 的 include 路径。
- 建议包作者**把 `scheme.h` 暴露面压到最小**:C 侧尽量说纯 C,只在真正必须处(异步 buffer 的 GC 锁、线程 activation、完成队列)用 Chez C API,其余留在 Scheme 侧,升级 Chez 时受伤最轻。

### bake 的契约:按 `chez-api` 开关注入

默认纯 C;**仅当 `manifest.ss` 的 native 项声明 `(chez-api #t)`** 时,bake 才往用户构建环境注入:

| 注入变量 | 指向 | 用途 |
|---|---|---|
| `CHEZ_INCLUDE` | `scheme.h`/`equates.h` 所在目录 | 用户 Makefile:`CFLAGS += -I$(CHEZ_INCLUDE)` |
| `CHEZ_LIB` | `libkernel.a`/`kernel.o` 所在目录 | 仅当该原生库还需**链接** Chez kernel(如 standalone 集成)时 |

模型 A 的构建则一个 Chez 变量都不给。**注入形式随后端而变**:`make`/脚本走**环境变量**(`CHEZ_INCLUDE=…`);`cmake` 走 **`-D` cache 变量**(`-DCHEZ_INCLUDE=…`,`CMakeLists.txt` 里 `target_include_directories(t PRIVATE ${CHEZ_INCLUDE})`)。bake 两者都设无妨,cmake 推荐 `-D`。

### Chez include 路径解析

`scheme.h` 位于 Chez 安装的 boot 目录 `<prefix>/lib/csv<version>/<machine-type>/`(与 `petite.boot`/`scheme.boot`/`libkernel.a` 同处)。bake 解析顺序:

1. 环境变量 `CHEZ_INCLUDE_DIR` 覆盖(用户显式指定,最高优先);
2. 否则从 `scheme` 可执行文件路径 + `--version` + `(machine-type)` 推导 `…/lib/csv<ver>/<mt>/`;
3. 校验该目录确有 `scheme.h`,缺失则**立即报错**(而非让 C 编译到一半才找不到头文件)。

### 构建后端:make / cmake / 脚本(后端可插拔)

**bake 不自己编译 native,只驱动你的构建后端**——make、cmake、任意脚本对 bake 只是不同调用配方。所以 `manifest.ss` 的 `build` 字段声明**后端**而非写死 `make`:

```scheme
(native
  (sqlite (git "…") (rev "…") (build make))                 ; 默认后端
  (foo    (git "…") (rev "…")
          (build (cmake (targets "foo")
                        (defines ("FOO_SSL" "ON"))))         ; 透传为 -DFOO_SSL=ON
          (chez-api #t))                                     ; → 追加 -DCHEZ_INCLUDE
  (bar    (path "native/bar") (build (script "build.sh"))))  ; 任意命令兜底
```

三个后端遵循**同一契约**:进包源码目录(`git` 依赖为 checkout 处,`path` 为声明路径)→ 按后端跑 → 产物落该包 `native/<machine-type>/` → 按 `chez-api` 决定注入 → `--allow-build` 显式授权(跑构建 = RCE)。

**cmake 配方**(bake 内建,三段式):

```sh
cmake -S <srcdir> -B <build>/<mt> -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=<pkg>/native/<mt> \
      [用户 defines…] [-DCHEZ_INCLUDE=<chez-include> 若 chez-api]
cmake --build <build>/<mt> [--target …] -j
cmake --install <build>/<mt>        # 认 DESTDIR;PREFIX 即 CMAKE_INSTALL_PREFIX
```

cmake 的 out-of-source `build/<mt>/` **天然按 machine-type 隔离**(直接满足难点 5);`DESTDIR`/`PREFIX` 语义映射到 `CMAKE_INSTALL_PREFIX`(见 [Chandler](chez-chandler-git-lib-manager-design.md) 难点 5)。**make 配方**则跑 `make` + 按难点 5 传 `DESTDIR`/`PREFIX`,产物同样落 `native/<mt>/`。bake 不重实现 cmake,只编排它。

### 模型 B 的 `CMakeLists.txt` 模板(包作者可抄)

给用 cmake + Chez 嵌入 API(模型 B)的包作者一份可直接用的模板。四个关键点:`SHARED` 库(可被 `load-shared-object` dlopen)、**去 `lib` 前缀**让产物名匹配 `(load-native "osi")` 的 `<soname>.<ext>`、吃 bake 注入的 `-DCHEZ_INCLUDE`、装进 bake 设好的 `CMAKE_INSTALL_PREFIX`(即 `<pkg>/native/<mt>/`)。

```cmake
cmake_minimum_required(VERSION 3.15)
project(osi C)

add_library(osi SHARED osi.c)        # SHARED → .so/.dylib/.dll,可被 load-shared-object dlopen

# 去掉 lib 前缀:产出 osi.so / osi.dylib / osi.dll,匹配 (load-native "osi") 的 <soname>.<ext>
# WINDOWS_EXPORT_ALL_SYMBOLS:MSVC 默认不导出 DLL 符号,不加则 load-native 拿不到 foreign-procedure 入口
set_target_properties(osi PROPERTIES PREFIX "" WINDOWS_EXPORT_ALL_SYMBOLS ON)

# ── 模型 B:吃 bake 注入的 Chez C API 头(-DCHEZ_INCLUDE=…)──
#    模型 A(纯 C ABI)删掉这一整段即可,连 CHEZ_INCLUDE 都不需要。
if(NOT CHEZ_INCLUDE)
  message(FATAL_ERROR
    "CHEZ_INCLUDE 未设置:模型 B 需 bake 注入 scheme.h 路径(bake 以 -DCHEZ_INCLUDE 传入)")
endif()
target_include_directories(osi PRIVATE ${CHEZ_INCLUDE})   # scheme.h / equates.h

# 极少数情况:原生库还需链接 Chez kernel(standalone 集成)。bake 另传 -DCHEZ_LIB。
# target_link_libraries(osi PRIVATE ${CHEZ_LIB}/libkernel.a)

# 装到 CMAKE_INSTALL_PREFIX = <pkg>/native/<machine-type>/(bake 已设),故 DESTINATION 用 "."
install(TARGETS osi
        LIBRARY DESTINATION .        # Unix: .so/.dylib
        RUNTIME DESTINATION .)       # Windows: .dll
```

> **平台后缀自洽**:CMake 对 `SHARED` 库在 Linux 出 `.so`、macOS 出 `.dylib`、Windows 出 `.dll`,恰好与 `load-native` 里 `so-ext` 按 machine-type 推的扩展名一致——两侧不会错配。(注意别用 `MODULE`:它在 macOS 会出 `.so` 而非 `.dylib`,与 `load-native` 的判定冲突。)
>
> **模型 A** 的包只需上半段(`add_library` + `PREFIX ""` + `install`),把 `CHEZ_INCLUDE` 相关整段删掉,构建环境里一个 Chez 变量都不出现。

### 产物落点契约(所有后端的不变量)

不管 make / cmake / script,**最终 FFI 产物必须落在 `<pkg>/native/<machine-type>/<soname>.<ext>`**——这是 `load-native` 与 `bake install` 唯一认的位置。落点是**不变量**,后端只是到达方式:

| 后端 | 到达方式 |
|------|---------|
| make | `DESTDIR`/`PREFIX` → 该目录 |
| cmake | `CMAKE_INSTALL_PREFIX` → 该目录 |
| script | bake 传 `$NATIVE_OUT`,脚本把产物放进去 |

**bake 在后端跑完后校验**:期望的 `<soname>.<ext>` 是否真在 `native/<mt>/`;不在就**立即报错**(而非默默成功、拖到运行期 `load-native` 才炸)。期望的 soname 取自 native 项名,或显式 `(produces "osi" …)`。

### script 后端:环境契约

`(build (script "build.sh"))` 时,bake 在**包源码目录**里跑脚本,注入这些环境变量;脚本只负责把产物丢进 `$NATIVE_OUT`:

| 变量 | 值 |
|------|-----|
| `NATIVE_OUT` | `<pkg>/native/<machine-type>/`(bake 已建好)|
| `MACHINE_TYPE` | 如 `ta6le` |
| `SOEXT` | `so` / `dylib` / `dll` |
| `CHEZ_INCLUDE` | `scheme.h` 目录(**仅** `chez-api #t`)|
| `CHEZ_LIB` | `libkernel` 目录(仅需链接 kernel 时)|

```sh
#!/bin/sh
# build.sh —— 落点契约:产物写进 $NATIVE_OUT/<soname>.$SOEXT
cc -shared -fPIC ${CHEZ_INCLUDE:+-I"$CHEZ_INCLUDE"} osi.c -o "$NATIVE_OUT/osi.$SOEXT"
```

跑完 bake 校验 `$NATIVE_OUT/osi.$SOEXT` 存在。**注入变量与前述 make/cmake 完全同源**——script 只是把同一套 Chez/落点信息以环境变量形式给到任意命令,不引入新概念。

### 信任模型:谁的脚本

- **你自己项目的 `recipe.ss` / 构建脚本**:是你自己的代码,天然可信,`sh`/`run` 随便用。
- **依赖的 native 构建(make/cmake/script)**:是**别人的代码**,跑它 = RCE,必须 `--allow-build` 显式授权、可审计。区分标准是"谁写的",不是"用哪个后端"。

## 要编码的"交付物模型"(Chez 不是普通编译器)

Chez 不像 gcc 直接吐可执行文件。工具需内建三种 `link` 目标,选一做默认、其余 opt-in:

| 模式 | 产物 | 依赖 | 适合 |
|---|---|---|---|
| **boot 文件** `make-boot-file` | petite.boot+scheme.boot+库 打成一个 `.boot`,`scheme --boot app.boot` 跑 | 需现场有 scheme 可执行文件 | 内部分发、启动快 |
| **whole-program `.so`** `compile-whole-program`(靠 `.wpo`) | 单个全程序优化 `.so` | 编译期须**全程开 `generate-wpo-files`** 才有 `.wpo` 可合 | **推荐做默认** |
| **独立可执行文件** | 生成 C `main` + 链接 `libkernel`/`kernel.o`,真正自包含 exe | 需 C 工具链 + 精确匹配 Chez 安装布局 | 最"自成体系",也最脆 |

对自成体系:建议**默认 whole-program `.so` + 薄 wrapper**,standalone-exe 作为 `bake exe --standalone` 目标。

## 打包分发:`bake pack`

把 Skiff 应用**整体**打成无源码安装包(非 standalone exe),两模式:**per-module `.so`(主·重点优化)/ 单 boot(保留)**。

```
bake pack --mode modules --target <mt>    # per-module(主)
bake pack --mode boot    --target <mt>    # 单 boot(保留)
```

`bake pack` 不引入新编译能力,只**组装**:`bake build` 的 `build/<mt>/`(剥源码)+ [Chandler](chez-chandler-git-lib-manager-design.md) 依赖闭包 + native 后端产物 + skiff 运行时 + 启动器 + `pack.manifest`。模式 1 复用上文「交付物模型」的 `make-boot-file`。

> **完整规范**(包布局、`pack.manifest` 格式、`skiff --app` 加载、`verify-target!` 失败策略、补丁模型、跨平台/Windows)见 **[Skiff 应用打包与部署规范](chez-skiff-pack-spec.md)**——pack 的单一权威,本节仅入口。

## 真正会硌手的地方(附:自成体系能否躲开)

### 1. 从 `import` 自动抽依赖图 —— 核心价值,也最难
从 `.sls`/`.sps` 解析 `(import ...)` 自动建 DAG。难点:`(for (x) expand run)` 相位、`only/except/rename/prefix` 要解析但不影响文件依赖、`include`/`include-ci` 的隐藏文件依赖、`cond-expand`、排除内建库(`(chezscheme)`/`(rnrs ...)` 不进图)。宏可生成 import,静态分析原理上不完备。
→ **自成体系可躲大半**:约束自己代码风格(import 写库头、不用宏拼库名、include 显式声明),分析就够可靠。

### 2. Chez 已自带 mtime 增量(`maybe-compile-*`),别重复造
`maybe-compile-file/library/program` 已做"目标比源新就跳过"。你的增量价值**不在单库编译**,而在**跨目标 DAG + 非 Chez 产物**(生成的源码、FFI 的 C `.so`、boot 文件)。
→ 老实承认这层已解决,力气放到编排。

### 3. 相位/展开期耦合导致的"失效级联" —— 最阴的 bug 源
若库 B `(for expand)` 依赖库 A(A 导出宏),则 **A 一改,B 必须重编**,哪怕 B 源码没动。纯 mtime 会漏掉级联,结果是"加载旧 `.so`,报玄学错,clean 一下就好"。失效判定必须把**导出宏的依赖**特殊对待:上游变→下游一律失效。
→ **躲不开,必须正面处理**。决定工具可不可信。

### 4. 增量正确性 > 速度:失效键要含编译参数和 Chez 版本
换 `optimize-level`、开关 `generate-wpo-files`、升级 Chez —— 源 mtime 没变但产物须重建。Rake 只看 mtime 就栽这。正解:把 **(源内容哈希 + 编译 flags + Chez 版本 + `(machine-type)`)** 做成 fingerprint 当失效键。
→ 直接上内容指纹,不走纯 mtime。

### 5. 产物按 machine-type 分目录
`.so`/`.wpo`/`.boot` 绑定 Chez 版本 + machine type(如 `ta6le`)。`_build` 布局须 `build/<machine-type>/...`,否则换机器/版本会静默加载错产物。
→ 约定解决,但一开始就定死。

### 6. WPO footgun:whole-program 依赖编译期全程开 `.wpo` 生成
`compile-whole-program` 要合并程序及其所有库的 `.wpo`。只要有**一步**编译忘了 `(generate-wpo-files #t)`,最后就合不出来。该参数须由工具**统一注入**每次编译,不交给构建文件手写。

### 7. 并行编译只能靠多进程,不能靠线程
提速来自并行编译独立库。但 Chez 编译器**进程内**跑,`library-directories`、展开期实例等近乎全局状态,同进程并行 `compile-library` 易串味、产出错配 `.so`。正解:**进程池**(`fork/exec scheme --script compile-one.ss` 每次编一个),配合失效图。
→ 想要 `-j`,从一开始设计成"一个编译单元 = 一个子进程"。

### 8. 工具自举的鸡生蛋
要快启动就把 `bake` 自己编成 boot/whole-program;但编它的又是 bake。用解释执行的 `bootstrap.ss` 第一次把真身编出来即可。

### 9. `clean` 与副作用语义
构建文件是完整 Scheme,可任意副作用,`clean` 不知删什么。约定:每个 `file`/target **显式声明输出**,`clean` 只删声明过的;不鼓励未声明副作用。

## 结论

能不能做没悬念(Rake 的宏 + Chez 的快启动几乎白得);成败在**三处编译语义建模** —— (3) 宏依赖的失效级联、(6) 全程 WPO、(7) 并行靠多进程。其余(依赖抽取、machine-type 分目录、指纹增量)靠自成体系的约定即可压平。

## 可能的下一步(二选一)

1. 把 `task/file/rule` 三个宏 + 拓扑执行器写成能跑的最小内核(约 100 行,先不管 Chez 编译)。
2. 先攻**依赖图 + 失效级联**:给出 `import` 解析器和 fingerprint 失效模型的设计。
