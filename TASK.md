# Chandler 任务清单

> v3 中心设计:[designs/06-installed-layout.md](designs/06-installed-layout.md)。
> v4 范围:**健壮性 + 完善化** —— 补齐事务/并发/校验/文档裂缝(详见各 Phase)。
> 工作方法:每个模块固定 5 步 —— 设计 → 测试先行 → 实现 → 跑 `tests/run-tests.sps` 回归 → 小提交。

---

## v4 总览(健壮性 + 完善化)

来源:三路代码审计(registry/install/pack 错误路径 + CLI 命令映射 + TODO/stub 扫描)+ 设计文档审计。

| 决策 | 内容 |
|------|------|
| D20 | registry 写入原子化(temp + rename + fsync) |
| D21 | install/uninstall/switch per-prefix 进程锁 |
| D22 | staging promote 改整目录单次 rename |
| D23 | doctor 直扫 `.registry/*.ss` + 检测 orphan/kind-mismatch |
| D24 | verify-pack 强制 schema + 强制完整性字段 + EXTRA fatal |
| D25 | 补实现 `chandler verify` / `chandler exec`;`tree` 改为 `deps --tree` 别名 |
| D26 | install kind 校验 + switch 验目标 vroot + `--latest` semver |
| D27 | prebuilt 在 resolve 阶段显式报错(关掉半开后门) |
| D28 | 重写 `00-design-principles.md` 对齐 v3(去 setup、去 I3 混合 registry、补 D8-D19) |
| D29 | pack 创建改 temp sibling + rename |
| D30 | registry 格式迁移路径(format 版本号语义) |

### v4 关键决策(已拍板)

| 问题 | 决策 | 理由 |
|------|------|------|
| verify-pack EXTRA 是否 fatal? | **是,致命** | 完整性校验的本意是发现任何偏差;EXTRA 文件可能是注入 |
| prebuilt 怎么办? | **resolve 阶段显式报错** | 补实现是 v5 范畴;现状是静默吞掉的半开后门 |
| `list` 双义如何解决? | **保留 `list` = 全局已装包;locked deps 只用 `deps --list`** | 最小改动;改 README 即可 |
| `verify` / `exec` 实现还是删? | **实现** | 两者都是真实需求(verify 是 CI 关键;exec 是常见操作);实现量小 |
| 锁的粒度? | **per-prefix 一把锁**(`<libdir>/.registry/.lock` 目录锁) | 简单可靠;Chez 无线程并发,进程级足够 |
| 锁的实现? | **`create-directory` 原子性 + 指数退避重试** | 跨 POSIX/Windows;无需文件系统特殊支持 |

---

## Phase 1 — 健壮性:registry 原子写(P0)

| # | 模块 | 状态 | 说明 |
|---|------|------|------|
| 1.1 | `chandler/sexp.ss` | ⏳ | `write-canonical-file` 改 temp + fsync + rename(temp 同目录,保证 rename 原子) |
| 1.2 | `chandler/registry/io.ss` | ⏳ | `write-registered!` 直接复用 1.1 的原子写;`remove-registered!` 幂等性保留 |
| 1.3 | `chandler/test/sexp.ss` | ⏳ | 测试:写中崩溃模拟(写后立即读,验证可读) |

**约束**:temp 文件必须与目标**同目录**(跨目录 rename 不保证原子)。temp 命名:`.<basename>.tmp.<pid>`。fsync 后再 rename。rename 后删 temp(若残留)。

---

## Phase 2 — 健壮性:per-prefix 进程锁 + staging promote(P0)

| # | 模块 | 状态 | 说明 |
|---|------|------|------|
| 2.1 | `chandler/registry/lock.ss`(NEW) | ⏳ | `with-registry-lock! libdir thunk`:`create-directory` 抢锁 + 指数退避 + 超时 + staleness 检测(锁目录里写 pid + 时间戳,过期强抢) |
| 2.2 | `chandler/registry/staging.ss` | ⏳ | `staging-path` 改用 `<name>/<version>` 子目录(避免 `-` 拼接撞路径);新增 `promote-staging!` 单次 rename 整目录到 vroot |
| 2.3 | `chandler/registry.ss` | ⏳ | `install-global`/`uninstall-global`/`switch-active` 全包进 `with-registry-lock!`;install 改用 staging 整目录 promote |
| 2.4 | `chandler/test/registry.ss` | ⏳ | 测试:并发 install 不丢版本(模拟 - 跑两个 install 串行但都改同一 registry);staging promote 后旧 vroot 不残留 |

