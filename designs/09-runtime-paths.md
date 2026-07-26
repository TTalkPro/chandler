# 09 — 资源定位 API 与 native 加载

> 状态: 已实现(v3 + v4),对齐 `chandler/runtime-paths.ss`。
> v3 中心设计见 [06-installed-layout.md](06-installed-layout.md) §8 / §9,决策记录见 [TASK.md](../TASK.md)。

## 1. 一句话目标

库/app 在运行时通过 `(chandler runtime-paths)` 定位资源文件,**完全走
`(library-directories)`**(D8:APP_ROOT 已去除,2026-07-24 起的统一 API);资源
与库源码同居(method B,D13),无需 manifest 声明。

## 2. 资源定位 API

### 2.1 导出函数

```scheme
(library (chandler runtime-paths)
  (export resource-path find-resource-path
          define-resource-path-resolver)
  (import (chezscheme)
          (chandler util)
          (chandler layout)
          (chandler fs)))
```

> **v3 起 API 稳定**:无 `app-root` / `app-name`(无 APP_ROOT 可暴露),无
> manifest `(resources ...)` 字段。资源完全靠方法 B 的目录约定定位。

### 2.2 函数签名

| 函数 | 签名 | 行为 |
|------|------|------|
| `resource-path` | `(resource-path '(mylib sub) "schema.json") → string` | 找到返回路径,找不到 raise |
| `find-resource-path` | `(find-resource-path '(mylib sub) "schema.json") → string \| #f` | 找到返回路径,找不到返回 `#f` |
| `define-resource-path-resolver` | `(define-resource-path-resolver my-schema '(mylib sub))` | 声明式 resolver 宏(生成一个包了 `find-resource-path` 的 thunk) |

### 2.3 资源落点(D13 method B)

资源文件与库源码同居,**在库源码树下**作为同名子目录的 `resources/`:

| 库 | 源码路径 | 资源路径 |
|----|---------|---------|
| `(myapp)` | `<src>/myapp.ss` | `<src>/myapp/resources/<file>` |
| `(mylib parser)` | `<src>/mylib/parser.ss` | `<src>/mylib/parser/resources/<file>` |
| `(mylib io json)` | `<src>/mylib/io/json.ss` | `<src>/mylib/io/json/resources/<file>` |

> **v2 → v3 路径翻转**:v2 用 `<src>/resources/<libpath>/<file>`(资源集中在
> `<src>/resources/`,再下钻到 libpath),v3 改 method B `<src>/<libpath>/resources/<file>`
> (资源跟库源码走)。前者需要在 install/pack 时单走一次 `copy-resources!`,
> 后者随源码树自然拷贝,**install/pack 零额外代码**。

## 3. 定位算法

### 3.1 算法总览

```
resource-path(libref, segs)
         ↓
    ┌───────────────────────────────────────┐
    │ Primary: scan-library-directories      │
    │ 遍历 (library-directories) 的每个条目  │
    │ 检查 src 侧:                           │
    │   <src>/<libpath>/resources/<segs>    │
    │ 检查 obj 侧:                           │
    │   <obj>/<libpath>/resources/<segs>    │
    └───────────────────────────────────────┘
         ↓ 若未命中
    ┌───────────────────────────────────────┐
    │ Fallback: via-object (N+1 算法)        │
    │ 1. library-object-filename(libref)    │
    │ 2. N 次 path-parent 剥 libref 路径     │
    │ 3. +1 次 path-parent 剥 <mt>          │
    │ 4. 拼 <prefix>/<libpath>/resources/<segs> │
    └───────────────────────────────────────┘
```

### 3.2 Primary: scan-library-directories

```scheme
(define (scan-library-directories libpath segs)
  ;; libpath = "mylib/sub"  segs = ("schema.json")
  ;; 对 (library-directories) 的每个条目,同时检查 src 侧与 obj 侧
  (let loop ([entries (library-directories)])
    (and (pair? entries)
         (or (let side-loop ([sides (entry-sides (car entries))])
               (and (pair? sides)
                    (let ([path (apply join-paths
                                       (cons (side-resource-dir (car sides) libpath)
                                             segs))])
                      (if (file-exists? path) path (side-loop (cdr sides))))))
             (loop (cdr entries))))))
```

> 一个 `library-directories` 条目 = `(src . obj)` 对(string 条目两侧同一);
> 对每个条目**两条 side 都试**,命中即返回。

### 3.3 Fallback: via-object(N+1 算法)

当库从某个不在 `library-directories` 上的前缀加载时,primary 失效(典型场景:
手动编译测试的临时位置)。此时用 N+1 算法反推 prefix:

