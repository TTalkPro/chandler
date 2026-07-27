#!chezscheme
;;; chandler/layout.ss --- machine-type / so-ext / 路径拼接 / 库名↔路径 / src·mt 拆分
;;;
;;; 落地[库布局规范]与总设计 load-native 草案的路径推导。纯函数,无 I/O。
;;; 供 activate、install、registry 等 chandler 内部库复用。
;;;
;;; **src/mt 拆分模型(2026-07-22 引入)**:一个安装前缀 <prefix> 下,源码落
;;; <prefix>/<name>/<version>/src/、平台绑定产物(编译 .so + native)落
;;; <prefix>/<name>/<version>/<mt>/。消费方用一条 Chez 库目录**对** (源目录 . 对象目录)
;;; 解析二者:
;;;   library-directories 形式:(cons "<prefix>/<name>/<version>/src"
;;;                                  "<prefix>/<name>/<version>/<mt>")
;;;   --libdirs / CHEZSCHEMELIBDIRS 串形式:"<prefix>/<name>/<version>/src::<prefix>/<name>/<version>/<mt>"
;;;     (双分隔符分隔 源::对象;分隔符随平台:Windows ";" 其余 ":",见 path-sep)
;;; native 收进所属库:<obj>/<lib>/native/<soname>.<ext>(与该库编译 .so 同处)。

