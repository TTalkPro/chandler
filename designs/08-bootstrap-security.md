# 自举、分发与信任模型

> 收尾两个总设计难点:难点 8(工具自举的鸡生蛋)与难点 5(原生构建 = RCE)的完整策略,外加 Chandler 自身的分发形态。

## 1. Chandler 自身形态

Chandler = **一个库 + 一个入口**,都按[布局规范](../chez-skiff-library-layout.md)组织:

```
chandler/                        ; 本仓库
  chandler.ss                    (library (chandler))        ; umbrella:activate/load-native/registry…
  chandler/…                     ; 子库:lock/layout/sexp/registry/cli/…
  bin/chandler                   ; 入口:sh wrapper → scheme --program chandler/cli/main.sps
  tests/  designs/  manifest.ss  recipe.ss
```

运行形态按环境递进(同一份源码):

| 形态 | 启动 | 场景 |
|------|------|------|
| 解释执行 | wrapper 里 `scheme --libdirs <prefix>/src::<prefix>/<mt> --program <prefix>/src/chandler/cli/main.sps …` | 自举第一步、开发期 |
| 编译 `.so` 树 | 同上,命中已编译产物 | 正常安装态(bake 编的) |
| whole-program boot | `scheme --boot chandler.boot` | 可选优化,`bake exe` 出 |

不做 standalone exe(与 bake 交付物模型结论一致):目标机必有 Chez——**Chandler 是 Chez 的包管理器,Chez 在场是前提**,不是负担。

## 2. 自举:`install.sh` + `install-self`(**基于 bake install**)

**chandler 是库,bake 装库,故 chandler 自安装直接复用 `bake install`**——不再自写一套库树拷贝(去掉与 bake `install-task` 的重复),chandler 只补 bake 不管的**运行时发现启动器**。

```
git clone + ./install.sh [--global | --force]:
  install.sh(薄壳):
    1. 前置:确认 bake 可用(自安装委托它);缺则报错指路
    2. 运行时发现,顺序 `skiff scheme chez chez-scheme chezscheme`(skiff 优先 + 能力探测,designs/06)
    3. exec <rt> --libdirs <repo> --program <repo>/chandler/cli/main.sps install-self "$@"
       (设 CHANDLER_SRC=<repo> 供 install-self 定位源根)
  chandler install-self(chandler/cli/selfinstall.ss):
    4. prefix = --global ? /usr/local/share/chez : $HOME/.local/share/chez(与 bake target 对齐,含 src/ 与 <mt>/)
    5. 库树 → 委托 `bake install`(或 `bake install-global`),cwd=源码 checkout,读其 recipe.ss
       bake 把源码(chandler.ss + chandler/**)拷到 <prefix>/src/、编译 `.so` + native 拷到 <prefix>/<mt>/,并写 <prefix>/.bake-install/chandler.files 清单
    6. 写运行时发现启动器 → <bindir>/chandler(POSIX,sh)或 <bindir>/chandler.ps1(Windows,PowerShell);skiff 优先;PATH 提示
```

- **落点与 bake target 对齐**:bake `(target user)` = `$HOME/.local/share/chez`、`(target global)` = `/usr/local/share/chez`——恰是 chandler 的前缀。`recipe.ss` 提供 `install`/`install-global`(及对应 uninstall)两组 install-task 供 install-self 选调。源码落 `<prefix>/src`(Chez 库搜索根)、编译 `.so` + native 落 `<prefix>/<mt>`,消费方挂 `<prefix>/src::<prefix>/<mt>` 对,`(import (chandler))` 可解析——兑现「机制三件套」之一。
- **自举入口两平台各一**:`install.sh`(POSIX)与 `install.ps1`(Windows PowerShell),语义一致——检查前置 `bake`、
  发现运行时(同一套探测判据)、认 `CHANDLER_RUNTIME`/`CHANDLER_SKIFF`/`CHANDLER_SCHEME`,再 exec `chandler install-self`。
  两脚本各自内嵌一份探测程序文本(自举期 chandler 尚未安装,无法 import),故注明与 `self-probe-src` 保持同步。
- **启动器 = 运行时发现 + 能力探测**(两平台同语义:POSIX 出 `chandler` sh 脚本,**Windows 出 `chandler.ps1`**——
  PowerShell 已取代 cmd,且 PATH 上的 `.ps1` 可裸名 `chandler` 调用;正斜杠 + `[System.IO.Path]::PathSeparator`
  使同一份脚本在 Windows 正确、在 Linux 的 pwsh 下也能实跑,`tests/powershell-run.sh` 即据此端到端验证):
  生成的启动器按 `skiff scheme chez chez-scheme chezscheme` 逐个查找;Chez 各名已知可运行程序直接用,**非 Chez 运行时(skiff 等)须先过能力探测**——喂一段 R6RS 程序,输出 `<token>:<skiff 版本>`。
  自 skiff 以内置 `(skiff-version)` 自证版本起,判据收紧为**口令 + 数字打头的版本**:一次调用同时确认「能跑程序」
  与「确实是 skiff」。原先只验口令,一个能跑程序但并非 skiff 的同名可执行文件会被误采纳。命中即 `exec <rt> --libdirs <prefix>/src::<prefix>/<mt> --program <prefix>/src/chandler/cli/main.sps "$@"`;皆无 → exit 127。
  `CHANDLER_RUNTIME=skiff|chez` 可**强制**某一种(非法值 → 64),`CHANDLER_SKIFF`/`CHANDLER_SCHEME` 指定具体可执行文件;
  强制时照单执行、不探测不回退(见 [06 §3](06-runtime-compat.md))。
  - **为何要探测**:早期 skiff(如 `0.0.0-dev`)是 demo stub——吞掉旗标、只打印 banner、退出码仍 0,靠顺序/退出码无法回退。探测让启动器**今天**跳过 stub 用 Chez,而 skiff 成熟(支持 `--program`)后**自动**被优先选用,无需改启动器。skiff 是 Chez 超集,`--libdirs`/`--program` 语义一旦实现即通用。
