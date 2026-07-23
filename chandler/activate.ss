#!chezscheme
;;; chandler/activate.ss --- activate / load-native(src/mt 拆分:lib/{src,<mt>})
;;;
;;; 运行期激活(脚本顶层):挂 lib/ 一对(源.对象)(+ path 源目录 + 全局)到
;;; library-directories。规则与 run/exec/repl 一致(install 的 resolved-libdirs)。
;;; native 收进所属库 lib/<mt>/<lib>/native/。
;;;
;;; **native 分层(bake designs/24)**:挂好该对本身就使 bake 生成的
;;; `(<lib> native-loader)` 自加载生效(loader 按 library-directories 的 obj 侧定位,
;;; 且惰性——不引用 FFI 就不 dlopen)。故 activate-natives 已降级为**兜底**:
;;; 只预加载「无生成 loader」的第三方库(见 install 的 native-load-paths)。
;;; 注:日常激活推荐用 install 生成的 chandler-setup.ss(纯 skiff 即可,无需 (chandler))。

(library (chandler activate)
  (export activate activate-natives load-native native-path native-root)
  (import (chezscheme)
          (chandler layout)
          (chandler fs)
          (chandler manifest)
          (chandler install)
          (chandler runtime-detector))

  (define native-root (make-parameter "lib"))   ; 项目 lib 前缀(base)
  (define loaded (make-hashtable string-hash string=?))   ; 幂等注册表

  ;; (activate [root]) —— 挂库路径 + 载 native
  (define activate
    (case-lambda
      [() (activate ".")]
      [(root)
       (gate-runtime! root)
       (library-directories (append (resolved-libdirs root) (library-directories)))
       (activate-natives root)]))

  ;; 仅载 native —— 统一加载**兜底**:有 native-loader 的库自加载,不在此列
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

  ;; ── load-native / native-path(边缘/显式用;native 收进所属库 lib/<mt>/<lib>/native/)──
  ;;   (native-path pkg soname) → <native-root>/<mt>/<pkg>/native/<soname>.<ext>
  ;;   (native-path soname)     → 同上,pkg 缺省取 soname(native 常与所属库同名)
  (define native-path
    (case-lambda
      [(soname) (native-path soname soname)]
      [(pkg soname)
       (lib-native-path (join-paths (native-root) (current-machine-type)) pkg soname)]))

  (define load-native
    (case-lambda
      [(soname) (let ([p (native-path soname)]) (load-one p) p)]
      [(pkg soname) (let ([p (native-path pkg soname)]) (load-one p) p)])))