(library (chandler layout)
  (export current-machine-type so-ext
          windows-mt?
          join-paths path-join
          path-sep split-pair version-root entry->arg libdirs->arg
          resources-dirname lib-resource-dir
          native-so? lib-native-dir lib-native-path native-so-name
          srcdir-join)
  (import (chezscheme)
          (chandler util))

  ;; 全仓唯一的「machine-type 字符串」出处。先前另有一个逐字同义的
  ;; `machine-type-string`,两个名字在 13 个文件里混用 —— 已统一到本函数。
  (define (current-machine-type)
    (symbol->string (machine-type)))

  (define (windows-mt? mt)
    (string-suffix? "nt" mt))

  ;; native C 库扩展名随 OS(Chez 编译产物恒 .so,那是另一回事,见 pack 规范 §2)
  (define (so-ext)
    (let ([m (current-machine-type)])
      (cond
        [(string-suffix? "nt"  m) "dll"]     ; Windows
        [(string-suffix? "osx" m) "dylib"]   ; macOS
        [else                     "so"])))    ; Linux/BSD

  ;; ── 路径拼接(POSIX 分隔;Windows 亦接受 /,Chez 内部规范化)──
  (define (path-join a b)
    (cond
      [(string=? a "") b]
      [(string=? b "") a]
      [(char=? #\/ (string-ref a (- (string-length a) 1)))
       (string-append a b)]
      [else (string-append a "/" b)]))

  ;; (join-paths "a" "b" "c") → "a/b/c";忽略空段与 "."
  (define (join-paths . parts)
    (fold-left
      (lambda (acc p)
        (if (or (string=? p "") (string=? p ".")) acc (path-join acc p)))
      ""
      parts))

  ;; ── src/mt 拆分:安装前缀 → Chez 库目录对(源 . 对象)──
  ;;   (split-pair "<prefix>") → (cons "<prefix>/src" "<prefix>/<mt>")
  ;;   library-directories 直接吃这个 pair;字符串元素则源=对象(Chez 语义)。
  (define (split-pair prefix)
    (cons (join-paths prefix "src")
          (join-paths prefix (current-machine-type))))

  ;; ── 版本化前缀(v2 Unified Layout,designs/00 §4)──
  ;;
  ;; 中央仓库/install 的每个 versioned package 在 `<prefix>/<name>/<version>/` 下。
  ;; version-root 给出此 versioned package 的根目录。
  ;;
  ;;   (version-root "<prefix>" 'foo "1.2.0") → "<prefix>/foo/1.2.0"
  ;;
  ;; 对它调 split-pair 得到 install 的 (src . obj) 对:
  ;;   (split-pair (version-root "<prefix>" 'foo "1.2.0"))
  ;;     → (cons "<prefix>/foo/1.2.0/src" "<prefix>/foo/1.2.0/<mt>")
  (define (version-root prefix name version)
    ;; name 收 symbol 或 string(manifest/CLI 给字符串,lock 记录给 symbol)
    (join-paths prefix (if (symbol? name) (symbol->string name) name) version))

  ;; ── 资源落点(D13 method B,2026-07-25):<src>/<libpath>/resources/… ──
  ;;
  ;; v3 取消 manifest (resources ...) 声明,资源与库源码**同居**:每个库的资源
  ;; 住在同名子目录的 `resources/` 下。这跟 dev 期 `_vendor/<dep>/<srcdir>/`
  ;; 的源码布局一致 —— 资源不需要任何特殊路径变换,随源码树拷贝即可。
  ;;
  ;;   (myapp)        → <src>/myapp/resources/…
  ;;   (mylib parser) → <src>/mylib/parser/resources/…
  ;;
  ;; 资源定位 API(runtime-paths)扫各 library-directories 条目的 src 侧:
  ;;   <src>/<libpath>/resources/<segs>
  ;;
  ;; v2 的 prefix-resource-dir / src-resource-dir 已废弃 —— 它们把所有库的资源
  ;; 塞进单一 `<src>/resources/<ns>/` 顶层目录,与库源码树分离;method B 改为
  ;; 每个库自己管理自己的 resources/,自然且无冲突。
  (define resources-dirname "resources")

  ;; lib-resource-dir : src-dir libpath → <src-dir>/<libpath>/resources
  ;; libpath 形如 "myapp" / "mylib/parser"(符号列表 join 而)。
  (define (lib-resource-dir src-dir libpath)
    (join-paths src-dir libpath resources-dirname))

  ;; 目录分隔符 = Chez 的 $separator-character:**Windows 为 ";",其余为 ":"**。
  ;; 权威依据 ChezScheme s/syntax.ss 的 parse-string 注释:
  ;;   ; "stuff^...", ^ is ; under windows : otherwise
  ;;   ; stuff -> src-dir^^src-dir | src-dir
  ;; 即:条目间用**单个**分隔符;条目内 "src<sep><sep>obj" 用**双**分隔符表示
  ;; (源 . 对象) 对。故 Windows 上是 "src;;obj" 而非 "src::obj"——写死冒号会错。
  (define (path-sep)
    (if (string-suffix? "nt" (current-machine-type)) ";" ":"))

  ;; 一个「库目录条目」→ --libdirs / CHEZSCHEMELIBDIRS 的串片段。
  ;;   pair (src . obj) → "src<sep><sep>obj";普通字符串 → 原样(源=对象)。
  (define (entry->arg e)
    (if (pair? e)
        (let ([s (path-sep)])
          (string-append (car e) s s (cdr e)))
        e))

  ;; 一列条目 → 完整 --libdirs 串(条目间单个分隔符)。
  (define (libdirs->arg entries)
    (string-join (map entry->arg entries) (path-sep)))

  ;; ── native(C/FFI)产物 ──
  ;;   收进所属库:<obj-root>/<lib>/native/<soname>.<ext>(obj-root = <prefix>/<mt>)。
  (define (lib-native-dir obj-root lib)
    (join-paths obj-root lib "native"))

  (define (lib-native-path obj-root lib soname)
    (join-paths (lib-native-dir obj-root lib) (native-so-name soname)))

  (define (native-so-name soname)
    (string-append soname "." (so-ext)))

  ;; 文件名/路径是否 native 动态库(按 OS 扩展名;供扫描 obj 树时甄别编译 .so 与 native)
  (define (native-so? path)
    (string-suffix? (string-append "." (so-ext)) path))

  ;; 依赖库根:<lib-dir>/<name>/<srcdir>(srcdir 默认 ".")
  (define (srcdir-join dep-root srcdir)
    (if (or (not srcdir) (string=? srcdir "") (string=? srcdir "."))
        dep-root
        (join-paths dep-root srcdir))))
