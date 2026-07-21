# git 获取与缓存设计

> 原则:**网络操作全部走缓存间接层**;`lib/` 里的 checkout 永远从本地缓存物化,可复现、可离线、多项目共享。Chandler 不内嵌 git 实现,**shell out 到系统 `git`**(自成体系约定:开发机必有 git;免去 libgit2 绑定与凭证难题——凭证/代理/SSH 全由用户已有 git 配置接管)。

## 1. 缓存布局

```
~/.cache/chandler/                     ; $XDG_CACHE_HOME 优先;macOS ~/Library/Caches/chandler;Windows %LOCALAPPDATA%\chandler\cache
  git/
    <url-key>/                         ; 裸仓库(--bare --mirror)
  meta/
    <url-key>.refs                     ; 最近一次 ls-remote 快照 + 时间戳(解析期减少网络往返)
```

- **`<url-key>` = URL 规范化后 + sha256 前 16 位**:规范化(去尾 `/`、去 `.git`、scheme/host 小写)后哈希,再拼一段可读残端(如 `github.com-x-http-a1b2c3d4`)便于人工排查。同库不同写法(https/ssh、带不带 `.git`)**归并到同一缓存**——规范化只为 key,fetch 仍用原 URL(权限可能不同)。
- 裸镜像仓(`git clone --mirror`),后续 `git fetch` 增量更新;不留工作区。

## 2. 操作到 git 命令的映射

| Chandler 操作 | git 实现 |
|---------------|----------|
| 首次遇到 URL | `git clone --mirror <url> <cache>/git/<key>` |
| 解析 branch → rev | 缓存有 → `git rev-parse <branch>`(必要时先 fetch);`update` 强制 `git fetch` 后再 rev-parse |
| 解析 tag / 列 tag(version 区间) | `git tag --list`(缓存内);无匹配 → fetch 一次再试 |
| rev 是否已有 | `git cat-file -e <rev>^{commit}`;无 → fetch |
| 物化到 `lib/<name>/` | `git clone --shared <cache>/git/<key> lib/<name>` + `git checkout --detach <rev>`(见 §3) |
| 完整性 | rev 即内容哈希,git 对象模型自带校验;不另做 sha256 |

fetch 策略:能满足解析就**不碰网**(tag/rev pin 且缓存命中 → 零网络);只有 branch 解析、`update`、缓存未命中才 fetch。

## 3. 物化方式:本地 clone(带 `.git`)而非导出

`lib/<name>/` 用 `git clone --shared` + detached checkout,**保留 `.git`**,而不是 `git archive` 导出纯文件。理由:

- `verify` 直接 `git rev-parse HEAD` 对 lock、`git status --porcelain` 查脏改动——不用自建文件哈希清单;
- 用户临时改依赖调试后,状态可见、可 diff、可 stash;`install` 遇脏默认拒动(见 [01](01-cli.md));
- `--shared` 借缓存对象库,几乎零拷贝。

代价:`lib/` 略大、`.git` 会进编辑器搜索。提供 `--export` 开关切到 archive 纯导出模式(此时 `verify` 退化为「存在性检查」并警告)。**`lib/` 应进项目 `.gitignore`**(`init` 生成时自动写入)——依赖不 vendoring 进项目仓库,lock 才是提交物;确要 vendor 的用 `--export` 且自担 verify 降级。

## 4. 离线模式与失败语义

| 情形 | 行为 |
|------|------|
| `--offline` 且解析/物化全可由缓存满足 | 正常完成 |
| `--offline` 且缓存未命中 | EX_UNAVAILABLE,报缺哪个 URL 的哪个 rev |
| 在线但 fetch 失败(网络/权限) | 报错并提示:该 URL 用户 git 配置是否可达(凭证归 git 管) |
| CI 建议 | 缓存目录可整体作为 CI cache key(`chandler cache dir` 输出路径);lock 在手 + 缓存命中 = 完全无网构建 |

## 5. 缓存管理

- `chandler cache dir` — 打印缓存根(脚本/CI 用);
- `chandler cache list` — 各镜像仓 URL、大小、最后 fetch 时间;
- `chandler cache clean [--all | <url>…]` — 删除镜像;因 `--shared` clone 依赖缓存对象库,**clean 前检查**:提示哪些项目的 `lib/` 还借着它(缓存侧记 borrow 清单,尽力而为),`--all` 需二次确认;误删后果 = 相应 `lib/` 损坏,重跑 `install` 可恢复(rev 在 lock 里)。

> 若 borrow 追踪证明不可靠,退路是物化改默认 `--export`(纯拷贝、无借用),把 `--shared` 降为优化选项。此取舍留待实现期实测。

## 6. 并行获取

解析期 frontier 内各依赖的 clone/fetch **并行**(进程级:并发 `git` 子进程,上限默认 4);同一 `<url-key>` 上锁(文件锁 `<cache>/git/<key>.lock`)防止两个 Chandler 实例并发写同一镜像。

## 相关文档

- [03-resolution.md](03-resolution.md) — 谁在何时触发 fetch
- [01-cli.md](01-cli.md) — `cache` 子命令与 `--offline`
