# 07 — `(chandler setup)` 启动钩子

> 状态: 设计中

## 1. 一句话目标

在 install/pack 模式下,app 启动时通过 `(import (chandler setup))` 读取 `manifest.lock`,动态重写 `(library-directories)`,精确锁定依赖版本——等价 Ruby Bundler 的 `require 'bundler/setup'`。

## 2. 背景与动机

### 2.1 为什么不沿用启动器硬编码路径

v1 曾用启动器(`bin/myapp`)直接写死 `--libdirs /prefix/src :: /prefix/mt`。这在 v2 不可接受:

| 问题 | 说明 |
|------|------|
| **版本管理复杂** | 一个 prefix 下并存多个 `<name>/<version>/`,硬编码 prefix 无法定位到具体 version |
| **共享升级困难** | 系统升级某个 lib 版本,所有引用它的 app 都受影响,无法独立锁定 |
| **跨平台启动器** | POSIX sh 和 Windows PowerShell 要分别维护两份模板,sh/ps1 路径逻辑各异 |
| **违背 D4 决策** | 00 §10 D4 明确选择 Bundler 模型,启动器不应含版本逻辑 |

### 2.2 Bundler 类比

| Bundler | Chandler v2 |
|---------|-------------|
| `require 'bundler/setup'` | `(import (chandler setup))` |
| `Gemfile.lock` | `manifest.lock` |
| `$LOAD_PATH` | `(library-directories)` |
| `bundle install` | `chandler install` |
| `bundle exec` | 由启动器自动执行 run.sps |

## 3. 库形态

```scheme
(library (chandler setup)
  (export)
  (import (chezscheme)
          (chandler layout)
          (chandler fs))
```

**副作用库**:export 为空,`import` 即触发生效(重写 `(library-directories)`)。

## 4. 四步流程

### 4.1 步骤总览

```
(car (command-line))          反推 run.sps 绝对路径
         ↓
path-parent                   剥一层 → <name>/<version>/.chandler/
         ↓
读 manifest.lock              此 version 的 resolve 闭包
         ↓
重写 (library-directories)    per-package-version 的 (src . obj) 对列表
```

### 4.2 详细说明

#### 步骤 1: 反推 run.sps 绝对路径

启动器以 `--program run.sps` 形式调用 runtime,`(car (command-line))` 即 `run.sps` 的绝对路径。

**run.sps 位置约定**:

| 模式 | 路径 |
|------|------|
| install | `<prefix>/.chandler/<name>/run.sps` |
| pack | `<pack-root>/<name>/<version>/.chandler/run.sps` |

#### 步骤 2: 定位 manifest.lock

```scheme
(define (manifest-lock-path run-sps-path)
  ;; run.sps 位于 <name>/<version>/.chandler/run.sps
  ;; 连续两次 path-parent 回到 <name>/<version>/,再拼 .chandler/manifest.lock
  (let* ([version-dir  (path-parent (path-parent run-sps-path))]
         [chandler-dir  (path-parent version-dir)]  ; <name>/
         [lock-file     (join-paths chandler-dir ".chandler/manifest.lock")])
    lock-file))
```

#### 步骤 3: 解析 manifest.lock

`manifest.lock` 包含该 version 的完整 resolve 闭包:

```scheme
;; manifest.lock 结构(详见 01-manifest-lock.md)
(lock
  (format 1)
  (name myapp)
  (version "1.0.0")
  (chandler ">=0.2.0")
  (deps
    (http (version "1.2.0") (source (git ...))
          (src . "<prefix>/http/1.2.0/src")
          (obj . "<prefix>/http/1.2.0/ta6le"))
    (json (version "0.9.0") (source (git ...))
          (src . "<prefix>/json/0.9.0/src")
          (obj . "<prefix>/json/0.9.0/ta6le"))))
```

setup 读取 `(lock-deps lk)`,为每个 dep 生成 `(src . obj)` 对。

#### 步骤 4: 重写 library-directories

```scheme
(define (activate-from-lock! lk chandler-prefix)
  (let ([mt (current-machine-type)]
        [new-entries
         (map (lambda (d)
                (cons (dep-src d) (dep-obj d)))
              (filter (lambda (d) (eq? 'lib (locked-dep-kind d)))
                      (lock-deps lk)))])
    ;; 追加 chandler-runtime 自身的 (src . obj) 对,让 setup 自身能被 import
    (let ([chandler-entry (cons
                           (join-paths chandler-prefix "src")
                           (join-paths chandler-prefix mt))])
      (set! library-directories
            (append new-entries (list chandler-entry) (library-directories)))))
```

## 5. 路径反推伪代码

```scheme
;;; 输入: (car (command-line)) = "/home/user/.local/share/chez/.chandler/myapp/run.sps"
;;; 输出: manifest.lock 路径

(define (derive-lock-path cmd0)
  (let* ([run-sps     cmd0]                              ; "/home/.../run.sps"
         [chandler-dir (path-parent run-sps)]            ; "/home/.../.chandler/myapp/"
         [version-dir  (path-parent chandler-dir)]       ; "/home/.../.chandler/"
         [lock        (join-paths version-dir "manifest.lock")])
    lock))
```

## 6. Bootstrap Paradox 解决

