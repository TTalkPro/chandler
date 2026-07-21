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

## 2. 自举:`install.sh`(打破鸡生蛋)

```
curl … | sh   (或 git clone + ./install.sh):
  1. 探测 scheme(PATH / CHANDLER_SCHEME);无 → 报错并指路装 Chez;校验版本下界
  2. git clone chandler 仓库到 ~/.cache/chandler/self/(或就地)
  3. 用**解释执行**的 chandler 给自己走一遍正常安装:
       scheme --script bootstrap.ss
       ; bootstrap.ss = 精简版 install --global 用户级:
       ;   拷 chandler.ss + chandler/ 到 ~/.local/share/chez/lib/
       ;   写注册表([05] 格式,installer=bootstrap)
       ;   装 bin/chandler wrapper 到 ~/.local/bin/
  4. 提示把 ~/.local/bin 加 PATH;打印 chandler --version 验证
```

- **自举用正门**:bootstrap.ss 直接复用 `(chandler registry)` 事务代码(解释执行),不是另一套拷贝逻辑——装完的 Chandler 能用 `chandler uninstall --global chandler` 卸掉自己,注册表自洽。
- `(chandler)` 库落进用户级 libdir,兑现总设计「机制三件套」之一:`(import (chandler))` 永远可解析。
- 后续升级:`chandler self-update` = 对自己仓库 fetch + 重跑正常安装事务(升级路径 [05 §4](05-install-registry.md))。
- 生态自举全序:**Chez → Chandler → bake(chandler 装)→ Skiff/应用**;bake 编译 Chandler 的 `.so` 树是锦上添花(形态表第 2 行),没有 bake 也完全可用(解释执行)。

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
