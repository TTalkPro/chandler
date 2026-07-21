#!chezscheme
;;; chandler/layout.ss --- machine-type / so-ext / 路径拼接 / 库名↔路径
;;;
;;; 落地[库布局规范]与总设计 load-native 草案的路径推导。纯函数,无 I/O。
;;; 供 activate、install、registry、以及(反向依赖的)bake 复用(见 designs/07 §5)。

(library (chandler layout)
  (export current-machine-type so-ext
          join-paths path-join
          native-dir native-path
          library-name->path srcdir-join
          lib-root native-so-name)
  (import (chezscheme))

  (define (current-machine-type)
    (symbol->string (machine-type)))

  ;; native C 库扩展名随 OS(Chez 编译产物恒 .so,那是另一回事,见 pack 规范 §2)
  (define (so-ext)
    (let ([m (current-machine-type)])
      (cond
        [(string-suffix? "nt"  m) "dll"]     ; Windows
        [(string-suffix? "osx" m) "dylib"]   ; macOS
        [else                     "so"])))    ; Linux/BSD

  (define (string-suffix? suf s)
    (let ([ls (string-length s)] [lf (string-length suf)])
      (and (>= ls lf) (string=? suf (substring s (- ls lf) ls)))))

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

  ;; native 目录:<root>/native/<machine-type>/
  (define (native-dir root)
    (join-paths root "native" (current-machine-type)))

  ;; native 完整路径:<root>/native/<mt>/<soname>.<ext>
  (define (native-path root soname)
    (join-paths (native-dir root) (native-so-name soname)))

  (define (native-so-name soname)
    (string-append soname "." (so-ext)))

  ;; 库名 (a b c) → 相对路径 "a/b/c.ss"(用 .ss;Chez 亦认 .sls/.scm,读取时另探)
  (define (library-name->path name)
    (let ([parts (map symbol->string name)])
      (string-append (fold-left path-join "" parts) ".ss")))

  ;; 依赖库根:<lib-dir>/<name>/<srcdir>(srcdir 默认 ".")
  (define (srcdir-join dep-root srcdir)
    (if (or (not srcdir) (string=? srcdir "") (string=? srcdir "."))
        dep-root
        (join-paths dep-root srcdir)))

  ;; 项目内某依赖的库根:<project>/lib/<name>/<srcdir>
  (define (lib-root project-root name srcdir)
    (srcdir-join (join-paths project-root "lib" name) srcdir)))
