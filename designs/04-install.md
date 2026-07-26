# 04 — install 操作流水线

> 状态:已实现(v3 + v4 健壮性),对齐 `chandler/install.ss` + `chandler/registry.ss`。
> v3 中心设计见 [06-installed-layout.md](06-installed-layout.md),决策记录见 [TASK.md](../TASK.md)。

## 1. 一句话目标

把 `chandler-manifest.lock` 里的依赖闭包**物化**到版本化中央仓库 `<libdir>/<name>/<version>/{src,<mt>,.chandler/}` 下,更新中心 `.registry/<name>.ss`,为 app 生成稳定 shim 启动器 + `.chandler/run.sps`。整段装在一个**中心注册表事务**里(per-prefix 进程锁 + staging 整目录单次 rename + registry 原子写),失败不留半成品。

## 2. install 命令的形态

### 2.1 `chandler install`(项目根,从 lock 装到全局前缀)

默认行为。从项目根的 `chandler-manifest.lock` 读取已解析的依赖闭包:

- 装项目库自身到 `<libdir>/<name>/<version>/`
- 装各 dep 到 `<libdir>/<dep>/<pin-val>/`(版本目录名 = lock 的 pin val)
- 更新中心 `.registry/<name>.ss`(versions + active)
- app 形态额外生成稳定 shim 启动器(`<bindir>/<app>` POSIX / `<bindir>/<app>.ps1` Windows)+ `<vroot>/.chandler/run.sps`

### 2.2 `chandler install --prefix=<dir>`

装到任意目录。pack 流水线用它作阶段 1(payload),后续追加 envelope。

### 2.3 旗标

| 旗标 | 作用 |
|------|------|
| `--user` | 默认;POSIX `~/.local/share/chez` / Windows `%LOCALAPPDATA%\chez` |
| `--system` | POSIX `/usr/local/chez` / Windows `%ProgramData%\chez` |
| `--prefix=<dir>` | 任意目录(`bin/<app>` 落在 `<dir>/bin`);与 pack 共用 |
| `--force` | 覆盖已存在的同 version vroot(经 staging + promote 走 backup 回滚) |
| `--adopt` | 复用盘上现有 version root(不走 staging,直接登记) |

> v3 删了 `<pack.tar.gz>` 直接 install:prebuilt 仍是 schema-允许但实现暂缓的备选(D12/D27),resolve 阶段显式报错。当前不消费 tarball。

## 3. 落地布局(v3,中心 `.registry/`)

```
<libdir>/                                    例:~/.local/share/chez/
├── .registry/                               中心注册表(D16,NEW)
│   ├── <name>.ss                            每 name 一份,管 versions + active
│   └── staging/                             事务暂存(D15/D22)
│       └── <name>/<version>/                install 期间的临时树,成功后整目录单次 rename 落位
│
└── <name>/                                  例:myapp
    └── <version>/                           version root(I1:自包含)
        ├── src/
        │   ├── <name>.ss                    库入口源码
        │   └── <name>/                      子库 + 资源同居(D13)
        │       ├── <sub>.ss
        │       └── resources/               method B:资源与库源码同居
        │           └── <file>
        ├── <mt>/                            例:ta6le
        │   ├── <name>.so
        │   └── <name>/*.so
        └── .chandler/
            ├── chandler-manifest.ss         清单快照(D14)
            ├── chandler-manifest.lock       闭包 + files+sha256(D15,本 version 自有)
            └── run.sps                      仅 app 有(D18 lock 驱动)
```

> v3 已删的 v2 残留:
> - `<vroot>/.chandler/registry.ss` / `format.ss` / `source.ss` —— **删**,lock 取代
> - `<vroot>/.chandler/index.ss` / `staging/` —— **删**,挪到 `<libdir>/.registry/staging/<name>/<version>/`
> - `<libdir>/.chandler/` —— **删**,中心 `.registry/` 取代

## 4. 流水线

### 4.1 resolve(已完成)

由 `chandler deps` 负责:解析 → 写 `chandler-manifest.lock` → git 依赖 checkout 到 `_vendor/<name>/`。install 只消费 lock,不重新 resolve。

### 4.2 build(已完成)

`chandler build` 进程内编译 lock 闭包 → 各 `_vendor/<dep>/_build/<mt>/`。install 不触发编译,只搬运已编产物。

### 4.3 materialize 到 `<libdir>/<name>/<version>/`

