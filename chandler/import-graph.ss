#!chezscheme
;;; chandler/import-graph.ss --- R6RS import 解析 + 库名→路径 + 可达图(dev-time 层)
;;;
;;; 来源:bake/deps.ss(designs/06-import-graph 的解析层)。相对文件系统是**纯**的
;;; ——只读源文件,不编译。bake 那份为了共享 interaction-environment 给公开名都加了
;;; `dep-` 前缀防撞,library 词法封闭后这个理由消失,但名字保持不变:B4 搬 compile
;;; 时逐处引用,改名只会平添 diff。
;;;
;;; 三处并到 (chandler base):dep-join → string-join、dep-warn → eprintf、
;;; dep-parent-or-dot → parent-dir(空串换 ".")。
;;;
;;; **与 bake 的一处行为差异**见 §runtime-provided:chandler 是单二进制,自己的
;;; (chandler …) 库就活在构建进程里,不能算「运行时提供」。

(library (chandler import-graph)
  (export
    ;; 搜索根(designs/25 §预构建对象根)
    lib-roots lib-exts root-src root-obj prebuilt-root?
    ;; records
    make-lib-node lib-node? lib-node-name lib-node-path
    lib-node-exports lib-node-edges lib-node-includes
    make-dep-edge dep-edge? dep-edge-ref dep-edge-phase
    ;; 解析
    parse-source parse-library parse-program
    normalize-libref extract-edges dedupe-edges collect-export-names
    scan-includes level->phase
    ;; 库名 ↔ 路径 ↔ 归类
    ref->string ref->rel candidates candidates-in
    resolve-lib-path own-source-path prebuilt-lib-obj
    builtin-lib? runtime-provided-lib? classify-libref external-libref?
    reset-classify-cache!
    ;; 可达图
    build-graph
    ;; 小工具
    dep-read-all dep-find-clause dep-condition-message)
  (import (chezscheme)
          (chandler base))

  ;; ====================================================================
  ;; §配置 — 库搜索根与扩展名(designs/06 §库名→路径)
  ;;
  ;; 一个根有两种形状(designs/25 §预构建对象根):
  ;;
  ;;   "src"             源码根 —— 在这里找到的东西由我们自己编进 _build/<mt>/。
  ;;   ("src" . "obj")   预构建根 —— 源码根**配对**一棵别人已经建好的外部对象树:
  ;;                     chandler 的 <dir>/{src,<mt>} 对,或一个安装前缀。我们
  ;;                     从不往里编、也从不重编它已提供的东西,原样消费并交付。
  ;;
  ;; 第二种形状存在的理由:平台绑定产物**无法**只从源码根复现 —— 带 native 的库
  ;; 同时携带它的 C 库(<lib>/native/*)和**生成的** (<lib> native-loader),而
  ;; loader 的源码活在生产者的 _build/.gen/ 里、有意不交付(designs/24)。把这种
  ;; 依赖从 src/ 重编会直接失败:"cannot locate library (<lib> native-loader)"。
  ;; 故 <mt> 对象树不是优化,而是唯一可消费形态。
  (define lib-roots (make-parameter (list ".")))
  (define lib-exts '(".chezscheme.sls" ".sls" ".ss" ".sc"))

  (define (root-src r) (if (pair? r) (car r) r))
  (define (root-obj r) (and (pair? r) (cdr r)))
  (define (prebuilt-root? r) (pair? r))

  ;; ── records(designs/06 §术语与数据结构)──
  (define-record-type lib-node
    (fields (immutable name)        ; 符号列表,程序则为 #f
            (immutable path)        ; 源文件路径
            (immutable exports)     ; 符号列表
            (immutable edges)       ; dep-edge 列表
            (immutable includes)))  ; 字符串列表(相对源文件目录)

  (define-record-type dep-edge
    (fields (immutable ref)         ; 符号列表 —— 规范化后的库引用
            (immutable phase)))     ; 'run | 'expand | (meta . N)

  ;; ── 小工具 ──
  (define (dep-read-all path)
    (call-with-input-file path
      (lambda (p)
        (let loop ((acc '()))
          (let ((x (read p)))
            (if (eof-object? x) (reverse acc) (loop (cons x acc))))))))

  (define (ref->string ref)
    (string-append "(" (string-join (map symbol->string ref) " ") ")"))

  (define (dep-find-clause key forms)
    (cond
      ((null? forms) #f)
      ((and (pair? (car forms)) (eq? (caar forms) key)) (car forms))
      (else (dep-find-clause key (cdr forms)))))

  ;; ====================================================================
  ;; §库引用规范化 + 内建判定(designs/06)
  ;; ====================================================================

  (define (normalize-libref ref)
    ;; 保留前导符号;丢掉尾部的版本子形式。
    (if (pair? ref) (filter symbol? ref) '()))

  (define builtin-heads '(rnrs scheme chezscheme r6rs))

  (define (builtin-lib? ref)
    (or (and (pair? ref) (memq (car ref) builtin-heads) #t)
        ;; 运行时自带,且没有被某个搜索根下的源文件遮蔽
        (and (runtime-provided-lib? ref) (not (resolve-lib-path ref)))))

  ;; 正在跑的**运行时** boot 里已带的库 —— 在 skiff 上跑时的每个 (skiff …)。
  ;; 它们没有源文件可编,也不该随运行时一起装:运行时已经提供了。
  ;; 只在源码解析失败**之后**才咨询,故项目库恒胜过同名 boot 库。
  ;;
  ;; **与 bake 的差异**:chandler 是单二进制,构建器自己的 (chandler …) 库此刻就
  ;; 加载在本进程里,于是会混进 (library-list)。但它们是**工具**,不是目标运行时
  ;; 提供给应用的东西 —— 若把 (chandler base) 判成 builtin,一个忘了跑
  ;; `chandler deps` 的项目就会静默不编、不交付它,直到部署才炸。故整片
  ;; (chandler …) 从快照里排除:铺好了源码/对象自然解析得到,没铺就报
  ;; "cannot locate library",那才是可操作的错。
  (define runtime-provided
    (let ((h (make-hashtable equal-hash equal?)))
      (for-each (lambda (l)
                  (unless (and (pair? l) (eq? (car l) 'chandler))
                    (hashtable-set! h l #t)))
                (library-list))
      h))

  (define (runtime-provided-lib? ref)
    (and (pair? ref) (hashtable-ref runtime-provided ref #f) #t))

  ;; ====================================================================
  ;; §import-set → (ref . phase) 列表(designs/06 §抽取算法)
  ;; ====================================================================

  (define (level->phase lvl)
    (cond
      ((eq? lvl 'run) 'run)
      ((eq? lvl 'expand) 'expand)
      ((and (pair? lvl) (eq? (car lvl) 'meta)) (cons 'meta (cadr lvl)))
      (else 'run)))

  (define (extract-edges set phase)
    ;; only/except/rename/prefix 只是剥壳;只有 `for` 改 phase。
    (cond
      ((not (pair? set)) '())
      (else
       (case (car set)
         ((only except prefix rename) (extract-edges (cadr set) phase))
         ((library) (list (make-dep-edge (normalize-libref (cadr set)) phase)))
         ((for)
          (let ((inner (cadr set)) (levels (cddr set)))
            (apply append
                   (map (lambda (lvl) (extract-edges inner (level->phase lvl)))
                        (if (null? levels) (list 'run) levels)))))
         (else (list (make-dep-edge (normalize-libref set) phase)))))))

  (define (dedupe-edges edges)
    (let loop ((es edges) (seen '()) (out '()))
      (cond
        ((null? es) (reverse out))
        (else
         (let* ((e (car es)) (r (dep-edge-ref e)))
           (if (member r seen)
               (loop (cdr es) seen out)
               (loop (cdr es) (cons r seen) (cons e out))))))))

  ;; ====================================================================
  ;; §export 名 + include 扫描(designs/06)
  ;; ====================================================================

  (define (collect-export-names specs)
    (apply append
           (map (lambda (s)
                  (cond
                    ((symbol? s) (list s))
                    ((and (pair? s) (eq? (car s) 'rename)) (map cadr (cdr s)))
                    (else '())))
                specs)))

  (define (dep-parent-or-dot p)
    (let ((d (parent-dir p)))
      (if (string=? d "") "." d)))

  (define (dep-path-join dir rel)
    (if (string=? dir ".") rel (string-append dir "/" rel)))

  (define (scan-includes body src-path)
    (let ((dir (dep-parent-or-dot src-path)) (acc '()))
      (let walk ((x body))
        (when (pair? x)
          (cond
            ((and (memq (car x) '(include include-ci)) (pair? (cdr x)))
             (let ((arg (cadr x)))
               (if (string? arg)
                   (set! acc (cons (dep-path-join dir arg) acc))
                   (eprintf "warning: non-literal include in ~a; dependency may be missed~%"
                            src-path))))
            (else (walk (car x)) (walk (cdr x))))))
      (reverse acc)))

  ;; ====================================================================
  ;; §解析一个源文件 → lib-node(designs/06 §解析流水线)
  ;; ====================================================================

  (define (dep-condition-message e)
    (guard (x (#t "read error"))
      (if (message-condition? e) (condition-message e) "read error")))

  (define (parse-source path)
    (let ((forms (guard (e (#t (error 'parse-source
                                      (format "failed to parse ~a: ~a" path
                                              (dep-condition-message e)))))
                   (dep-read-all path))))
      (let ((lib (dep-find-clause 'library forms)))
        (if lib (parse-library lib path) (parse-program forms path)))))

  (define (parse-library form path)
    ;; form = (library <name> (export ...) (import ...) body ...)
    (let* ((name (normalize-libref (cadr form)))
           (clauses (cddr form))
           (exp-clause (dep-find-clause 'export clauses))
           (imp-clause (dep-find-clause 'import clauses))
           (body (filter (lambda (c) (not (and (pair? c)
                                               (memq (car c) '(export import)))))
                         clauses))
           (exports (if exp-clause (collect-export-names (cdr exp-clause)) '()))
           (sets (if imp-clause (cdr imp-clause) '()))
           (edges (dedupe-edges
                    (apply append (map (lambda (s) (extract-edges s 'run)) sets))))
           (includes (scan-includes body path)))
      (make-lib-node name path exports edges includes)))

  (define (parse-program forms path)
    (let* ((imp-forms (filter (lambda (f) (and (pair? f) (eq? (car f) 'import))) forms))
           (sets (apply append (map cdr imp-forms)))
           (edges (dedupe-edges
                    (apply append (map (lambda (s) (extract-edges s 'run)) sets))))
           (includes (scan-includes forms path)))
      (make-lib-node #f path '() edges includes)))

  ;; ====================================================================
  ;; §库引用 → 路径解析(designs/06 §库名→路径)
  ;; ====================================================================

  (define (ref->rel ref) (string-join (map symbol->string ref) "/"))

  (define (candidates-in roots ref)
    (apply append
           (map (lambda (root)
                  (map (lambda (ext) (string-append (root-src root) "/" (ref->rel ref) ext))
                       lib-exts))
                roots)))

  (define (candidates ref) (candidates-in (lib-roots) ref))

  (define (%first-existing cs)
    (let loop ((cs cs))
      (cond
        ((null? cs) #f)
        ((file-exists? (car cs)) (car cs))
        (else (loop (cdr cs))))))

  (define (resolve-lib-path ref) (%first-existing (candidates ref)))

  ;; 能在**非预构建**根下解析到的源码 = 我们自己编的(预构建根排除在外)。
  (define (own-source-path ref)
    (%first-existing
      (candidates-in (filter (lambda (r) (not (prebuilt-root? r))) (lib-roots)) ref)))

  ;; 预构建库的对象根,即某个外部对象树里已经有 <ref>.so 的那个根。返回对象目录,或 #f。
  (define (prebuilt-lib-obj ref)
    (let loop ((rs (lib-roots)))
      (cond
        ((null? rs) #f)
        ((and (prebuilt-root? (car rs))
              (file-exists? (string-append (root-obj (car rs)) "/" (ref->rel ref) ".so")))
         (root-obj (car rs)))
        (else (loop (cdr rs))))))

  ;; 一条边怎么被满足。**顺序要紧**:
  ;;   builtin        — 运行时/boot 提供;无可编、无可交付
  ;;   <源码路径>     — 我们的源码;编它(项目库恒胜过同名预构建库)
  ;;   prebuilt       — 外部对象树提供;原样消费 + 交付
  ;;   <源码路径>     — 预构建根 src/ 下的纯源码依赖(没有交付对象)→ 自己编
  ;;   #f             — 解析不到
  ;; 记忆化:每轮指纹计算都会逐边咨询它。缓存键带上 roots,故后来的
  ;; (define-lib-roots …) / codegen-root 追加不会拿到旧搜索路径下形成的结论。
  (define classify-cache (make-hashtable equal-hash equal?))

  (define (classify-libref ref)
    (let* ((key (cons ref (lib-roots)))
           (hit (hashtable-ref classify-cache key 'miss)))
      (if (eq? hit 'miss)
          (let ((r (cond
                     ((builtin-lib? ref) 'builtin)
                     ((own-source-path ref) => values)
                     ((prebuilt-lib-obj ref) 'prebuilt)
                     ((resolve-lib-path ref) => values)
                     (else #f))))
            (hashtable-set! classify-cache key r)
            r)
          hit)))

  ;; 同一进程里连着建两次时清缓存:两次之间磁盘可能变了(codegen 生成了 loader
  ;; 源码、依赖被重新铺过),而缓存键只带 roots、不带文件存在与否。bake 是
  ;; 「一次调用 = 一个进程」故无此需;chandler 是单二进制,必须能显式复位。
  (define (reset-classify-cache!) (hashtable-clear! classify-cache))

  ;; 我们**不**编的边:运行时提供的,或外部对象树提供的。二者都排除出构建图、
  ;; 排除出编译前置、排除出指纹。
  (define (external-libref? ref) (memq (classify-libref ref) '(builtin prebuilt)))

  ;; ====================================================================
  ;; §可达图 + 环检测(I5/I9/I10)
  ;; ====================================================================

  (define (build-graph entry-paths)
    ;; 返回从 entry-paths 可达的 lib-node 列表。库依赖成环、或非内建库解析不到,即抛。
    (define nodes (make-hashtable string-hash string=?))
    (define (label path node)
      (if (lib-node-name node) (ref->string (lib-node-name node)) path))
    (define (visit path chain)
      (cond
        ((assoc path chain)
         (let ((labels (append (map cdr (reverse chain))
                               (list (cdr (assoc path chain))))))
           (error 'build-graph
                  (format "cyclic library dependency: ~a" (string-join labels " → ")))))
        ((hashtable-ref nodes path #f) (void))
        (else
         (let* ((node (parse-source path)) (lbl (label path node)))
           (hashtable-set! nodes path node)
           (for-each
             (lambda (edge)
               (let* ((ref (dep-edge-ref edge))
                      (how (classify-libref ref)))
                 (cond
                   ((eq? how 'builtin) (void))
                   ;; 外部对象树拥有它:对我们不透明,**不**下降
                   ;; (它生成的 loader 没有源码可解析)。
                   ((eq? how 'prebuilt) (void))
                   ((string? how) (visit how (cons (cons path lbl) chain)))
                   (else
                    (error 'build-graph
                           (format "cannot locate library ~a\n  searched: ~a"
                                   (ref->string ref)
                                   (string-join (candidates ref) ", ")))))))
             (lib-node-edges node))))))
    (for-each (lambda (e) (visit e '())) entry-paths)
    (vector->list (hashtable-values nodes)))

  )