```scheme
;;; obj-path = "<prefix>/<mt>/mylib/sub.so"
;;; libpath = "mylib/sub"
;;; N = 2(libpath 段数)
;;; +1 次剥 <mt>
;;; → "<prefix>/<libpath>/resources/<segs>"

(define (prefix-from-object obj-path n)
  (if (= n 0) obj-path
      (prefix-from-object (parent-dir obj-path) (- n 1))))

(define (via-object libpath segs)
  (let* ([libref (libpath->libref libpath)]
         [obj (ignore-errors (library-object-filename libref))]
         [n (+ (length libref) 1)])
    (and obj
         (let* ([prefix (prefix-from-object obj n)]
                [path (apply join-paths
                             (cons (side-resource-dir prefix libpath) segs))])
           (and (file-exists? path) path)))))
```

### 3.4 为什么 N+1 在 v3 layout 仍 work

v3 layout `<prefix>/<name>/<version>/<mt>/<libpath>/<file>.so`,N+1 parent-dir 链:

```
<prefix>/myapp/0.1.0/ta6le/mylib/sub.so   (N=2,+1=3 次 parent)
     ↓ parent 1   剥 sub
<prefix>/myapp/0.1.0/ta6le/mylib/
     ↓ parent 2   剥 mylib
<prefix>/myapp/0.1.0/ta6le/
     ↓ parent 3   剥 ta6le(<mt>)
<prefix>/myapp/0.1.0/
     ↓ 拼 libpath/resources/<segs>
<prefix>/myapp/0.1.0/src/mylib/sub/resources/<file>   ; src 侧(若编译产物侧是 obj 树,不会自动有 src)
```

> N+1 走 path-relative(基于 obj 路径上溯),不要求 `<prefix>` 必须是用户 prefix —
> 只要 obj 真实落在某个 `<prefix>/<mt>/<libpath>/.so` 的形态上,资源侧同前缀的
> `src/<libpath>/resources/` 即可命中(若 vroot 真有 src)。

## 4. APP_ROOT 已完全去除(D8)

v3 不再有 `APP_ROOT` 环境变量。所有运行时文件路径定位**统一到 `(library-directories)`**
这单一面:

| 旧机制 | 新替代 |
|--------|--------|
| `APP_ROOT` 单一前缀锚点 | `(library-directories)` 列表(每对 pair 自含 src/obj/native/resources 线索) |
| native-loader candidate 1: `$APP_ROOT/<mt>/<libpath>/native/` | native-loader 读 `(library-directories)` 扫 obj 侧(见 §5.2) |
| `(chandler setup)` 重写 library-directories | run.sps 直接 lock 驱动精确挂(D18) |

**为什么能统一**:`(library-directories)` 是 Chez 原生的库搜索面,它已经列出
"当前进程对着哪些前缀跑"。资源、native、import 解析都基于这个列表,不需要
第二个锚点。

**唯一例外**:runtime 可执行文件位置(skiff/scheme 二进制),由启动器的 `exec`
逻辑处理,不属于库路径范畴。

## 5. native 加载(I4 不变量保留)

### 5.1 per-lib native 落点

```
<name>/<version>/<mt>/<libpath>/native/<soname>
```

### 5.2 自加载 loader(完全靠 library-directories)

`chandler build` 为每个带 native 的库生成 `<obj>/<libpath>/native-loader.so`,
该库的 FFI 被引用时 loader **自己**定位并加载 `.so`——其候选之一正是
`(library-directories)` 的**对象侧**,而 run.sps 挂的各依赖 obj 侧恰是 native
落点,故**挂好对即自动生效**,且是**惰性**的(不碰 FFI 就不 `dlopen`):

```scheme
;;; build 生成的 native-loader.so(完全靠 library-directories,无 APP_ROOT)
(import (chezscheme))
(define (find-native libpath soname)
  (let loop ([dirs (library-directories)])
    (if (null? dirs) #f
        (let* ([obj (cdar dirs)]    ; pair entry: src 侧是 (car),obj 侧是 (cdr)
               [p (apply join-paths (cons obj (append (libpath->segs libpath)
                                                     (list "native" soname))))])
          (if (file-exists? p) p (loop (cdr dirs)))))))
(load-shared-object (find-native '("mylib") "libfoo.so"))
```

**为什么不需要 v1 那种 `$APP_ROOT/...` candidate**:

- v1 用单一 prefix,APP_ROOT 是定位锚点
- v3 的 `(library-directories)` 已包含所有 unit 的 obj 侧(install 的
  `<libdir>/<name>/<version>/<mt>/`、dev 的 `_vendor/<name>/_build/<mt>/` 等)
- loader 遍历列表即覆盖全部,不需要额外锚点

### 5.3 chandler 兜底扫描

只为**无 loader 的第三方库**扫描(`activate` / `run` / `repl` 的预加载):

```scheme
;;; native-load-paths:扫 (library-directories) 的 obj 侧
(define (native-load-paths)
  (let loop ([dirs (library-directories)] [acc '()])
    (if (null? dirs) (reverse acc)
        (let ([obj (entry-obj-side (car dirs))])
          (loop (cdr dirs) (append (native-sos-under obj) acc))))))

;;; self-loading? 检测:<libpath>/native-loader.so 是否存在
(define (self-loading? f)
  ;; f = "<prefix>/<mt>/<libpath>/native/<soname>.so"
  ;; 所属库目录 = f 的祖父目录
  (file-exists? (join-paths (parent-dir (parent-dir f)) "native-loader.so")))
```

