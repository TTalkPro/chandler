#!chezscheme
;;; chandler/runtime-paths.ss --- 应用 + 库资源定位 API(designs/11 §3-4,§7)

(library (chandler runtime-paths)
  (export resource-path find-resource-path
          define-resource-path-resolver)
  (import (chezscheme)
          (chandler util)
          (chandler layout)
          (chandler fs))

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

  ;; ══════════════════════════════════════════════════════════════════
  ;; 资源定位:**扫 (library-directories)**(2026-07-24 起的统一 API)
  ;;
  ;; 一个调用覆盖全部四态,且**不依赖任何环境变量**:
  ;;
  ;;   (resource-path '(mylib sub) "schema.json")
  ;;   (resource-path '(myapp) "hello.txt")          ; app 就是一个库,不特殊
  ;;
  ;; 解析序:
  ;;   ① 顺序扫 (library-directories) 的每个条目,**src 侧与 obj 侧都看**:
  ;;        <side>/resources/<libpath>/<segs>
  ;;      条目序即优先级 —— chandler 的 run/repl/activate 把项目前缀排在全局之前,
  ;;      故项目自己的资源自然遮蔽全局装的同名库。
  ;;   ② 兜底:(library-object-filename libref) 反推安装前缀,再拼
  ;;        <prefix>/src/resources/<libpath>/<segs>
  ;;      —— 覆盖「库从某个不在 library-directories 里的前缀被加载」的情形。
  ;;
  ;; **为什么没有 APP_ROOT**:资源与库住在同一个前缀里,而进程要能 import 那个
  ;; 库,该前缀本来就必须在 library-directories 上 —— 那张表本身就是「我在对着哪些
  ;; 前缀跑」的权威答案,再要一个环境变量说同一件事是重复,还多一条会漂移的路径。
  ;; (D8:APP_ROOT 环境变量已完全去除,native-loader 同样只扫 library-directories,
  ;; 见 chandler/native-build.ss。)
  ;;
  ;; obj 侧也扫:一个只挂了对象目录的前缀(src=obj 的字符串条目)照样能命中。
  ;; ══════════════════════════════════════════════════════════════════

  ;; libref → path 形:(mylib sub) → "mylib/sub"
  (define (libref->path libref)
    (string-join (map symbol->string libref) "/"))

  ;; 一个 library-directories 条目 → 它的 (src obj) 两侧(字符串条目两侧同一)
  (define (entry-sides e)
    (if (pair? e)
        (if (string=? (car e) (cdr e)) (list (car e)) (list (car e) (cdr e)))
        (list e)))

  (define (scan-library-directories libpath segs)
    (let loop ([entries (library-directories)])
      (and (pair? entries)
           (or (let side-loop ([sides (entry-sides (car entries))])
                 (and (pair? sides)
                      (let ([path (apply join-paths
                                         (cons (src-resource-dir (car sides) libpath) segs))])
                        (if (file-exists? path) path (side-loop (cdr sides))))))
               (loop (cdr entries))))))

  ;; 兜底:从 object filename 反推安装前缀
  ;;   /prefix/<mt>/mylib/sub.so → N+1 次 parent-dir(N = libref 段数)
  ;; library-object-filename 对未加载库抛异常 —— ignore-errors 捕获后返回 #f
  (define (prefix-from-object obj-path n)
    (if (= n 0) obj-path (prefix-from-object (parent-dir obj-path) (- n 1))))

  (define (via-object libref libpath segs)
    (let ([obj (ignore-errors (library-object-filename libref))])
      (and obj
           (let* ([prefix (prefix-from-object obj (+ (length libref) 1))]
                  [path (apply join-paths
                               (cons (prefix-resource-dir prefix libpath) segs))])
             (and (file-exists? path) path)))))

  (define (locate-resource libref segs)
    (unless (and (pair? libref) (for-all symbol? libref))
      (error 'resource-path "library reference must be a list of symbols" libref))
    (for-each validate-resource-segment segs)
    (let ([libpath (libref->path libref)])
      (or (scan-library-directories libpath segs)
          (via-object libref libpath segs))))

  ;; 严格:找不到即报错,并把**搜过哪里**说出来(可操作)
  (define (resource-path libref . segs)
    (or (locate-resource libref segs)
        (error 'resource-path
               (format "resource not found: ~a under resources/~a/ in any library directory~%  searched: ~a"
                       (if (null? segs) "(the directory itself)" (car (reverse segs)))
                       (libref->path libref)
                       (string-join (map (lambda (e) (car (entry-sides e)))
                                         (library-directories))
                                    ", ")))))

  ;; 可选:找不到返回 #f;**非法 segment 照旧当场拒**(路径穿越不该被降级成静默 #f)
  (define (find-resource-path libref . segs)
    (locate-resource libref segs))

  ;; 声明式 resolver 宏(designs/11 §7.2)—— 薄 wrapper,不缓存 prefix。
  ;; app 与 lib 自此同一形式:app 也是一个库,写自己的库名即可。
  ;;   (define-resource-path-resolver res '(myapp))
  (define-syntax define-resource-path-resolver
    (syntax-rules ()
      [(_ name 'libref)
       (define (name . segs)
         (apply resource-path 'libref segs))])))