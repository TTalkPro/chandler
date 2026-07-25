# Chandler v3 实施任务

> v3 中心设计:[designs/06-installed-layout.md](designs/06-installed-layout.md)。
> v2 历史见 git log;v3 不兼容 v2,无自动迁移。

## v3 总览

| 决策 | 内容 |
|------|------|
| D13 | 资源 method B:`<src>/<libpath>/resources/`(与库源码同居) |
| D14 | 文件命名统一 `chandler-` 前缀(`chandler-manifest.lock`) |
| D15 | lock 吸收 registry 的 `files+sha256`(Method Y) |
| D16 | 中心 `.registry/<name>.ss` 管 versions + active |
| D17 | 启动器 = 稳定 shim,运行时读 `.registry/` |
| D18 | `run.sps` lock 驱动 library-directories |
| D19 | `chandler switch` 命令(版本切换) |

## Phase 1 — 数据层(纯函数)

| # | 模块 | 状态 | 说明 |
|---|------|------|------|
| 1.1 | `chandler/registered.ss` | ✅ | 中心注册表数据类型(record + 函数式更新 + 序列化) |
| 1.2 | `chandler/lock.ss` | ✅ | 加 `(files ...)` 字段;重命名 `chandler-manifest.lock` |
| 1.3 | `chandler/manifest.ss` | ✅ | 删 `(resources ...)` 字段(静默忽略旧字段) |
| 1.4 | `chandler/layout.ss` | ✅ | 资源路径 method B:`lib-resource-dir` |

## Phase 2 — registry 门面拆分

| # | 模块 | 状态 | 说明 |
|---|------|------|------|
| 2.1 | `chandler/registry/data.ss` | ✅ | re-export `registered` |
| 2.2 | `chandler/registry/io.ss` | ✅ | read/write `.registry/<name>.ss` |
| 2.3 | `chandler/registry/staging.ss` | ✅ | staging 目录事务 |
| 2.4 | `chandler/registry.ss` | ✅ | facade;`install-global`/`uninstall-global`/`switch-active`/`doctor-global`/`list-global` |

## Phase 3 — 管线简化

| # | 模块 | 状态 | 说明 |
|---|------|------|------|
| 3.1 | `chandler/install.ss` | ✅ | 删 `install-project-resources!`;lock 路径改名 |
| 3.2 | `chandler/pack.ss` | ✅ | 删 `copy-resources!`/`copy-share!`;pack 加 `.bake-manifest`/`*.wpo` 过滤 |
| 3.3 | `chandler/runtime-paths.ss` | ✅ | Phase 1.4 已完成 |

## Phase 4 — runner + launcher

| # | 模块 | 状态 | 说明 |
|---|------|------|------|
| 4.1 | `run-sps-content` | ✅ | install/pack 模式都改 lock 驱动(D18) |
| 4.2 | launcher 模板 | ✅ | 稳定 shim,POSIX + Windows 读 `.registry/<name>.ss`(D17) |

## Phase 5 — CLI 命令

| # | 模块 | 状态 | 说明 |
|---|------|------|------|
| 5.1 | `cmd-switch` | ✅ | **NEW**:`<name> <version>` / `--latest` / `--list` |
| 5.2 | `cmd-list` | ✅ | 适配 v3 row 格式,标 [active] |
| 5.3 | `main.ss dispatch` | ✅ | switch 加进命令表 + usage |

## Phase 6 — 整合(部分完成)

| # | 模块 | 状态 | 说明 |
|---|------|------|------|
| 6.1 | 测试套件 | ✅ | 全量 337/0 通过(pack 套件预存损坏,与本工作无关) |
| 6.2 | `bootstrap.ss` | ⏳ | 适配新 lock 文件名 + 资源约定(待做) |
| 6.3 | `designs/` 文档 | ⏳ | 重写 00/04/05/08/09/11 对齐 v3(待做) |
| 6.4 | `README.md` | ⏳ | 用户文档同步(待做) |

## 工作方法

每个模块固定 5 步:

1. **设计**:列函数签名 + 行为契约
2. **测试先行**:`chandler/test/<module>.ss`,每函数 ≥1 测试
3. **实现**:逐函数写,逐个让测试转绿
4. **回归**:跑 `tests/run-tests.sps`
5. **小提交**:模块独立 commit

## v2 已完成(历史)

| Milestone | 状态 | 关键 commit |
|-----------|------|------------|
| v2.0 数据层 | ✅ | `37db998` `737c111` `a228b8c` |
| v2.1 install nested | ✅ | `d579cdc` |
| v2.2 launcher libdirs | ✅ | `b7a864f` |
| v2.3 pack nested | ✅ | `2051200` `58b758b` `6db94dc` |
| v2.5 lib pack(--lib) | ✅ | `b693bb0` |
| 去 --global + 路径调整 | ✅ | `bf0a987` |
| APP_ROOT 去除(D8) | ✅ | `4f1b8e3` |
| manifest.ss → chandler-manifest.ss | ✅ | `1bd34a1` |
| run.sps 统一 runner | ✅ | `f2adda8` `0feffc7` |
| install resources 落点 fix | ✅ | `171a0ff` |
| 死代码/死注释清理 | ✅ | `5e794a0` |

## v2 备选(暂缓)

| Milestone | 说明 |
|-----------|------|
| prebuilt 远程分发 | HTTP 下载 + sha256 + mt-gate(schema 已定义,实现暂缓) |