### 5.4 self-loading 检测

```scheme
;;; <libpath>/native-loader.so 与 native/ 同级 → 自加载
;;; f = "<prefix>/<mt>/mylib/native/libfoo.so"
;;; parent-dir(f) = "<prefix>/<mt>/mylib/native/"
;;; parent-dir(parent-dir(f)) = "<prefix>/<mt>/mylib/"
;;; 检测 "<prefix>/<mt>/mylib/native-loader.so" 是否存在
```

> 因 build 把 native-loader 生成在**库根**(`<mt>/<libpath>/native-loader.so`),
> 自加载判断 = 父目录有 `native-loader.so` 即跳过兜底。

## 6. 资源声明与 manifest.lock

**v3 删 `manifest.lock` 的 `(resources ...)` 字段**:旧 lock 的该字段
解析时**静默忽略**(降低升级摩擦)。`chandler deps` 不再生成,`chandler init`
也不再生成。

```scheme
;; 典型 v3 lock(无 resources 字段)
(lock
  (format 1)
  (manifest-sha256 "<hex>")
  (deps
    (http (version "1.2.0")
          (source (git "..."))
          (rev "abc123def0")
          (scope lib))))
```

详见 [01-manifest-lock.md](01-manifest-lock.md) 与 [06 §6](06-installed-layout.md#6-chandler-manifestlock-格式d14--d15)。

## 7. 错误模式

### 7.1 libref 类型错误

```scheme
(unless (and (pair? libref) (for-all symbol? libref))
  (error 'resource-path
         "library reference must be a list of symbols" libref))
```

### 7.2 路径遍历防护

```scheme
(define (validate-resource-segment seg)
  (cond
    [(not (string? seg))
     (error 'runtime-paths "resource segment must be a string" seg)]
    [(string=? seg "")
     (error 'runtime-paths "empty resource segment rejected")]
    [(string-prefix? "/" seg)
     (error 'runtime-paths "absolute resource segment rejected" seg)]
    [(string=? seg "..")
     (error 'runtime-paths "parent traversal rejected" seg)]
    [(string=? seg ".")
     (error 'runtime-paths "current-directory resource segment rejected" seg)]
    [(string-contains? seg "/")
     (error 'runtime-paths "resource segment with path separator rejected" seg)]))
```

### 7.3 资源根缺失

```scheme
;;; resource-path 严格模式:找不到即报错,并列出搜索过的路径
(define (resource-path libref . segs)
  (or (locate-resource libref segs)
      (error 'resource-path
             (format "resource not found: ~a under <libpath>/resources/ in any library directory~%  searched: ~a"
                     (if (null? segs) "(the directory itself)" (car (reverse segs)))
                     (string-join (map (lambda (e) (car (entry-sides e)))
                                     (library-directories))
                                  ", ")))))
```

## 8. 完整示例:`(resource-path '(http) "mime.json")`

### 8.1 场景

- myapp 依赖 http 库,版本 1.2.0
- http 库的资源文件: `<libdir>/http/1.2.0/src/http/resources/mime.json`

### 8.2 调用链

```
(resource-path '(http) "mime.json")
         ↓
libref→path: "http"
         ↓
scan-library-directories("http", ("mime.json"))
         ↓
library-directories 当前值(run.sps 已挂好):
  (
    ("/home/user/.local/share/chez/myapp/0.1.0/src"
     . "/home/user/.local/share/chez/myapp/0.1.0/ta6le")
    ("/home/user/.local/share/chez/http/1.2.0/src"
     . "/home/user/.local/share/chez/http/1.2.0/ta6le")
    ("/home/user/.local/share/chez/json/0.9.0/src"
     . "/home/user/.local/share/chez/json/0.9.0/ta6le"))
         ↓
检查第 2 条:
  src 侧: "/home/user/.local/share/chez/http/1.2.0/src/http/resources/mime.json"
  → 文件存在! 返回该路径
```

### 8.3 Fallback 触发条件

若 http 库从某个**不在** `library-directories` 上的前缀被加载(如手动编译测试):

```
library-object-filename '(http)
  → "/tmp/build/http.so"  (不在任何已挂载的前缀下)
         ↓
prefix-from-object("/tmp/build/http.so", 1 + 1)   ; N=1(libref='(http)),+1 剥 ta6le
  → "/tmp/build" → "/tmp"
         ↓
side-resource-dir("/tmp", "http")
  → "/tmp/http/resources/mime.json"
```

## 相关文档

- [06-installed-layout.md](06-installed-layout.md) §8 — 资源布局(D13 method B)
- [06-installed-layout.md](06-installed-layout.md) §9 — run.sps lock 驱动
- [10-dev-mode.md](10-dev-mode.md) — dev 模式 `(activate)` 与 native 兜底
- [11-cli.md](11-cli.md) — `env` / `exec` / `run` 与库路径的关系