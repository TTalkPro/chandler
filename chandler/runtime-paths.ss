#!chezscheme
;;; chandler/runtime-paths.ss --- 应用 + 库资源定位 API(designs/11 §3-4,§7)

(library (chandler runtime-paths)
  (export app-root app-name app-resource-path find-app-resource-path
          lib-resource-path find-lib-resource-path
          define-resource-path-resolver)
  (import (chezscheme)
          (chandler util)
          (chandler layout)
          (chandler fs))

  ;; APP_ROOT = 进程所依的**库前缀**(全局 ~/.local/share/chez · 项目自己的 lib/ ·
  ;; 解开的 pack —— 三者同构)。由 `chandler run`/`repl`/`activate` 或 pack 启动器在
  ;; 起进程前设好;未设置时退回从入口脚本位置推导(此时多半不是前缀,只能尽力)。
  (define (app-root)
    (or (getenv* "APP_ROOT")
        (let ([parent (parent-dir (car (command-line)))])
          (if (or (string=? parent "") (string=? parent "."))
              "."
              parent))))

  ;; 调用者只能传入单个安全路径段，不能预拼路径。
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

  ;; 应用名 —— 资源落在 <app-root>/src/resources/<app>/(C4:与依赖资源
  ;; src/resources/<libpath>/ 及全局安装前缀逐层同构),故必须回答「我是谁」。三级:
  ;;   ① APP_NAME 显式(共享前缀里装了多个应用时,启动器传);
  ;;   ② <app-root>/.chandler/ 下的唯一条目 —— pack 恒只写一个(chandler pack 的
  ;;      write-app-manifest!),故包内不必再加第二个 env,APP_ROOT 仍是唯一必需变量;
  ;;   ③ 取不到 → #f(认不出前缀属于谁,不猜)。
  (define (app-name)
    (or (getenv* "APP_NAME")
        (sole-chandler-entry (app-root))))

  (define (sole-chandler-entry root)
    (let ([d (join-paths root ".chandler")])
      (and (file-directory? d)
           (let ([es (filter (lambda (e) (file-directory? (join-paths d e)))
                             (dir-entries d))])
             (and (pair? es) (null? (cdr es)) (car es))))))

  ;; 一种拼法:<prefix>/src/resources/<app>/…(落点定义见 (chandler layout) 的
  ;; prefix-resource-dir)。APP_ROOT 恒指向一个**库前缀**,三态同构(全局装
  ;; ~/.local/share/chez · 项目自己的 lib/ · 解开的 pack),故这里不分支、也没有
  ;; 第二条候选;项目源码里的 resources/ 由 chandler 铺进 lib/src/resources/<name>/。
  ;; 严格与可选查找共用路径构造,只有缺失处理不同。
  (define (build-app-resource-path segs)
    (for-each validate-resource-segment segs)
    (let ([app (app-name)])
      (unless app
        (error 'app-resource-path
               (string-append
                 "cannot tell which app this prefix belongs to: no APP_NAME, and "
                 (join-paths (app-root) ".chandler")
                 " does not hold exactly one entry (run via `chandler run` or a pack launcher)")))
      (apply join-paths (cons (prefix-resource-dir (app-root) app) segs))))

  (define (app-resource-path . segs)
    (let ([path (build-app-resource-path segs)])
      (if (file-exists? path)
          path
          (error 'app-resource-path (string-append "resource not found: " path)))))

  ;; 可选查找:认不出应用名也只是「找不到」,但**非法 segment 照旧当场拒**
  ;; (路径穿越不该被降级成 #f 静默放过)。
  (define (find-app-resource-path . segs)
    (for-each validate-resource-segment segs)
    (let ([app (app-name)])
      (and app
           (let ([path (apply join-paths
                              (cons (prefix-resource-dir (app-root) app) segs))])
             (and (file-exists? path) path)))))

  ;; ══════════════════════════════════════════════════════════════════
  ;; lib 资源定位(designs/11 §4):基于 (library-object-filename) 反推 prefix
  ;; ══════════════════════════════════════════════════════════════════

  ;; libref → path 形:(mylib sub) → "mylib/sub"
  (define (libref->path libref)
    (string-join (map symbol->string libref) "/"))

  ;; 从 object filename 反推 install prefix:
  ;; /prefix/<mt>/mylib/sub.so → N+1 次 parent-dir(N = libref 段数)
  (define (prefix-from-object obj-path n)
    (if (= n 0)
        obj-path
        (prefix-from-object (parent-dir obj-path) (- n 1))))

  ;; 主路径:object filename → prefix → src/resources/<libpath>/<segs>
  ;; library-object-filename 对未加载库抛异常 —— ignore-errors 捕获后走 source fallback
  (define (lib-resource-via-object libref segs)
    (let ([obj (ignore-errors (library-object-filename libref))])
      (and obj
           (let* ([n (+ (length libref) 1)]              ; N 段 libref + 1 段 <mt>
                  [prefix (prefix-from-object obj n)]
                  [libpath (libref->path libref)]
                  [base (prefix-resource-dir prefix libpath)]
                  [path (apply join-paths (cons base segs))])
             (and (file-exists? path) path)))))

  ;; fallback:source-only / built-in → 遍历 library-directories 的 src 侧
  (define (lib-resource-via-source libref segs)
    (let ([libpath (libref->path libref)]
          [dirs (library-directories)])
      (let loop ([entries dirs])
        (if (null? entries)
            #f
            (let* ([entry (car entries)]
                   [src-dir (if (pair? entry) (car entry) entry)])
              (let ([src-file (join-paths src-dir (string-append libpath ".ss"))])
                (if (file-exists? src-file)
                    ;; src-dir 就是 <prefix>/src,资源正在它下面 —— 不必再回到 prefix
                    (let* ([base (src-resource-dir src-dir libpath)]
                           [path (apply join-paths (cons base segs))])
                      (or (and (file-exists? path) path)
                          (loop (cdr entries))))
                    (loop (cdr entries)))))))))

  ;; 公共 API:先校验 segment,再尝试 object / source 两条路径
  (define (lib-resource-path libref . segs)
    (for-each validate-resource-segment segs)
    (or (lib-resource-via-object libref segs)
        (lib-resource-via-source libref segs)
        (error 'lib-resource-path
               "resource not found for library" libref)))

  (define (find-lib-resource-path libref . segs)
    (for-each validate-resource-segment segs)
    (or (lib-resource-via-object libref segs)
        (lib-resource-via-source libref segs)))

  ;; M5:声明式 resolver 宏(designs/11 §7.2)—— 薄 wrapper,不缓存 prefix
  (define-syntax define-resource-path-resolver
    (syntax-rules (app)
      [(_ name app)
       (define (name . segs)
         (apply app-resource-path segs))]
      [(_ name 'libref)
       (define (name . segs)
         (apply lib-resource-path 'libref segs))])))