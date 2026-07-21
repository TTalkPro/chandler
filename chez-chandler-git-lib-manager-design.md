# Chandler —— 基于 git 的 Chez Scheme 库管理器设计

> 定位:git-first 的 Chez 库管理器,类比 Erlang 的 rebar3。是 **Skiff** 运行时生态里的包管理器。
> 目标:把某个 git 仓库里的 R6RS 库安装到 Chez 的库搜索路径中,支持系统级 / 用户级 / 项目本地三种落点,并在仓库带 Makefile 时按 `DESTDIR`/`PREFIX` 语义执行构建。
>
> **航海隐喻**:Skiff(轻舟)是运行时;**Chandler(船具商)专门给船供应补给和装备** = 包供应商/库管理器,天然配对。项目清单文件叫 **`manifest.ss`**(载货清单 = 船上装了什么 = 项目依赖了什么),这两层意思字面重合。
>
> **配套工具**:[bake](chez-bake-build-tool-design.md) —— 构建/编译工具(build + Rake 双关)。分工:`chandler` 供货(拉取/安装依赖,读 `manifest.ss`)→ `bake` 编译应用(读 `recipe.ss`)。两份清单**各自独立、互不共享**。

## 需求回顾

1. 基于 git,类似 rebar3。
2. 可安装到:
   - `/usr/local/share/chez/lib`(系统级,需 root)
   - `~/.local/share/chez/lib`(用户级)
   - 视情况直接装进项目自己的 lib 目录
3. 若下载的项目带 Makefile,则执行 Makefile,并且能通过环境变量替换目标路径。

## 名字

**`chandler`**(船具商):船具商是"给船供应补给和装备的商家",正对包供应商/registry 的字面定义。依赖 = 船上补给,Chandler 就是备货和供货的一方,与运行时 `skiff`(船)、构建工具(装配)成一套航海故事。

**清单文件 `manifest.ss`**:货运 manifest 就是"这条船上装了什么"的清单,和"这个项目依赖什么"字面对齐;而 "manifest" 在软件圈本就是"内容/元数据列表"的通用词,零学习成本。以 `.ss` 结尾意味着它是一份可 `read` 的 s-表达式**数据**(类比 Clojure 的 `deps.edn`),Lisp 里最地道。锁文件为 **`manifest.lock`**。

> 备选(历史):`pantry`(食品储藏室,旧厨房主题)、`larder`、`cave`(撞 Homebrew Cellar)。航海备选:`hold`(货舱)、`bosun`(水手长,撞 Stack Exchange 的 bosun 监控)、`purser`(事务长)。最终取 `chandler`,辨识度与"供货"语义最强。

## `manifest.ss` 字段设计