整段包在 `with-registry-lock!` 里(D21,per-prefix 一把锁 `<libdir>/.registry/.lock`),保证并发 install 不丢版本条目;锁超时默认 30s,staleness 阈值 10 分钟。

#### 4.3.1 enumerate + kind 校验(D26)

- `enumerate-lib src <name>` 从源树枚举:`<name>.ss` + `<name>/**` → `src/`;`_build/<mt>/` 过滤 `.bake-manifest`/`.wpo` → `<mt>/`。**与 pack 完全同一函数**,保证 payload 字节级一致(I2)。
- **kind 校验**:incoming kind(`entry` 存在 → `app`,否则 `lib`)与已登记的 `registered-kind` 必须一致,否则报错。防止把 lib 装到 app 的 registry(那个 name 永远无法 active)或反之。

#### 4.3.2 staging + 整目录单次 promote(D22)

```
<libdir>/.registry/staging/<name>/<version>/
  src/...
  <mt>/...
```

- 所有文件先写到 staging(`copy-file`,不走 atomic write —— staging 本来就是私有的)
- promote = **整目录单次 rename** 到 `<libdir>/<name>/<version>/`,原子;失败时 rename 回滚到 backup 位置,不留半成品

> v2 的「逐文件 promote + 失败时逐文件反向删除」已被整目录 rename 取代(D22):一次系统调用即可完成,无「部分 promote」的中间态;POSIX rename + Windows MoveFileEx 都是原子的。

#### 4.3.3 更新 `.registry/<name>.ss`(D20)

`write-registered!` 经 `sexp.ss:write-canonical-file` 走**原子写**:`temp + fsync + rename`(temp 与目标同目录,保证 rename 原子)。命名 `.<basename>.tmp.<pid>`;rename 后清理 temp 残留。

新增一条 `versions.<v>` 条目:

```scheme
(registered
  (format 1)
  (name myapp)
  (kind app)                                  ;; app | lib(从 manifest 推导)
  (versions
    ("0.1.0" (installed-at "2026-07-25T19:11:27")
             (source (path "/home/me/proj/myapp"))
             (installer chandler)))
  (active "0.1.0"))                           ;; 仅 app 有;lib 不带 (active ...)
```

- **首次 install**(无 active):若 kind=app 且 opts 没显式 `set-active: #f`,自动设 active = 此 version
- **后续 install**:不改 active;新 version 只追加到 `versions`,active 留在原值

### 4.4 app 形态:启动器 + run.sps

app 才有的两步,装在 `cmd-install` 而非 `install-global` 内部(注册表事务解耦后):

```
<bindir>/<app>                                POSIX 稳定 shim,生成一次永不重写(D17)
<bindir>/<app>.ps1                            Windows PowerShell 稳定 shim
<vroot>/.chandler/run.sps                     锁驱动挂精确版本(D18)
```

详见 [08-launchers.md](08-launchers.md)。

## 5. 锁与原子性(v4 健壮性)

### 5.1 per-prefix 进程锁(D21)

- 锁位置:`<libdir>/.registry/.lock`(一个目录;不污染用户的 `.registry/`)
- 抢锁:`create-directory` 原子;失败则指数退避(100ms → 200 → ... → 5s)直到 30s 超时
- staleness:锁目录里写 `pid` + `start-time`;若 pid 不活(平台探测)或 `now - start > 10min` 则强抢
- 范围:`install-global` / `uninstall-global` / `switch-active` 全包进 `with-registry-lock!`,一次占锁包住 staging promote + registry read-modify-write

### 5.2 registry 文件原子写(D20)

`write-registered!` 走 `write-canonical-file`:temp 文件 `.<name>.ss.tmp.<pid>` → fsync → rename 覆盖;rename 后删 temp 残留。**temp 必须与目标同目录**(跨目录 rename 不保证原子)。

### 5.3 staging 整目录 promote(D22)

见 §4.3.2。失败回滚:rename 回 staging,staging 已存在但 promote 失败时 backup 回滚路径 = 原地 + 错误报告。

### 5.4 并发不变量

`install-global` 在锁内一次性完成「枚举 → kind 校验 → staging 写入 → 整目录 promote → registry read-modify-write」,中间不释放锁。两个并发 install 串行化执行 → 不会丢版本条目,后到者看到前者写下的完整状态。

## 6. 错误模式

