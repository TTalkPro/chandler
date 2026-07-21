# 全局安装/卸载的文件清单机制

> 总设计难点 1 点名的下一步:「补安装/卸载的文件清单机制(全局安装时的可清除性)」。本文定义**已装文件注册表**,让 `--global` 安装可审计、可干净卸载、可检测冲突。适用于 `chandler install --global` 与 `bake install`(两工具共用同一注册表格式与落点,见 [07](07-bake-integration.md))。

## 1. 落点与注册表位置

| 级别 | 库落点 | 注册表 |
|------|--------|--------|
| 用户级(默认) | `~/.local/share/chez/lib/` | `~/.local/share/chez/lib/.chandler/registry/` |
| 系统级(`--global --system`,需 root) | `/usr/local/share/chez/lib/` | 同上目录下 `.chandler/registry/` |

注册表**与库目录同居**(`<libdir>/.chandler/`):库目录被整体挪走/挂载时清单跟着走;`.` 前缀目录不构成库名前缀,Chez 搜索不受扰。

## 2. 注册表格式:每包一文件

`<libdir>/.chandler/registry/<name>.ss`,与生态一致的可 `read` s-表达式:

```scheme
(installed
  (format 1)
  (name    "chez-markding")
  (version "1.4.0")
  (source  (git "https://github.com/x/chez-markding") (rev "9f8e…"))  ; path 安装则 (path "/abs/src")
  (installed-at "2026-07-21T10:30:00Z")     ; 由调用方传入时钟(纯记录,不参与逻辑)
  (installer chandler)                       ; chandler | bake(谁装的,诊断用)
  (files                                     ; 相对 <libdir> 的全部落盘文件;目录不记,按需清空
    ("chez-markding.ss"                (sha256 "ab12…"))
    ("chez-markding/syntax/block.ss"   (sha256 "cd34…"))
    ("chez-markding/native/ta6le/md.so"(sha256 "ef56…"))
    ("chez-markding/syntax/block.so"   (sha256 "…") (compiled ta6le "10.3.0"))))  ; --with-compiled 产物,标 ABI
```

- **`files` 是卸载的唯一依据**;哈希用于 `--global verify`(检测被外力篡改)与升级时的「动没动过」判断。
- 编译产物条目带 `(compiled <mt> <chez-version>)` 注解:Chez 升级后可用 `chandler doctor --global` 找出全部失效 `.so`。

## 3. 安装事务(冲突检测 → 落盘 → 登记)

```
install --global:
  1. 源侧校验:name = 目录名(布局规范三合一;此处升级为硬错误)
  2. 计划集:待拷贝文件相对路径全列出
  3. 冲突检测:计划集中任一路径已存在于 <libdir> 且
       属于其它包的 registry → EX_CANTCREAT,报「文件被 <pkg> 占有」
       不属于任何 registry(野文件)→ 默认拒绝,--adopt 收编
       属于本包旧版本 → 进入升级路径(§4)
  4. 落盘:先全部拷到 <libdir>/.chandler/staging/<name>/,fsync 后逐个 rename 进位
  5. 登记:写 registry/<name>.ss(最后写——registry 存在 = 安装完整)
  6. 失败回滚:任何一步失败,按已进位清单反向删除,staging 清理
```

staging + 「registry 最后写」给出弱事务性:中断后要么无 registry(视为未安装,残留由 `doctor` 清)、要么 registry 完整可信。

## 4. 升级与卸载

| 操作 | 行为 |
|------|------|
| 升级(同名再装) | 读旧 registry → 新计划集落盘 → **删除旧 files 中不在新集者**(孤儿清理)→ 覆写 registry。旧文件哈希不符(用户改过)→ 列出并要求 `--force` |
| `chandler uninstall --global <name>` | 读 registry → 逐文件哈希核对(不符则警告仍删,`--keep-modified` 保留)→ 删文件 → 删空目录(仅删因此变空者)→ 删 registry |
| `chandler list --global` | 枚举 registry:名、版本、来源、装机时间、谁装的 |
| `chandler doctor --global` | 全量体检:野文件、缺失文件、哈希漂移、ABI 失效的 `.so`、残留 staging |

## 5. 遮蔽规则(难点 7 的确定化)

搜索优先级由 `activate`/运行时装配的 `library-directories` 顺序**固定**为:

```
项目 lib/(activate 挂的)  >  用户级 libdir  >  系统级 libdir  >  Chez 内建
```

- 同名库多级并存 = 合法(项目 pin 压倒全局);`chandler doctor` 显示遮蔽关系(「(http) 解析到项目 lib/,遮蔽了用户级 1.1.0」),玄学变可见。
- 用户级/系统级之间**不做版本比较**,纯顺序遮蔽——注册表里有版本,`doctor` 负责告知,不负责裁决。

## 6. 与 bake install 的关系

`bake install` 装**本项目自身**、`chandler install --global` 装**任意 git 库**,两者最终都走本文的注册表事务(同一格式、同一冲突规则),实现上共享一个 `(chandler registry)` 库(bake 依赖它,见 [07 §共享库](07-bake-integration.md))。`installer` 字段记录来源;`uninstall` 两边都能卸对方装的包。

## 相关文档

- [01-cli.md](01-cli.md) — `--global` 命令入口
- [07-bake-integration.md](07-bake-integration.md) — 与 bake 共享注册表实现