```scheme
;; manifest.ss —— Chandler 读取的项目载货清单
(manifest
  ;; ── 项目标识 ──
  (name    "my-app")
  (version "0.1.0")
  (skiff   ">=0.3")                 ; 需要的 Skiff 运行时版本区间(见下「版本区间语法」)

  ;; ── 库根探测(见难点 3):声明本仓库的库搜索根 ──
  (srcdir  "src")                   ; (import (foo bar)) → src/foo/bar.sls

  ;; ── 运行时依赖:库名 → 来源 + pin ──
  (deps
    ;; 库名      来源                                  pin(tag / rev / branch 三选一)
    (http   (git "https://github.com/x/http")      (tag    "v1.2.0"))
    (json   (git "https://github.com/x/json")      (rev    "a1b2c3d"))    ; 最可复现
    (uri    (git "git@github.com:x/uri.git")       (branch "main"))       ; 会漂移 → 必进 lock
    ;; 本地 path 覆盖:开发期联调,优先级高于 git,不写进 lock
    (mylib  (path "../mylib")))

  ;; ── 仅开发 / 测试期依赖(发布物不含)──
  (dev-deps
    (test   (git "https://github.com/x/test")      (tag "v0.5.0")))

  ;; ── 需构建的原生依赖:显式授权跑构建(见难点 5)──
  ;; FFI 模型见 bake 文档「自定义原生构建」:默认纯 C(模型 A,无需 Chez 头);
  ;; 声明 (chez-api #t) 才注入 CHEZ_INCLUDE(模型 B,Swish 式,直接操作 Scheme 对象)。
  ;; build 后端可插拔:make(默认)/ cmake /(script "…");产物落该包 native/<mt>/。
  (native
    ;; make 后端 + 模型 A:纯 C ABI,不需要 Chez 头
    (sqlite (git "https://github.com/x/sqlite-ffi") (rev "…")
            (build make))
    ;; cmake 后端(三段式 configure→build→install,out-of-source 按 mt 隔离)
    (foo    (git "https://github.com/x/foo") (rev "…")
            (build (cmake (targets "foo")
                          (defines ("FOO_SSL" "ON")))))     ; 透传为 -DFOO_SSL=ON
    ;; cmake + 模型 B:bake 追加 -DCHEZ_INCLUDE
    (osi    (path "native/osi")
            (build (cmake (targets "osi"))) (chez-api #t))
    ;; script 后端:bake 传 $NATIVE_OUT/$SOEXT/$CHEZ_INCLUDE,脚本把产物丢进 $NATIVE_OUT
    (bar    (path "native/bar")
            (build (script "build.sh"))
            (produces "bar")))           ; 校验 native/<mt>/bar.<ext> 存在;默认取项名

  ;; ── 命名脚本别名:Chandler 只跑这些具名脚本,不执行任意 shell ──
  (scripts
    (postinstall "scripts/setup.ss")))
```

### 版本区间语法

git-first 下**首要 pin 手段是 git 的 `tag`/`rev`/`branch`**;版本区间主要用于 `skiff` 运行时要求,以及"从若干 git tag 里择优"的可选解析。自定义一套(R6RS 的 `(1 2)` 版本语法几乎无人用、匹配语义弱,不作锚点):

| 写法 | 含义 |
|------|------|
| `"1.2.0"` | 精确 |
| `"^1.2.0"` | 兼容:`>=1.2.0 <2.0.0`(不破主版本)|
| `"~1.2.0"` | 近似:`>=1.2.0 <1.3.0`(只放 patch)|
| `">=0.3"` | 下界 |
| `"*"` | 任意 |

### `manifest.lock`

- 对每个 git 依赖记录**解析到的确切 commit `rev`** + 来源 URL + 传递依赖,保证跨机可复现。
- `branch` pin 每次 `chandler update` 时重解析并刷新 lock;`rev`/`tag` pin 稳定。
- `path` 覆盖不写入 lock(纯本地开发态)。

## 运行期激活(rubygem 式)与原生库加载

目标:像 Ruby 的 `require 'bundler/setup'` 那样——**应用顶上一行激活整个依赖环境**,之后 `import` 当前目录 `lib/` 下所有依赖即可用;再提供一个**加载 C/C++ 生成 `.so` 的函数**。

### 机制三件套

1. **`(chandler)` 库全局预装**(用户级 `~/.local/share/chez/lib`)——类比"rubygems 预装",保证 `(import (chandler))` 永远可解析,解决"要用 Chandler 却得先装 Chandler"的鸡生蛋。
2. **`(activate)`** 读 `./manifest.lock`,做两件事:(a) 把 `./lib` 下每个依赖的库根 **prepend 到 `(library-directories)`**;(b) **一次性自动加载所有依赖声明的 native `.so`**(见下)。
3. **native 由 activate 统一加载,不是每个 lib 自己 load**。理由:库不该知道自己的 `.so` 装在哪——那是 machine-type/安装布局的事,只有 Chandler 知道。所以各依赖在其 `manifest.ss` 的 `native` 字段**声明**要哪些原生库,`activate` 按依赖序把它们全部 `load-shared-object`;之后**任何** lib 的 `foreign-procedure` 都能解析到符号(Chez 的 `foreign-procedure` 对所有已载入 shared object 全局查找)。`(load-native …)` 仅作**边缘/显式控制**的公开函数保留(如动态加载未声明的库),常规路径无需调用。

