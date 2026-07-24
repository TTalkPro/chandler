# 09 — 资源定位 API 与 native 加载

> 状态: 设计中

## 1. 一句话目标

库/app 在运行时通过 `(chandler runtime-paths)` 定位资源文件,通过 `(chandler activate)` 加载 native 库,全程不依赖 `APP_ROOT` 环境变量。

## 2. 资源定位 API

### 2.1 导出函数

```scheme
(library (chandler runtime-paths)
  (export resource-path find-resource-path
          define-resource-path-resolver)
  (import (chezscheme)
          (chandler util)
          (chandler layout)
          (chandler fs))
```

> **v2 去除 `app-root` / `app-name` API**:不再需要(无 APP_ROOT)。资源定位完全走 `(library-directories)` 扫描。

### 2.2 函数签名

| 函数 | 签名 | 行为 |
|------|------|------|
| `resource-path` | `(resource-path '(mylib sub) "schema.json") → string` | 找到返回路径,找不到 raise |
| `find-resource-path` | `(find-resource-path '(mylib sub) "schema.json") → string \| #f` | 找到返回路径,找不到返回 `#f` |
| `define-resource-path-resolver` | `(define-resource-path-resolver my-schema '(mylib sub))` | 声明式 resolver 宏 |

### 2.3 资源落点(I2)

资源文件位于:

```
<name>/<version>/src/resources/<libpath>/<file>
```

即 `<prefix>/src/resources/<libpath>/<file>`。

| 组件 | 含义 |
|------|------|
| `<name>` | 顶层库名,如 `http` |
| `<version>` | semver 版本字符串 |
| `<libpath>` | 库引用路径,如 `mylib/sub` → `mylib/sub/` |
| `<file>` | 资源文件名 |

## 3. 双路径算法

### 3.1 算法总览

```
resource-path(libref, segs)
         ↓
    ┌───────────────────────────────────────┐
    │ Primary: scan-library-directories      │
    │ 遍历 (library-directories) 的每个条目  │
    │ 检查 src 侧:                           │
    │   <src>/resources/<libpath>/<segs>    │
    │ 检查 obj 侧:                           │
    │   <obj>/resources/<libpath>/<segs>    │
    └───────────────────────────────────────┘
         ↓ 若未命中
    ┌───────────────────────────────────────┐
    │ Fallback: via-object (N+1 算法)        │
    │ 1. library-object-filename(libref)    │
    │ 2. N 次 path-parent 剥 libref 路径     │
    │ 3. +1 次 path-parent 剥 <mt>          │
    │ 4. 拼 <prefix>/src/resources/<libpath>/<segs> │
    └───────────────────────────────────────┘
```

### 3.2 Primary: scan-library-directories

```scheme
(define (scan-library-directories libpath segs)
  (let loop ([entries (library-directories)])
    (and (pair? entries)
         (or (let side-loop ([sides (entry-sides (car entries))])
               (and (pair? sides)
                    (let ([path (apply join-paths
                                       (cons (src-resource-dir (car sides) libpath) segs))])
                      (if (file-exists? path) path (side-loop (cdr sides))))))
              (loop (cdr entries))))))
```

对 `(library-directories)` 的每个条目,同时检查 src 侧和 obj 侧。

### 3.3 Fallback: via-object (N+1 算法)

当库从某个不在 `library-directories` 上的前缀加载时,primary 失效。此时用 N+1 算法反推 prefix:

```scheme
;;; obj-path = "<prefix>/<mt>/mylib/sub.so"
;;; libref = '(mylib sub)
;;; N = 2 (libref 段数)
;;; +1 次剥 <mt>
;;; → "<prefix>/"

(define (prefix-from-object obj-path n)
  (if (= n 0) obj-path
      (prefix-from-object (parent-dir obj-path) (- n 1))))

(define (via-object libref libpath segs)
  (let ([obj (ignore-errors (library-object-filename libref))])
    (and obj
         (let* ([prefix (prefix-from-object obj (+ (length libref) 1))]
                [path (apply join-paths
                             (cons (prefix-resource-dir prefix libpath) segs))])
           (and (file-exists? path) path)))))
```