setup 自身是 `(chandler setup)`,位于 `chandler-runtime/src/chandler/setup.ss`。它在 setup 接管前必须先被找到。

### 6.1 解决机制

| 模式 | chandler-runtime 来源 | --libdirs 指向 |
|------|---------------------|----------------|
| install | 系统 `~/.local/share/chez/` | `$CHANDLER_HOME/src::$CHANDLER_HOME/$MT` |
| pack | bundled `<pack>/chandler-runtime/` | `$HERE/chandler-runtime/src::$HERE/chandler-runtime/$MT` |

启动器用 Chez 原生 `--libdirs` 参数**先**指向 chandler-runtime,使 `(import (chandler setup))` 在 library-directories 重写前就能找到 chandler 库。

### 6.2 时序

```
1. launcher exec runtime --libdirs <chandler-runtime-src>::<chandler-runtime-mt> --program run.sps
2. runtime 加载 run.sps
3. run.sps 执行 (import (chandler setup))
4. (chandler setup) 位于 --libdirs 上,被找到并执行
5. setup 重写 library-directories 为 per-package-version 的闭包路径
6. 后续 (import (myapp main)) 通过新的 library-directories 解析
```

## 7. run.sps 模板

install 和 pack 共享同一模板:

```scheme
(import (chezscheme)
        (chandler setup)        ; 接管 library-directories
        (myapp main))          ; import app 入口库
(main (cdr (command-line)))     ; 转发剩余命令行参数
```

**安装时生成位置**:

| 模式 | 路径 |
|------|------|
| install | `<prefix>/.chandler/<name>/run.sps` |
| pack | `<pack-root>/<name>/<version>/.chandler/run.sps` |

## 8. 错误处理

### 8.1 lock 文件缺失

```scheme
(unless (file-exists? lock-path)
  (error 'chandler-setup
         "manifest.lock not found; run `chandler install` first"))
```

用户操作:运行 `chandler install`。

### 8.2 版本漂移(lock 与文件系统不匹配)

```scheme
;;; 检查 lock 里的每个 dep 是否在文件系统上存在对应的 (src . obj)
(define (verify-lock-consistency! lk)
  (for-each
    (lambda (d)
      (let ([src (dep-src d)] [obj (dep-obj d)])
        (unless (and (file-directory? src) (file-directory? obj))
          (error 'chandler-setup
                 (format "version drift detected: ~a/~a filesystem does not match lock; reinstall required"
                         (locked-dep-name d) (locked-dep-version d))))))
    (lock-deps lk)))
```

**拒绝 auto-upgrade**:00 §11 明确拒绝 auto-upgrade,版本漂移时必须显式 `chandler install`。

### 8.3 依赖仍找不到

```scheme
;;; library-directories 设置后尝试验证关键 dep
(define (verify-deps-resolve! lk)
  (for-each
    (lambda (d)
      (let ([libref (list (locked-dep-name d))])
        (unless (ignore-errors (library-object-filename libref))
          (error 'chandler-setup
                 (format "cannot resolve dependency ~a; check that all packages are installed"
                         (locked-dep-name d))))))
    (lock-deps lk)))
```

## 9. 环境变量 vs command-line 反推

**为什么不用 `APP_NAME` 环境变量**:

- run.sps 在 `<name>/<version>/.chandler/` 目录下
- `(car (command-line))` 已知,可以从 run.sps 的路径**反推**出 `<name>` 和 `<version>`
- 不需要额外的环境变量约定,路径本身已是自包含的定位信息

**路径反推优势**:

| 方式 | 依赖 |
|------|------|
| `APP_NAME` env var | 启动器必须设,跨平台不一致 |
| `(car (command-line))` 反推 | 无额外依赖,路径即真相 |

## 10. 与 dev 模式的关系

| 模式 | 机制 | 用 `(chandler setup)` 吗 |
|------|------|------------------------|
| **dev** | `chandler run` 子进程实时算 `resolved-libdirs`,通过 `--libdirs` 传入 | ✗ |
| **install** | `~/.local/bin/<app>` 启动器执行 run.sps,`(import (chandler setup))` 读 lock | ✅ |
| **pack** | `<pack>/bin/<app>` 启动器执行 pack 内 run.sps,`(import (chandler setup))` 读 pack 内嵌 lock | ✅ |

dev 模式下的等价物是 `(activate)`,由 `chandler run` 调用,不读 lock,直接用 `resolved-libdirs`(实时计算)。

## 11. 性能

setup 的开销:

- 一次文件 read(`manifest.lock`)
- 一次 `(library-directories)` set 操作
- 合计约**毫秒级**,与进程启动相比可忽略

## 相关文档

- [00-design-principles.md](00-design-principles.md) — 宪法,5 不变量,D4 决策(Bundler 模型)
- [01-manifest-lock.md](01-manifest-lock.md) — manifest.lock schema
- [08-launchers.md](08-launchers.md) — 三态启动器生成,bootstrap paradox 完整流程
- [09-runtime-paths.md](09-runtime-paths.md) — 资源定位 API
- [10-dev-mode.md](10-dev-mode.md) — dev 模式,`(activate)` 机制
- [11-cli.md](11-cli.md) — `cmd-install`/`cmd-run` CLI 实现
