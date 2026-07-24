# 09 — 资源定位 API 与 native 加载

> 状态: 设计中

## 1. 一句话目标

库/app 在运行时通过 `(chandler runtime-paths)` 定位资源文件,通过 `(chandler activate)` 加载 native 库,全程不依赖 `APP_ROOT` 环境变量。

## 2. 资源定位 API

### 2.1 导出函数

```scheme
(library (chandler runtime-paths)
  (export app-root app-name
          resource-path find-resource-path
          define-resource-path-resolver)
  (import (chezscheme)
          (chandler util)
          (chandler layout)
          (chandler fs))
```

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

## 4. 资源定位不读 APP_ROOT

00 §8 明确:**资源与库住在同一个前缀里,而 `(library-directories)` 本身就是「我在对着哪些前缀跑」的权威答案**。

`APP_ROOT` 历史遗留:
- v1 用单一前缀模型,APP_ROOT 作为定位锚点
- v2 改用 `library-directories` 列表,每个条目自包含 src/obj/native,资源扫描自然覆盖所有前缀

## 5. native 加载(I4 不变量保留)

### 5.1 per-lib native 落点

```
<name>/<version>/<mt>/<libpath>/native/<soname>
```

### 5.2 自加载 loader

bake 生成的 `native-loader.so` 按候选序自加载:

```scheme
;;; native-loader.so 的候选路径生成逻辑
(candidates-for '<lib>)
  = list(
      (join-paths (app-root) "<mt>" "<libpath>" "native" "<soname>")
      ;; 候选 2:扫 library-directories 的 obj 侧
    )
```

因 `library-directories` 挂载了 per-dep 的 obj 侧,候选 2 恰好命中。

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