| 触发 | 行为 |
|------|------|
| kind 不一致(incoming `app`,registry 已记 `lib`,或反之) | `install-global` 报错(install 退出码 65) |
| registry 已存在但 malformed | install 失败;`chandler doctor` 报 `malformed-registry`(用户可手动删坏的 `<name>.ss` 后重装) |
| 源树无 installable 文件(`enumerate-lib` 返回空) | 报错 |
| staging promote 失败(rename 撞已有目录且非空,权限不足) | backup 回滚,退出码 70/77 |
| 锁超时(30s 内抢不到) | 退出码 70;提示「another chandler process holds the libdir」 |

## 7. `--allow-build` 何时需要

依赖含 native 代码(FFI)时,Chez 编译会执行任意代码(I5 不变量)。默认拒绝。

- **git source**:native 构建需 `--allow-build[=a,b]`(可指定库名列表);授权绑构建描述哈希写入 `.chandler-approvals`(详见 [12-security.md](12-security.md))
- **prebuilt source**:schema 允许但实现暂缓(D12);`chandler deps` 解析时显式报错 `prebuilt source not yet supported; use git`(D27)

## 8. 与 v2 的差异

| 维度 | v2 | v3 + v4 |
|------|----|---------|
| 注册表 | per-version `<vroot>/.chandler/registry.ss` + index 缓存 | 中心 `<libdir>/.registry/<name>.ss` + `(versions ...)`(D16) |
| staging 位置 | `<vroot>/.chandler/staging/`(撞 - 分隔路径) | `<libdir>/.registry/staging/<name>/<version>/`(D22) |
| staging promote | 逐文件 move + 反向回滚 | **整目录单次 rename**(D22) |
| registry 写 | 直接覆盖 | temp + fsync + rename(D20) |
| 并发 | 无保护 | per-prefix 锁(D21) |
| 启动器 | 生成式,embed VERSION | 稳定 shim,运行时读 `.registry/`(D17) |
| run.sps | scan-libdirs 全扫 | lock 驱动精确挂(D18) |
| `.bake-manifest` / `*.wpo` | install 过滤、pack 不过滤 | 都过滤 |

## 9. 完整示例:git install(myapp 装 http 1.2.0)

```
1. myapp/chandler-manifest.lock:
   (deps
     (http (version "1.2.0") (source (git "https://...")) (rev "abc123")
           (src . "_vendor/http/src") (obj . "_vendor/http/_build/ta6le")))

2. chandler install(myapp 项目根,默认 --user)
   ├─ deps + build 已完成(前提)
   ├─ target-libdir = ~/.local/share/chez,target-bindir = ~/.local/bin
   └─ install-project-payload!(register?=#t):
       with-registry-lock!(~/.local/share/chez)        ; D21
         ├─ enumerate-lib + kind 校验                   ; D26
         ├─ with-staging! ~/.local/share/chez/myapp/0.1.0:
         │    copy-file ... → staging/...               ; D22
         │    promote-staging! → ~/.local/share/chez/myapp/0.1.0  ; 单次 rename
         └─ write-registered! .registry/myapp.ss        ; D20 temp+fsync+rename
              (active "0.1.0")                          ; 首次 install

   └─ write-app-launcher! myapp 0.1.0 (myapp) main:
        ~/.local/bin/myapp                             ; 稳定 shim
        ~/.local/share/chez/myapp/0.1.0/.chandler/run.sps  ; lock 驱动
```

## 10. 完整示例:重装覆盖(同 name 同 version)

```
chandler install --force
  → with-registry-lock!:
      kind 一致(已有 registry 仍是 app)
      staging 拷新文件
      promote-staging!:rename staging 到 vroot;
                        旧 vroot 内容被替换(若 rename 撞已有目录,
                        backup 回滚路径 = 原地 + 错误)
      write-registered!:versions 已有 "0.1.0" 条目 → 替换 installed-at + source + installer
```

`versions.<v>` 条目被替换,active 保持不变。

## 相关文档

- [06-installed-layout.md](06-installed-layout.md) — v3 中心设计(布局、registry、method B、lock 驱动)
- [03-central-repo.md](03-central-repo.md) — 中央仓库布局(中心 `.registry/`)
- [05-pack.md](05-pack.md) — pack 流水线(reuse install-project-payload!)
- [08-launchers.md](08-launchers.md) — 稳定 shim + run.sps(D17 + D18)
- [11-cli.md](11-cli.md) — `chandler install` 命令面 + 退出码
- [12-security.md](12-security.md) — `--allow-build` 授权模型