- **卸载自洽、不依赖源码**:`chandler uninstall-self` 直接读 bake 的 `<prefix>/.bake-install/chandler.files`(绝对路径逐行)删库 + 清空父目录 + 删清单,再删启动器。装后源码删了也能卸。
- 后续升级:`chandler self-update` = `git pull && ./install.sh`(install-self 的 `--force` 先据清单卸旧库再装)。
- 生态自举全序:**bake(自装,script-app 自拷)→ chandler(bake 装库 + 自补启动器)→ 应用**。bake 是 script-application 不能用 install-task 自装,故自拷;chandler 是库,直接 `bake install`——两者分工正好体现「库 vs 脚本应用」的安装差异。

## 3. 信任模型(全生态汇总)

分级标准只有一条:**这段代码谁写的**(bake 总设计既定),而非用什么后端/语言:

| 代码 | 信任 | 执行条件 |
|------|------|----------|
| 你的 `recipe.ss`(`run`/`sh`) | 可信 | 无条件(bake 直接跑) |
| 你 manifest 里 `path` native 的构建 | 可信 | `chandler build` 默认放行 |
| **依赖的** native 构建(make/cmake/script) | 不可信 | `--allow-build`(可白名单到包名)显式授权 |
| 依赖的 `recipe.ss` | 不可信 | **永不执行**(compile-tree 走布局约定,见 [07 §2](07-bake-integration.md)) |
| 依赖的 `manifest.ss` / lock / pack.manifest | 数据 | 只 `read` 不求值(`(chandler sexp)` 统一入口,读到非白名单结构即拒) |
| 你 manifest 的 `scripts`(postinstall 等) | 可信(你写的名) | 只跑具名脚本;**依赖的 scripts 永不执行** |

补充红线:

- **clone/checkout 本身零执行**:git hook 不带出(`core.hooksPath=/dev/null` 显式设防)、不因 checkout 触发任何依赖侧代码;
- 解析/安装路径上**唯一**可能执行依赖代码的点就是获批的 native 构建——审计面收敛到一处;
- `--allow-build` 的授权**记录进 lock 旁注**(`manifest.lock` 同目录 `.chandler-approvals`:包名+构建描述哈希);构建描述变了(命令/脚本内容 rev 变化)→ 授权失效重新提示——防「先给个无害脚本骗授权,更新后换恶意脚本」;
- 传输安全交给 git(https/ssh + 用户凭证配置);rev 全长锁定 = 内容寻址,重放/篡改由 git 对象哈希兜底。

## 4. 威胁清单对照

| 威胁 | 缓解 |
|------|------|
| 恶意依赖构建脚本 RCE | `--allow-build` + 描述哈希绑定授权 + 白名单粒度 |
| manifest 数据注入(读时求值) | 纯 `read` + 结构白名单,永不 `eval`/`load` 清单 |
| git hook 执行 | hooksPath 置空 |
| 依赖仓库被顶替(URL 劫持/force-push) | lock 锁全长 rev,物化只认 rev;`verify` CI 卡关 |
| 撞名库(同名不同物) | 解析 R4:异域同名默认硬错([03 §2](03-resolution.md)) |
| 全局目录投毒(野文件遮蔽) | 注册表 + `doctor` 野文件检测([05](05-install-registry.md)) |
| install.sh 供应链 | 发布物给 sha256;推荐 git clone + 审阅后执行的路径并列文档首位 |

## 5. 开放问题(留待实现期)

1. `.chandler-approvals` 是否该进版本库(团队共享授权 vs 各自审计)——倾向进库,如 lock;
2. 私有依赖的 CI 凭证注入指引(纯 git 配置问题,写文档即可,不进工具);
3. 签名/来源证明(git tag 签名校验 `--verify-signatures`)——v2 再议,git-first 下有现成挂点。

## 相关文档

- [05-install-registry.md](05-install-registry.md) — 自举复用的注册表事务
- [07-bake-integration.md](07-bake-integration.md) — `--allow-build` 透传与执行分工
- [06-runtime-compat.md](06-runtime-compat.md) — 自举对 Chez 版本下界的探测