### ⚠️ expand-time 坑(决定用法边界)

Chez 对**库/程序**的 `import` 是**展开期一次性解析**的——无法"先 import 一个文件再让后续 import 生效"。但**脚本顶层(REPL 语义)的 `import` 顺序求值**:`scheme --script app.ss` 每个顶层 form 依次展开+求值,故 `(activate)` 改完 `library-directories` 后,下一条 `(import ...)` 才展开、即可解析。

**结论:rubygem 式"一行激活"只在脚本顶层成立**(恰是应用入口形态)。对编译成 whole-program/boot 的程序(单一 import,无法穿插),激活须在展开前完成——走 `chandler run`(Bundler exec 模型:先设 `library-directories` 再 `load` 应用)或 `CHEZSCHEMELIBDIRS` 环境变量。

```scheme
;; ── 脚本模式:chandler run app.ss  或  scheme --script app.ss ──
(import (chandler))
(activate)                 ; 一步到位:①挂载所有依赖库路径 ②自动载入所有依赖声明的 native

(import (http) (json))     ; ← 在 activate 之后才展开,解析成功;FFI 库直接 foreign-procedure,无需自载 native
```

### 目录布局(遵循[库布局规范](chez-skiff-library-layout.md))

依赖按 [chez-markding 惯例](chez-skiff-library-layout.md)**整仓 checkout**,其仓库根即搜索根(`srcdir "."`):

```
project/                          ← Skiff 应用
  manifest.ss  manifest.lock
  lib/                            ← Chandler 装依赖处(activate 扫这里,替代早期设想的 deps/)
    http/                         ← 依赖整仓 = 该库仓库根 = 其搜索根(srcdir ".")
      http.ss                     (library (http))            ← umbrella
      http/client.ss              (library (http client))
    sqlite/
      sqlite.ss                   (library (sqlite))
      sqlite/ffi.ss               (library (sqlite ffi))      ← 只写 foreign-procedure;native 由 activate 统一载
      native/ta6le/sqlite.so      ← C/C++ 产出,置仓库根、按 machine-type 分目录
  build/<machine-type>/…          ← 应用自身编译产物(bake 出)
```

`activate` 把每个 `lib/<name>/`(srcdir `"."`)prepend 到 `library-directories`。**原生 `.so` 放依赖仓库根的 `native/<machine-type>/`**,不进 Chez 库子树——正是难点 4「Chez 编译库 `.so` 与 FFI 的 C `.so` 同名不同物」的解药。

### `(chandler)` 库 API 草案

```scheme
(library (chandler)
  (export activate load-native native-path)
  (import (chezscheme))

  ;; 读 ./manifest.lock:①挂载库路径 ②自动载入所有依赖声明的 native
  (define (activate . maybe-root)
    (let* ([root  (if (null? maybe-root) "." (car maybe-root))]
           [deps  (read-lock (path-build root "manifest.lock"))])
      (library-directories                                   ; ① 库搜索路径
        (append (map (lambda (d) (path-build root "lib" (dep-name d) (dep-srcdir d))) deps)
                (library-directories)))
      (native-root (path-build root "lib"))
      ;; ② 按依赖序自动载入每个依赖声明的 native(幂等);之后所有 foreign-procedure 全局可解析
      (for-each
        (lambda (d)
          (for-each (lambda (nat)                            ; nat = (pkg . soname),来自各 dep 的 manifest native 声明
                      (load-native (car nat) (cdr nat)))
                    (dep-natives d)))
        (topo-order deps))))

  (define native-root (make-parameter "lib"))
  (define loaded (make-hashtable string-hash string=?))      ; 已载入注册表,保证幂等

  (define (so-ext)
    (let ([m (symbol->string (machine-type))])
      (cond [(string-suffix? "nt"  m) "dll"]      ; Windows
            [(string-suffix? "osx" m) "dylib"]    ; macOS
            [else                     "so"])))     ; Linux/BSD

  (define (native-path pkg soname)                 ; lib/<pkg>/native/<mt>/<soname>.<ext>
    (path-build (native-root) pkg "native"
                (symbol->string (machine-type))
                (string-append soname "." (so-ext))))

  ;; 边缘/显式控制用:常规路径由 activate 统一调用,应用一般无需自己调
  ;; (load-native "sqlite")          → lib/sqlite/native/<mt>/sqlite.<ext>
  ;; (load-native "mypkg" "libfoo")  → lib/mypkg/native/<mt>/libfoo.<ext>
  (define load-native
    (case-lambda
      [(pkg)        (load-native pkg pkg)]
      [(pkg soname)
       (let ([p (native-path pkg soname)])
         (unless (hashtable-ref loaded p #f)                 ; 幂等:已载入不重复
           (unless (file-exists? p)
             (error 'load-native "缺少原生库,先跑 bake build ~a:\n  ~a" pkg p))
           (load-shared-object p)
           (hashtable-set! loaded p #t))
         p)])))
```