**约束**:锁超时默认 30s;staleness 阈值 10 分钟(写入进程 pid + 启动时间,超过阈值且 pid 不活则强抢)。Windows `delete-directory` 失败要重试(rename 占用)。

---

## Phase 3 — 健壮性:doctor 重写(P0)

| # | 模块 | 状态 | 说明 |
|---|------|------|------|
| 3.1 | `chandler/registry/io.ss` | ⏳ | 新增 `list-registry-files libdir` —— 只列 `.registry/*.ss` 文件路径,不解析(不过滤坏文件) |
| 3.2 | `chandler/registry.ss` | ⏳ | `doctor-global` 重写:直接扫 `.registry/*.ss`,逐个解析,坏文件 → `malformed-registry` issue;不再依赖过滤过的 `list-registered-names` |
| 3.3 | `chandler/registry.ss` | ⏳ | doctor 新增检测:`orphan-vroot`(扫 `<libdir>/<name>/<version>/` 不在 registry)、`kind-mismatch`(registry kind vs 该 version 是否有 `.chandler/run.sps`)、`name-filename-mismatch`(`.registry/foo.ss` 内 `(name bar)`)、`duplicate-version`(registry 内重复 version 字符串) |
| 3.4 | `chandler/test/registry.ss` | ⏳ | 测试:坏 registry 文件、孤儿 vroot、kind 冲突均被报出 |

---

## Phase 4 — 健壮性:verify-pack 严格化(P0)

| # | 模块 | 状态 | 说明 |
|---|------|------|------|
| 4.1 | `chandler/pack.ss` | ⏳ | `verify-pack`:强制顶层 `(pack ...)` tag(用 `expect-tag`,非 pair 抛受控错) |
| 4.2 | `chandler/pack.ss` | ⏳ | 强制 `(files ...)` 非空 + 每 entry 必须有 `(sha256 ...)` 和 `(size ...)`;缺失 → fatal |
| 4.3 | `chandler/pack.ss` | ⏳ | `EXTRA` 文件 → fatal(计入 `bad`) |
| 4.4 | `chandler/pack.ss` | ⏳ | pack 创建改 temp sibling + rename(D29):写到 `<out>.tmp.<pid>/`,完工后 rename 到 `<out>/` |
| 4.5 | `chandler/test/pack.ss` | ⏳ | 测试:无 hash 的 entry、空 files、EXTRA 文件均 verify 失败 |

---

## Phase 5 — CLI 命令补齐(P1)

| # | 模块 | 状态 | 说明 |
|---|------|------|------|
| 5.1 | `chandler/cli/commands.ss` | ⏳ | `cmd-verify`:读 lock,扫 `_vendor/<dep>/`,逐文件比对 lock 的 `(files ...)` sha256;不一致 exit 65 |
| 5.2 | `chandler/cli/commands.ss` | ⏳ | `cmd-exec`:复用 `env-with-dotenv` + `resolved-libdirs` 设 `CHEZSCHEMELIBDIRS`,然后 `execvp` 透传 |
| 5.3 | `chandler/cli/main.ss` | ⏳ | dispatch 加 `[(verify)`、`[(exec)`、`[(tree)`(tree = `cmd-deps-tree` 别名);`list-tasks` 字符串改为从 dispatch 表生成或只列真实命令 |
| 5.4 | `chandler/test/cli.ss` | ⏳ | 测试:`chandler verify` 干净/脏;`chandler exec -- echo hi` 透传 |

---

## Phase 6 — 设计层小修(P1)

| # | 模块 | 状态 | 说明 |
|---|------|------|------|
| 6.1 | `chandler/registry.ss` | ⏳ | `install-global`:若 registry 已存在,incoming kind 必须与 registry kind 一致,否则报错 |
| 6.2 | `chandler/registry.ss` | ⏳ | `switch-active`:切前验 vroot 存在 + `.chandler/run.sps` 存在,否则 `missing-vroot` / `missing-runner` 报错 |
| 6.3 | `chandler/cli/commands.ss` | ⏳ | `switch --latest` 改 semver 比较(解析 `major.minor.patch`,数值比;含 prerelease 排序) |
| 6.4 | `chandler/resolve.ss` | ⏳ | prebuilt source 在 `git-provider` 分支显式报错 `prebuilt source not yet supported; use git`(D27) |
| 6.5 | `chandler/test/registry.ss` | ⏳ | 测试:lib/app 同名 install 报错;switch 到无 vroot 的版本报错;`--latest` 数值序 |