### 3.4 为什么 N+1 在 v2 layout 仍然 work

N+1 算法走 **path-relative**,不走 **prefix-absolute**:

```
library-object-filename 返回: "<prefix>/<mt>/mylib/sub.so"
     ↓
N 次 parent-dir 剥 libref:    "<prefix>/<mt>/"
     ↓
+1 次 parent-dir 剥 <mt>:     "<prefix>/"
     ↓
拼 "src/resources/<libpath>/<segs>"
```

v2 layout 的 `<mt>` 嵌套在 `<name>/<version>/` 下,parent-dir 链是:

```
<prefix>/<name>/<version>/<mt>/mylib/sub.so
     ↓ parent 1
<prefix>/<name>/<version>/<mt>/mylib/
     ↓ parent 2
<prefix>/<name>/<version>/<mt>/
     ↓ +1
<prefix>/<name>/<version>/
```

恰好定位到 `<name>/<version>/`,然后拼 `src/resources/<libpath>/<segs>`。

## 4. APP_ROOT 完全去除(v2 决策)

**v2 不再有 APP_ROOT 环境变量。** 所有运行时文件路径定位**统一到 `(library-directories)`** 这单一面:

| v1 机制 | v2 替代 |
|---------|--------|
| `APP_ROOT` 单一前缀锚点 | `(library-directories)` 列表(每对 pair 自包含 src/obj/native/resources) |
| native-loader candidate 1: `$APP_ROOT/<mt>/<libpath>/native/` | native-loader 读 `(library-directories)` 扫 obj 侧(见 §5.2) |
| `app-root` / `app-name` API | 删除;资源定位走 `scan-library-directories`,不读 env |

**为什么能统一**:`(library-directories)` 是 Chez 原生的库搜索面,它已经列出了"当前进程对着哪些前缀跑"。资源、native、import 解析都基于这个列表,不需要第二个锚点。`(chandler setup)` 在 import 时重写这个列表后,后续所有定位自动跟着走。

**唯一例外**:runtime 可执行文件位置(skiff/scheme 二进制),由 launcher 的 `exec` 逻辑处理,不属于库路径范畴。

## 5. native 加载(I4 不变量保留)

### 5.1 per-lib native 落点

```
<name>/<version>/<mt>/<libpath>/native/<soname>
```

### 5.2 自加载 loader(完全靠 library-directories)

bake 生成的 `native-loader.so` 在 library invoke 期执行——**此时 `(chandler setup)` 已重写 `library-directories` 为应用真实库列表**(因为 setup 在触发 native-loader 的 import 链之前执行)。loader 直接读 `(library-directories)` 扫 obj 侧:

```scheme
;;; bake 生成的 native-loader.so(完全靠 library-directories,无 APP_ROOT)
(import (chezscheme))
(define (find-native libref soname)
  ;; libref = '(http)  soname = "llhttp.so"
  (let loop ([dirs (library-directories)])
    (if (null? dirs) #f
        (let ([p (apply path-build (cdar dirs) (append libref (list "native" soname)))])
          (if (file-exists? p) p (loop (cdr dirs)))))))
;; 找到后 load-shared-object
(load-shared-object (find-native '(http) "llhttp.so"))
```

**为什么不需要 candidate 1**(v1 的 `$APP_ROOT/...`):
- v1 用单一 prefix,APP_ROOT 是定位锚点
- v2 的 `(library-directories)` 列表已包含所有 unit 的 obj 侧(install 的 `<name>/<version>/<mt>/`、dev 的 `_vendor/<name>/_build/<mt>/` 等)
- loader 遍历列表即覆盖全部,不需要额外锚点

**执行时序保证**:
```
1. launcher exec runtime with --libdirs = chandler-runtime(bootstrap)
2. runtime 加载 run.sps
3. run.sps (import (chandler setup)) → setup 重写 library-directories 为应用列表
4. run.sps (import (myapp main)) → myapp import http → http 的 native-loader 执行
5. native-loader 读 (library-directories) → 此时已是应用列表 → 扫 obj 侧命中
```

### 5.3 chandler 兜底扫描

