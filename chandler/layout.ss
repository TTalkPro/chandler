#!chezscheme
;;; chandler/layout.ss --- machine-type / so-ext / 路径拼接 / 库名↔路径 / src·mt 拆分
;;;
;;; 落地[库布局规范]与总设计 load-native 草案的路径推导。纯函数,无 I/O。
;;; 供 activate、install、registry、以及(反向依赖的)bake 复用(见 designs/07 §5)。
;;;
;;; **src/mt 拆分模型(2026-07-22 对齐 bake install 改版)**:一个安装前缀 <prefix>
;;; 下,源码落 <prefix>/src/、平台绑定产物(编译 .so + native)整棵 _build/<mt>/ 落
;;; <prefix>/<mt>/。消费方用一条 Chez 库目录**对** (源目录 . 对象目录) 解析二者:
;;;   library-directories 形式:(cons "<prefix>/src" "<prefix>/<mt>")
;;;   --libdirs / CHEZSCHEMELIBDIRS 串形式:"<prefix>/src::<prefix>/<mt>"(:: 分隔源::对象)
;;; native 收进所属库:<prefix>/<mt>/<lib>/native/<soname>.<ext>(与该库编译 .so 同处)。

(library (chandler layout)
  (export current-machine-type so-ext
          join-paths path-join
          split-pair entry->arg libdirs->arg
          native-so? lib-native-dir lib-native-path native-so-name
          library-name->path srcdir-join
          lib-root)
  (import (chezscheme)
          (chandler util))

  (define (current-machine-type)
    (symbol->string (machine-type)))

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

  ;; 一个「库目录条目」→ --libdirs / CHEZSCHEMELIBDIRS 的串片段。
  ;;   pair (src . obj) → "src::obj"(:: = 源::对象);普通字符串 → 原样(源=对象)。
  (define (entry->arg e)
    (if (pair? e)
        (string-append (car e) "::" (cdr e))
        e))

  ;; 一列条目 → 完整 --libdirs 串(条目间 ":" 分隔)。
  (define (libdirs->arg entries)
    (string-join (map entry->arg entries) ":"))

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

  ;; 库名 (a b c) → 相对路径 "a/b/c.ss"(用 .ss;Chez 亦认 .sls/.scm,读取时另探)
  (define (library-name->path name)
    (let ([parts (map symbol->string name)])
      (string-append (fold-left path-join "" parts) ".ss")))

  ;; 依赖库根:<lib-dir>/<name>/<srcdir>(srcdir 默认 ".")
  (define (srcdir-join dep-root srcdir)
    (if (or (not srcdir) (string=? srcdir "") (string=? srcdir "."))
        dep-root
        (join-paths dep-root srcdir)))

  ;; 项目内某依赖的源库根(src/mt 拆分:源在 lib/src/ 下):<project>/lib/src/<name>/<srcdir>
  (define (lib-root project-root name srcdir)
    (srcdir-join (join-paths project-root "lib" "src" name) srcdir)))