---

## Phase 7 — 文档同步(P2)

| # | 模块 | 状态 | 说明 |
|---|------|------|------|
| 7.1 | `designs/00-design-principles.md` | ⏳ | 重写:删 `(chandler setup)` §7、改 I3 不变量为中心 registry、§4.1 布局对齐 v3、决策表补 D8-D19 |
| 7.2 | `designs/04-install.md` / `05-pack.md` / `08-launchers.md` / `09-runtime-paths.md` / `11-cli.md` | ⏳ | 对齐 v3(去 setup、改 .registry、加 switch/doctor 新 issue 类型) |
| 7.3 | `README.md` | ⏳ | 命令表加 `env`、改 `list`/`tree` 描述、`verify`/`exec` 描述对齐实现、移除 v2 setup 残留引用 |
| 7.4 | `bootstrap.ss` | ✅ | 适配新 lock 文件名 + 资源约定(原 6.2)——已检查,无需改:bootstrap 只编排 `deps`/`build`/`install` CLI 调用,不直接读写 `manifest.lock`、`resources/`、per-version `.chandler/registry.ss`,也不生成启动器(全由 cmd-install 出 shim);唯一引用的全局路径是 v3 中心 `.registry/chandler.ss`(L274/L320)。回归 450/0。 |

---

## Phase 8 — 其他(P3,可延后)

| # | 模块 | 状态 | 说明 |
|---|------|------|------|
| 8.1 | `chandler/registered.ss` | ⏳ | `(format N)` 版本号语义化 + 迁移路径(老格式 → 新格式的 upgrade 函数) |
| 8.2 | `chandler/proc.ss` | ⏳ | Windows 子进程适配(`open-process-ports` 或 PowerShell 包装) |
| 8.3 | prebuilt 实现 | ⏳ | 真正的 prebuilt 拉取(v5 范畴,这里只占位) |

---

## v3 已完成(历史)

| 决策 | 内容 | 状态 |
|------|------|------|
| D13 | 资源 method B:`<src>/<libpath>/resources/` | ✅ |
| D14 | 文件命名统一 `chandler-` 前缀 | ✅ |
| D15 | lock 吸收 registry 的 `files+sha256` | ✅ |
| D16 | 中心 `.registry/<name>.ss` 管 versions + active | ✅ |
| D17 | 启动器 = 稳定 shim,运行时读 `.registry/` | ✅ |
| D18 | `run.sps` lock 驱动 library-directories | ✅ |
| D19 | `chandler switch` 命令 | ✅ |

| Phase | 状态 | 说明 |
|-------|------|------|
| v3 Phase 1 数据层 | ✅ | registered / lock / manifest / layout |
| v3 Phase 2 registry 门面 | ✅ | data / io / staging / facade |
| v3 Phase 3 管线简化 | ✅ | install / pack / runtime-paths |
| v3 Phase 4 runner + launcher | ✅ | run-sps / shim |
| v3 Phase 5 CLI | ✅ | switch / list / dispatch |
| v3 Phase 6 整合 | 部分 | 测试 ✅ 337/0;bootstrap ⏳(移至 v4 7.4);designs/ ⏳(移至 v4 7.2);README ⏳(移至 v4 7.3) |

## v2 已完成(更早历史)

| Milestone | 状态 |
|-----------|------|
| v2.0 数据层 | ✅ |
| v2.1 install nested | ✅ |
| v2.2 launcher libdirs | ✅ |
| v2.3 pack nested | ✅ |
| v2.5 lib pack(--lib) | ✅ |
| 去 --global + 路径调整 | ✅ |
| APP_ROOT 去除(D8) | ✅ |
| manifest.ss → chandler-manifest.ss | ✅ |
| run.sps 统一 runner | ✅ |
| install resources 落点 fix | ✅ |
| 死代码/死注释清理 | ✅ |
