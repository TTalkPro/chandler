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
| 解释执行 | wrapper 里 `scheme --libdirs <安装根> --program …` | 自举第一步、开发期 |
| 编译 `.so` 树 | 同上,命中已编译产物 | 正常安装态(bake 编的) |
| whole-program boot | `scheme --boot chandler.boot` | 可选优化,`bake exe` 出 |

不做 standalone exe(与 bake 交付物模型结论一致):目标机必有 Chez——**Chandler 是 Chez 的包管理器,Chez 在场是前提**,不是负担。

## 2. 自举:`install.sh` + `install-self`(对齐 bake,打破鸡生蛋)

**模型与 [bake](../chez-bake-build-tool-design.md) 一致**:`install.sh` 是**薄壳**,只做运行时发现后把安装逻辑委托给工具自身的 `install-self` 子命令(而非另写一套 bootstrap)。

```
git clone + ./install.sh [--prefix DIR | --global | --force]:
  install.sh(薄壳):
    1. 运行时发现,顺序 `skiff scheme chez chez-scheme chezscheme`(skiff 优先,designs/06)
    2. exec <rt> --libdirs <repo> --program <repo>/chandler/cli/main.sps install-self "$@"
       (设 CHANDLER_SRC=<repo> 供 install-self 定位源根)
  chandler install-self(逻辑本体,chandler/cli/selfinstall.ss):
    3. prefix = --prefix > --global(/usr/local)> $HOME/.local(默认)
    4. 拷 chandler.ss + chandler/**(跳过 test/)→ <prefix>/share/chez/lib/
    5. 写运行时发现启动器 → <prefix>/bin/chandler(同样 skiff 优先)
    6. 写 <prefix>/share/chez/lib/.chandler-self.files 清单(干净卸载依据)
    7. PATH 提示;已装则 guard 报错(--force 覆盖)
```

- **布局对齐 bake**:`<prefix>/share/…` 放库树、`<prefix>/bin/<tool>` 放启动器、`.<tool>-self.files` 清单;chandler 的库树落 `share/chez/lib`(Chez 库搜索根),使 `(import (chandler))` 可解析——兑现「机制三件套」之一。
- **启动器 = 运行时发现**:生成的 `bin/chandler`(及开发期 `bin/chandler`)按 `skiff scheme chez chez-scheme chezscheme` 逐个 `command -v`,首个命中即 `exec <rt> --libdirs <home> --program <home>/chandler/cli/main.sps "$@"`;皆无 → exit 127。skiff 是 Chez 超集,`--libdirs`/`--program` 通用。
- **卸载自洽**:`chandler uninstall-self` 据 `.chandler-self.files` 逐文件删除 + 清空父目录。
- 后续升级:`chandler self-update` = `git pull && ./install.sh`(install-self 的 `--force` 覆盖旧树)。
- 生态自举全序:**skiff/Chez → Chandler → bake(chandler 装)→ Skiff/应用**;bake 编译 Chandler 的 `.so` 树是锦上添花,没有 bake 也完全可用(解释执行)。

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
