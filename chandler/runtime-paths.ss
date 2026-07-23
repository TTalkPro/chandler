#!chezscheme
;;; chandler/runtime-paths.ss --- 应用 + 库资源定位 API(designs/11 §3-4,§7)

(library (chandler runtime-paths)
  (export app-root app-resource-path find-app-resource-path
          lib-resource-path find-lib-resource-path
          define-resource-path-resolver)
  (import (chezscheme)
          (chandler util)
          (chandler layout)
          (chandler fs))

  ;; APP_ROOT 是部署态权威；未设置时从入口脚本位置推导。
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

  ;; 严格与可选查找共用校验和路径构造，只有缺失处理不同。
  (define (build-app-resource-path segs)
    (for-each validate-resource-segment segs)
    (apply join-paths (append (list (app-root) "resources") segs)))

  (define (app-resource-path . segs)
    (let ([path (build-app-resource-path segs)])
      (if (file-exists? path)
          path
          (error 'app-resource-path
                 (string-append "resource not found: " path)))))

  (define (find-app-resource-path . segs)
    (let ([path (build-app-resource-path segs)])
      (and (file-exists? path) path)))

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

  ;; 主路径:object filename → prefix → share/<libpath>/resources/<segs>
  ;; library-object-filename 对未加载库抛异常 —— ignore-errors 捕获后走 source fallback
  (define (lib-resource-via-object libref segs)
    (let ([obj (ignore-errors (library-object-filename libref))])
      (and obj
           (let* ([n (+ (length libref) 1)]              ; N 段 libref + 1 段 <mt>
                  [prefix (prefix-from-object obj n)]
                  [libpath (libref->path libref)]
                  [base (apply join-paths (list prefix "share" libpath "resources"))]
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
                    (let* ([prefix (parent-dir src-dir)]
                           [base (apply join-paths (list prefix "share" libpath "resources"))]
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