只为**无 loader 的第三方库**扫描:

```scheme
;;; native-load-paths:扫 (library-directories) 的 obj 侧
(define (native-load-paths)
  (let loop ([dirs (library-directories)] [acc '()])
    (if (null? dirs) (reverse acc)
        (let ([obj (entry-obj-side (car dirs))])
          (loop (cdr dirs)
                (append (native-sos-under obj) acc))))))

;;; self-loading? 检测:<lib>/native-loader.so 是否存在
(define (self-loading? f)
  ;; f = "<prefix>/<mt>/<lib>/native/<soname>.so"
  ;; 所属库目录 = f 的祖父目录
  (file-exists? (join-paths (parent-dir (parent-dir f)) "native-loader.so")))
```

### 5.4 self-loading 检测

```scheme
;;; <lib>/native-loader.so 与 native/ 同级 → 自加载
;;; f = "<prefix>/<mt>/mylib/native/libfoo.so"
;;; parent-dir(f) = "<prefix>/<mt>/mylib/native/"
;;; parent-dir(parent-dir(f)) = "<prefix>/<mt>/mylib/"
;;; 检测 "<prefix>/<mt>/mylib/native-loader.so" 是否存在
```

## 6. 资源声明与 manifest.lock

资源声明在 `manifest.lock` 中以快照形式存在:

```scheme
;; manifest.lock 中的资源快照
(lock
  (format 1)
  (name myapp)
  (version "1.0.0")
  (deps
    (http (version "1.2.0")
          (source (git ...))
          (resources
            (http) "schema.json"
            (http client) "ca-bundle.crt"))))
```

详见 [01-manifest-lock.md](01-manifest-lock.md)。

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
             (format "resource not found: ~a under resources/~a/ in any library directory~%  searched: ~a"
                     (if (null? segs) "(the directory itself)" (car (reverse segs)))
                     (libref->path libref)
                     (string-join (map (lambda (e) (car (entry-sides e)))
                                     (library-directories))
                                  ", ")))))
```

## 8. 完整示例:myapp 调用 `(resource-path '(http) "mime.json")`

### 8.1 场景

- myapp 依赖 http 库,版本 1.2.0
- http 库的资源文件: `<prefix>/http/1.2.0/src/resources/http/mime.json`

### 8.2 调用链

```
(resource-path '(http) "mime.json")
         ↓
libref→path: "http"
         ↓
scan-library-directories("http", ("mime.json"))
         ↓
library-directories 当前值(setup 后):
  (
    ("/home/user/.local/share/chez/http/1.2.0/src"
     . "/home/user/.local/share/chez/http/1.2.0/ta6le")
    ("/home/user/.local/share/chez/json/0.9.0/src"
     . "/home/user/.local/share/chez/json/0.9.0/ta6le")
    ("/home/user/.local/share/chez/chandler/src"
     . "/home/user/.local/share/chez/chandler/ta6le")
  )
         ↓
检查第 1 条:
  src 侧: "/home/user/.local/share/chez/http/1.2.0/src/resources/http/mime.json"
  → 文件存在! 返回该路径
```

### 8.3 Fallback 触发条件

若 http 库从某个**不在** `library-directories` 上的前缀被加载(如手动编译测试):

```
library-object-filename '(http)
  → "/tmp/build/http.so"  (不在任何已挂载的前缀下)
         ↓
prefix-from-object("/tmp/build/http.so", 1 + 1)
  → "/tmp/build" → "/tmp"
         ↓
prefix-resource-dir("/tmp", "http")
  → "/tmp/src/resources/http/mime.json"
```

## 相关文档

- [00-design-principles.md](00-design-principles.md) — 宪法,I1-I5 不变量,术语表
- [01-manifest-lock.md](01-manifest-lock.md) — manifest.lock schema
- [07-chandler-setup.md](07-chandler-setup.md) — `(chandler setup)` 四步流程
- [08-launchers.md](08-launchers.md) — 启动器生成,bootstrap paradox
- [10-dev-mode.md](10-dev-mode.md) — dev 模式,`(activate)` 机制
- [11-cli.md](11-cli.md) — CLI 命令面