> **加载顺序与 Windows**:按依赖拓扑序载入,让"native A 依赖 native B 的符号"先加载 B。Linux `dlopen` 惰性绑定对同批已载入库较宽容;**Windows** 的 `.dll` 在 load 时即解析导入,故 native 的**传递依赖 DLL 须同目录或在 PATH**(见跨平台矩阵)。`activate` 幂等,即便某 lib 仍显式 `load-native` 也不会重复加载。

> 注:`activate` 也可退化为**直接扫 `./lib/*/manifest.ss`** 而非读 lock,适合无 lock 的临时场景;有 lock 时以 lock 为准(可复现)。

## 已有先例(避免重造)

- **Akku**(akkuscm):最主流的 R6RS/R7RS 包管理器,支持 Chez。中心化 curated index + 项目本地 `.akku/lib`,会帮你重写库路径。
- **Raven**:专门给 Chez 的包管理器,更接近 git 风格。
- **snow-fort / snow2**:R7RS 的 snowball 包体系。

Chandler 与它们的差异点:**git-first + Makefile 感知 + 可装系统全局目录**。差异有价值,也正是麻烦来源(见难点 1)。

## Chez 库机制要点

- R6RS 库,靠 `(library-directories)` / `(library-extensions)` 参数搜索,可用环境变量 `CHEZSCHEMELIBDIRS` / `CHEZSCHEMELIBEXTS` 配置。
- 库名 `(foo bar baz)` → 路径 `foo/bar/baz.sls`(或 `.ss`/`.scm`)。
- 源文件 `.sls`/`.sps`/`.scm`;编译产物 `.so`,WPO 产物 `.wpo`。
- Chez **无内建包管理器**;R6RS 库仅通过代码内的 `import` 声明依赖,**没有 manifest 标准**——Chandler 的 `manifest.ss` 正是来补这个空缺。

## 实现难点与缺陷

### 1. 全局安装 vs rebar3 模型 —— 最大的设计张力
rebar3 的精髓恰恰是**不装全局**:每个项目有独立 `_build/`,依赖隔离、版本各管各。而"装进 `/usr/local/share/chez/lib` 或 `~/.local/share/chez/lib`"是**全局共享**,方向相反。后果:

- 项目 A 要 `foo@1.2`、项目 B 要 `foo@2.0`,全局只能一份 → **版本冲突无解**。
- 卸载困难:文件散进共享目录,没有"已安装文件清单"就清不干净。
- `/usr/local` 需 root,权限模型与用户级混在一起,谁遮蔽谁要有确定规则。

**建议**:默认走项目本地 `lib/`(真正的 rebar3 味道,`activate` 即扫此目录,见「运行期激活」),全局安装作为 `chandler install --global` 的可选动作。

### 2. Chez 没有依赖元数据标准
R6RS 库只在代码里用 `import` 声明依赖,没有 rebar.config / Cargo.toml。二选一:

