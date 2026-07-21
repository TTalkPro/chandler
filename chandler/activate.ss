#!chezscheme
;;; chandler/activate.ss --- activate / load-native(新模型:扁平 lib/)
;;;
;;; 运行期激活(脚本顶层):挂 lib/(+ path 源目录 + 全局)到 library-directories,
;;; 并 load 所有 lib/native/<mt>/*.so。规则与 run/exec/repl 一致(install 的 resolved-libdirs)。
;;; 注:日常激活推荐用 install 生成的 chandler-setup.ss(纯 skiff 即可,无需 (chandler))。

(library (chandler activate)
  (export activate activate-natives load-native native-path native-root)
  (import (chezscheme)
          (except (chandler layout) native-path)   ; native-path 本库按扁平 lib/ 自定义
          (chandler fs)
          (chandler manifest)
          (chandler install)
          (chandler runtime))

  (define native-root (make-parameter "lib"))
  (define loaded (make-hashtable string-hash string=?))   ; 幂等注册表

  ;; (activate [root]) —— 挂库路径 + 载 native
  (define activate
    (case-lambda
      [() (activate ".")]
      [(root)
       (gate-runtime! root)
       (library-directories (append (resolved-libdirs root) (library-directories)))
       (activate-natives root)]))

  ;; 仅载 native(chandler-setup.ss / run 的 preamble 已自载,此为 (activate) 子集)
  (define activate-natives
    (case-lambda
      [() (activate-natives ".")]
      [(root)
       (for-each (lambda (so) (load-one so)) (native-load-paths root))]))

  (define (load-one p)
    (unless (hashtable-ref loaded p #f)
      (when (file-exists? p)
        (load-shared-object p)
        (hashtable-set! loaded p #t))))

  ;; 运行时版本门(manifest 有 chez/skiff 声明时)
  (define (gate-runtime! root)
    (let ([mpath (join-paths root "manifest.ss")])
      (when (file-exists? mpath)
        (let ([mf (read-manifest mpath)])
          (verify-runtime! (list (cons 'chez (manifest-chez mf))
                                 (cons 'skiff (manifest-skiff mf))))))))

  ;; ── load-native / native-path(边缘/显式用;新模型 native 扁平于 lib/native/<mt>/)──
  ;;   (native-path soname) 或 (native-path pkg soname) 皆 → <native-root>/native/<mt>/<soname>.<ext>
  (define native-path
    (case-lambda
      [(soname) (flat-native (native-root) soname)]
      [(pkg soname) (flat-native (native-root) soname)]))

  (define (flat-native root soname)
    (join-paths (join-paths (join-paths root "native") (current-machine-type))
                (string-append soname "." (so-ext))))

  (define load-native
    (case-lambda
      [(soname) (let ([p (native-path soname)]) (load-one p) p)]
      [(pkg soname) (let ([p (native-path soname)]) (load-one p) p)])))
