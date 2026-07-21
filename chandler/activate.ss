#!chezscheme
;;; chandler/activate.ss --- activate / load-native 核心(designs/chandler 总设计「运行期激活」)
;;;
;;; rubygem 式一行激活:读 ./manifest.lock,(a) 把每个 lib/<name>/<srcdir> prepend 到
;;; library-directories;(b) 按拓扑序统一 load 所有依赖声明的 native(库自身只写 foreign-procedure)。
;;; 只在脚本顶层成立(展开期坑,见总设计);编译型入口走 chandler run 的环境变量注入。

(library (chandler activate)
  (export activate activate-natives load-native native-path native-root)
  (import (chezscheme)
          (except (chandler layout) native-path)   ; native-path 本库自定义(按 lib/<pkg> 布局)
          (chandler manifest)
          (chandler lock)
          (chandler runtime))

  (define native-root (make-parameter "lib"))
  (define loaded (make-hashtable string-hash string=?))   ; 幂等注册表

  ;; (activate [root]) —— 一步:挂库路径 + 载 native
  (define activate
    (case-lambda
      [() (activate ".")]
      [(root)
       (gate-runtime! root)
       (mount-library-dirs! root)
       (activate-natives root)]))

  ;; 仅挂 native(chandler run 的 preamble 用:库路径已由环境变量注入)
  (define activate-natives
    (case-lambda
      [() (activate-natives ".")]
      [(root)
       (native-root (join-paths root "lib"))
       (let ([lk (read-lock (lock-path root))])
         (for-each
           (lambda (d)
             (for-each (lambda (nat)
                         (load-native (symbol->string (locked-dep-name d))
                                      (symbol->string nat)))
                       (locked-dep-natives d)))
           (topo-order lk)))]))

  ;; 运行时版本门(manifest 有 chez/skiff 声明时)
  (define (gate-runtime! root)
    (let ([mpath (join-paths root "manifest.ss")])
      (when (file-exists? mpath)
        (let ([mf (read-manifest mpath)])
          (verify-runtime! (list (cons 'chez (manifest-chez mf))
                                 (cons 'skiff (manifest-skiff mf))))))))

  ;; 把 lib/<name>/<srcdir> 与 path 依赖根 prepend 到 library-directories
  (define (mount-library-dirs! root)
    (let* ([lk (read-lock (lock-path root))]
           [lock-dirs (map (lambda (d)
                             (lib-root root (symbol->string (locked-dep-name d))
                                       (locked-dep-srcdir d)))
                           (lock-deps lk))]
           [path-dirs (path-dep-dirs root)])
      (library-directories
        (append lock-dirs path-dirs (library-directories)))))

  ;; path 依赖不在 lock:从 manifest 读并挂(srcdir 依上游默认 ".")
  (define (path-dep-dirs root)
    (let ([mpath (join-paths root "manifest.ss")])
      (if (file-exists? mpath)
          (let ([mf (read-manifest mpath)])
            (map (lambda (d) (join-paths root (dep-source-loc d)))
                 (filter (lambda (d) (eq? 'path (dep-source-kind d)))
                         (append (manifest-deps mf) (manifest-dev-deps mf)))))
          '())))

  ;; ── load-native(总设计草案;边缘/显式控制用,常规由 activate 统一调)──
  (define load-native
    (case-lambda
      [(pkg) (load-native pkg pkg)]
      [(pkg soname)
       (let ([p (native-path pkg soname)])
         (unless (hashtable-ref loaded p #f)
           (unless (file-exists? p)
             (error 'load-native
                    (format "缺少原生库,先跑 chandler build ~a:~%  ~a" pkg p)))
           (load-shared-object p)
           (hashtable-set! loaded p #t))
         p)]))

  ;; lib/<pkg>/native/<mt>/<soname>.<ext>
  (define (native-path pkg soname)
    (let ([pkg-root (join-paths (native-root) pkg)])
      (join-paths (join-paths (join-paths pkg-root "native") (current-machine-type))
                  (string-append soname "." (so-ext)))))

  (define (lock-path root) (join-paths root "manifest.lock")))