- 自定义清单(即 `manifest.ss`),要求上游配合 —— 存量项目不会有;
- 解析 `import` 表单反推依赖 —— 拿不到版本约束,也拿不到"库名 → git URL"的映射。

这是 Akku 要维护中心化 index 的根本原因。git-first 意味着要在 `manifest.ss` 里显式写 `(库名 → git URL + pin)`。

### 3. 库名 → 文件路径映射不确定
`(import (foo bar))` 映射到 `foo/bar.sls`,搜索根是 `(library-directories)` 某一项。但仓库的库根可能是仓库根、`src/`、`lib/`、`scheme/`,各家不一。**不能无脑把整个仓库拷进 lib 目录**,否则路径出错或撞名。需要"库根探测"或让 `manifest.ss` 声明 `srcdir`(已在 schema 中体现)。

### 4. 编译产物与 ABI 绑定
`.so`/`.wpo` 绑定具体 Chez 版本 + machine type(如 `ta6le`),不可移植。要决定:

- 只发**源码**(各自编译,慢但可移植);
- 还是发**编译产物**(快但一升级 Chez 全废,还要按 machine type 分目录)。

且 Chez 编译库也用 `.so` 扩展名,和 FFI 的 C 共享库同名不同物,极易混淆。

### 5. 原生构建执行 = 任意代码执行 + 约定不通用
> native 构建的完整契约(后端、注入、落点、模型 A/B)见 [bake 文档「自定义原生构建」](chez-bake-build-tool-design.md);此处只列它对 Chandler 侧的约束。

- **安全**:跑依赖仓库里的构建(make/cmake/script)就是 RCE,须 `--allow-build` 显式确认、可审计。`manifest.ss` 的 `(native … (build …))` 就是这份显式授权的落点。**信任标准是"谁写的脚本"**:依赖的构建一律不可信,你自己 `recipe.ss` 的 `run`/`sh` 才可信。
- **路径替换约定**:后端各有事实标准——make 用 autotools 的 **`PREFIX`+`DESTDIR`**,cmake 用 **`CMAKE_INSTALL_PREFIX`**(也认 `DESTDIR`),script 用 bake 传的 **`$NATIVE_OUT`**。三者收敛到同一落点(见下)。
- **落点不变量**:无论哪个后端,产物**必须**落 `<pkg>/native/<machine-type>/<soname>.<ext>`——`load-native` 与 `bake install` 唯一认的位置;bake 构建后校验其存在,不在即报错。

### 6. 版本与可复现性
- git 分支会漂移 → 必须 **pin commit** 并生成 **lockfile**(`manifest.lock`)。
- R6RS 虽有库版本语法 `(foo bar (1 2))`,但几乎无人用、Chez 匹配语义弱,SemVer 式求解**没有原生锚点**,需在 `manifest.ss`/lockfile 层自建(见上「版本区间语法」)。

### 7. 依赖遮蔽与解析顺序
`library-directories` 按序搜索。系统副本与用户副本同名时,谁赢要确定且可解释,否则会出现"装了新版却加载旧版"的玄学。

### 8. 工具自举的鸡生蛋
Chandler 本身是 Chez 程序,分发时不能靠它自己装,需要 `install.sh` 或单文件 boot 脚本。问题小但别忘。

## 结论

技术上最硬的三块:**(a) 没有元数据标准**(须自定义 `manifest.ss`)、**(b) 编译产物 ABI 绑定**(源码 vs 二进制取舍)、**(c) 全局安装与版本隔离的哲学冲突**。Makefile 那条按 `DESTDIR`/`PREFIX` 标准做、并加显式授权,可填掉大半坑。

## 可能的下一步

- `manifest.ss` schema 与 `lib/` 布局 + `(chandler)` 激活 API 已成草案(见上),下一步补**安装/卸载的文件清单机制**(全局安装时的可清除性)。
- 划清 `manifest.ss`(Chandler:依赖=载货)与 [bake](chez-bake-build-tool-design.md) 的 `recipe.ss`(构建步骤)的边界,避免职责重叠。
