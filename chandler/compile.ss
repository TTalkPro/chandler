#!chezscheme
;;; chandler/compile.ss --- 编译层:import 图降解为 file 任务 + 指纹失效(dev-time 层)
;;;
;;; 来源:bake/compile.ss(§18 编译层 / §18b 指纹 / §18c WPO / §18e 并行 /
;;; §18g boot / §18d clean)。recipe 面 API:`(define-lib-roots …)`、
;;; `(library-task name entry)`、`(program-task …)`、`(boot-task …)`、`(prebuilt …)`。
;;; 把库的 import 图降解成第一迭代的 file 任务,执行器(invoke/needed?/run-once/
;;; 环检测)原样复用。
;;;
;;; 搬运期的改名与取舍(理由见 TASK.md P6 §B4 实现期决定):
;;;   bake-build-dir → build-dir;manifest → fp-manifest(chandler 的 "manifest"
;;;   是包清单,同名两义会害人);bake-runtime → worker-runtime(默认取**父进程
;;;   所在运行时**);*generate-wpo*/*gen-roots* → parameter;
;;;   §18f bake 自举(cmd-bootstrap/build-bake-all!)整段不搬 —— chandler 的安装
;;;   由自含的 bootstrap.ss 负责;`--compile-one` 自调用改**生成独立 worker 脚本**。

(library (chandler compile)
  (export
    ;; 落点 / 路径 / 运行时能力
    build-dir ref->so node->so lib-dir-pairs root->dir-pair compiler-available?
    ;; 任务注册(recipe 面)
    define-lib-roots prebuilt library-task program-task boot-task
    entry->path register-compile-task! non-builtin-edges
    ;; 编译动作
    compile-lib link-whole-program link-boot-file topo-sort-sos
    compile-nodes compile-kinds *generate-wpo* *gen-roots*
    ;; 指纹 + 清单(designs/07)
    fp-manifest fingerprint-providers fingerprint-of fingerprint-target?
    flags-string needed-compile? needed-unit?
    fp-manifest-path load-fp-manifest! write-fp-manifest! reset-fingerprint-cache!
    ;; 并行构建(designs/11)
    parallel-build!
    worker-runtime worker-script-path write-worker-script! worker-cmd
    ;; dev 态工效 / clean
    consumer-lib-roots libdirs-string cmd-clean
    ;; 装配 + 复位(必须由入口显式调用,见文件末尾)
    install-compile-hooks! reset-compile-state!)
  (import (chezscheme)
          (chandler base)
          (chandler task-engine)
          (chandler recipe)
          (chandler import-graph))

  ;; ====================================================================
  ;; §18 编译层 — designs/06 §降解为 file 任务 + designs/07
  ;; ====================================================================

  (define (build-dir) (string-append "_build/" (current-machine-type)))

  ;; WPO 注入开关(designs/09)。默认关;(program-task …) 打开它,于是本次运行的
  ;; **每次**编译都产 .wpo —— 全程序链接需要全部 .wpo(难点 6)。它进 flags-string,
  ;; 故一开一关就使指纹失效。
  (define *generate-wpo* (make-parameter #f))

  ;; codegen 根(designs/24):B5 的 native 生成 loader 源码后往这里追加。
  ;; define-lib-roots 会把它接回去 —— 那个宏**覆盖** lib-roots,一份写
  ;; (define-lib-roots ".") 的 recipe 否则会把 _build/.gen 丢掉,build-graph
  ;; 就解析不到生成的 (<lib> native-loader)。
  (define *gen-roots* (make-parameter '()))

  ;; 目标 .so 路径 → lib-node,好让 needed? 选指纹通路。
  (define compile-nodes (make-hashtable string-hash string=?))

  ;; 目标 .so 路径 → 'library | 'program | 'boot-entry。逐目标覆盖;
  ;; 没有则由 node 推(有名字是 library,否则 program)。
  (define compile-kinds (make-hashtable string-hash string=?))

  ;; 我们**自己编**的边 —— 排除运行时提供的、以及预构建对象根提供的
  ;; (import-graph §classify-libref)。二者在 _build/<mt>/ 下都没有 .so,故都不能
  ;; 成为前置、也不能进指纹。
  (define (non-builtin-edges node)
    (filter (lambda (e) (not (external-libref? (dep-edge-ref e)))) (lib-node-edges node)))

  ;; 给 `library-directories` 的 (源 . 对象) 对。普通根与我们自己的构建树配对。
  ;;
  ;; 预构建根变成 (obj . obj) —— **只给对象**,它的源码那半边有意不交给 Chez。
  ;; 两半都给,Chez 就可能从**源码**加载该依赖,于是烤进我们 .so 的编译实例是
  ;; Chez 在内存里现做的那个,而不是我们即将交付的 .so:
  ;;   "loading …/mylib.so yielded a different compilation instance of (mylib)
  ;;    from that required by compiled (zconsumer)"
  ;; —— 这种故障只在部署好的安装里现形。源码那半边是我们自己的事(解析 + 诊断,
  ;; import-graph);Chez 从预构建根消费的,必须正是要交付的东西。
  (define (root->dir-pair r bdir)
    (if (prebuilt-root? r)
        (cons (root-obj r) (root-obj r))
        (cons r bdir)))

  (define (lib-dir-pairs) (map (lambda (r) (root->dir-pair r (build-dir))) (lib-roots)))

  ;; 一个根传给 worker 的线格式:"src" | "obj<sep><sep>obj"(Chez 自己的
  ;; CHEZSCHEMELIBDIRS 编码,故读起来自然;分隔符随平台 —— bake 那份写死 "::",
  ;; 在 Windows 上是错的)。普通根裸传,由 worker 与它拿到的 build-dir 配对;
  ;; 预构建根按解析好的「只给对象」对传过去。
  (define (root->arg r)
    (if (prebuilt-root? r) (entry->arg (cons (root-obj r) (root-obj r))) r))

  (define (arg->root s)
    (let* ((sep (string-append (path-sep) (path-sep)))
           (i (string-search s sep)))
      (if i
          (cons (substring s 0 i) (substring s (+ i (string-length sep)) (string-length s)))
          s)))

  ;; lib-ref(符号列表)→ _build/<mt>/a/b/c.so
  (define (ref->so ref)
    (string-append (build-dir) "/" (string-join (map symbol->string ref) "/") ".so"))

  ;; 一个 node 自己的 .so 目标。程序(name = #f)用源文件主干名。
  (define (node->so node)
    (if (lib-node-name node)
        (ref->so (lib-node-name node))
        (string-append (build-dir) "/" (path-root (lib-node-path node)) ".so")))

  ;; parent-dir-or-dot 已收入 (chandler fs),经 (chandler base) 复用。

  ;; 本运行时有没有编译器。**Petite 没有** —— 它把 compile-library 绑着,但一调
  ;; 就抛 "compile package is not loaded",错在很深的地方、话也难懂。探测一次
  ;; (真编一个最小库到临时文件)后记住,好在入口处给出可操作的话。
  (define %compiler-known (make-parameter 'unknown))

  (define (compiler-available?)
    (case (%compiler-known)
      ((unknown)
       (let* ((stem (string-append (system-temp-dir) "/chandler-compiler-probe-"
                                   (number->string (get-process-id))))
              (src (string-append stem ".ss"))
              (obj (string-append stem ".so"))
              (ok (guard (e (#t #f))
                    (write-text src
                      "(library (chandler compiler-probe) (export p) (import (chezscheme)) (define p 1))")
                    (parameterize ((current-output-port (open-output-string)))
                      (compile-library src obj))
                    #t)))
         (ignore-errors (when (file-exists? src) (delete-file src)))
         (ignore-errors (when (file-exists? obj) (delete-file obj)))
         (%compiler-known ok)
         ok))
      (else (%compiler-known))))

  ;; 编译一个 node,统一注入编译旗标(designs/07 §编译动作 / 09 / 13),然后记下
  ;; 它的指纹。kind:compile-kinds 覆盖优先,否则有名字即 library,再否则 program。
  ;; boot-entry 走 compile-file —— make-boot-file 不接受
  ;; compile-program 的产物。
  (define (compile-lib node target)
    (unless (compiler-available?)
      (bail-config
        "this runtime has no compiler (Petite does not ship one) — build with `scheme` or `skiff`"))
    (ensure-dir (parent-dir-or-dot target))
    (let ((kind (or (hashtable-ref compile-kinds target #f)
                    (if (lib-node-name node) 'library 'program))))
      (parameterize ((library-directories (lib-dir-pairs))
                     (optimize-level *optimize-level*)
                     (generate-wpo-files (*generate-wpo*)))
        (case kind
          ((library)    (compile-library (lib-node-path node) target))
          ((program)    (compile-program (lib-node-path node) target))
          ((boot-entry) (compile-file    (lib-node-path node) target)))))
    (hashtable-set! fp-manifest target (fingerprint-of target)))

  ;; 每个 lib-node 一个 file 任务:目标 = .so,前置 = 源文件 + 上游 .so +
  ;; include 文件(designs/06 §降解为 file 任务)。
  (define (register-compile-task! node)
    (let* ((target  (node->so node))
           (up-sos  (map (lambda (e) (ref->so (dep-edge-ref e))) (non-builtin-edges node)))
           (prereqs (append (list (lib-node-path node)) up-sos (lib-node-includes node)))
           (action  (lambda (t deps) (compile-lib node t))))
      (hashtable-set! compile-nodes target node)
      (register-task! target 'file prereqs action #f)))

  ;; ====================================================================
  ;; §18b 指纹 + 清单 — designs/07 §Fingerprint / Manifest
  ;;   fingerprint = sha256(源 ‖ include 哈希 ‖ 旗标 ‖ chez 版本 ‖ machine-type
  ;;                        ‖ 上游指纹)。
  ;;   基于**内容**:只 touch 不改内容**不**重编;改旗标 / 换 Chez 版本**会**重编
  ;;   —— 这正是 mtime 抓不到的。
  ;;
  ;;   名字:bake 里叫 `manifest`,但 chandler 的 "manifest" 是包清单
  ;;   (chandler-manifest.ss / chandler-manifest.lock),同名两义会害人,故一律 fp- 前缀。
  ;;   磁盘文件名保持 `.bake-manifest` 不变 —— 过渡期 bake 子进程仍可能写它,
  ;;   改名只会让双方各自重编一遍。
  ;; ====================================================================

  (define fp-manifest (make-hashtable string-hash string=?))   ; target → 记录的指纹
  (define fp-cache    (make-hashtable string-hash string=?))   ; target → 指纹(本次运行)
  (define *fp-tmp-counter* 0)

  ;; target → 算它指纹的 thunk。让非 lib-node 的目标(如 native 后端,designs/20)
  ;; 也能走同一条指纹失效 + 清单通路,而不是回落到 mtime。
  (define fingerprint-providers (make-hashtable string-hash string=?))

  ;; 并行构建的 sh 脚本用(§18e)。名字带 pid,并发进程不撞。
  (define (fp-tmp)
    (set! *fp-tmp-counter* (+ *fp-tmp-counter* 1))
    (string-append (system-temp-dir) "/chandler-fp-" (number->string (get-process-id))
                   "-" (number->string *fp-tmp-counter*)))

  ;; 只清本轮的指纹缓存(编译旗标改变后要重算;整体复位见 reset-compile-state!)。
  (define (reset-fingerprint-cache!) (hashtable-clear! fp-cache))

  (define (flags-string)
    (string-append "optimize-level=" (number->string *optimize-level*)
                   ";generate-wpo-files=" (if (*generate-wpo*) "#t" "#f")))

  (define (fingerprint-of target)
    (or (hashtable-ref fp-cache target #f)
        (let ((prov (hashtable-ref fingerprint-providers target #f))
              (node (hashtable-ref compile-nodes target #f)))
          (let ((fp
                 (cond
                   (prov (prov))                    ; 自定义提供者(native …)
                   (node
                     (let* ((src-h  (sha256-file (lib-node-path node)))
                            (inc-hs (list-sort string<?
                                               (map sha256-file (lib-node-includes node))))
                            (ups    (list-sort string<?
                                               (map (lambda (e) (ref->so (dep-edge-ref e)))
                                                    (non-builtin-edges node))))
                            (up-fps (map fingerprint-of ups)))
                       (sha256-string
                         (string-append src-h
                                        "\nINC\n"   (string-join inc-hs ",")
                                        "\nFLAGS\n" (flags-string)
                                        "\nCHEZ\n"  (scheme-version)
                                        "\nMT\n"    (current-machine-type)
                                        "\nDEPS\n"  (string-join up-fps ",")))))
                   ;; 不认识的目标 —— 文件在就哈希它
                   ((file-exists? target) (sha256-file target))
                   (else "absent"))))
            (hashtable-set! fp-cache target fp)
            fp))))

  ;; 一个编译任务需要做,当且仅当 .so 不在、或指纹与上次成功编译时记录的不同。
  ;;
  ;; 判「不需要」时还要**保证对象不比源码旧**,见 refresh-object-mtime! —— 这是
  ;; 「内容指纹」与 Chez 内部「mtime 判据」不一致处的收口,放在这里是因为顺序要紧:
  ;; invoke 先处理前置再处理目标,故上游在这里被 touch,恰好早于下游的编译。
  (define (needed-compile? t node)
    (let ((target (task-name t)))
      (cond
        ((not (file-exists? target)) #t)
        (else
         (let ((recorded (hashtable-ref fp-manifest target #f)))
           (cond
             ((and recorded (string=? recorded (fingerprint-of target)))
              (refresh-object-mtime! target)
              #f)
             (else #t)))))))

  ;; ── 内容指纹 vs Chez 的 mtime 判据:一处必须收口的分歧 ──
  ;;
  ;; 我们按**内容**决定重编(designs/07:touch 不重编);而 Chez 在
  ;; `compile-library` 内部解析上游库时按 **mtime** 判新旧。源码 mtime 变新但内容
  ;; 不变时(切分支、把源码拷进已建好的树),两者会打架:指纹说「无需重编」,Chez
  ;; 却在编译**下游**时于内存里重编了上游 —— 产出的 `.so` 记的编译实例与磁盘上那个
  ;; 上游 `.so` 对不上。
  ;;
  ;; 症状很刺眼且**只在部署态现形**:这批对象只能以 `src::obj` **对**加载;只挂对象
  ;; 侧(pack 启动器、`(prebuilt …)` 消费)就报
  ;;   "loading …/fs.so yielded a different compilation instance of (chandler fs)
  ;;    from that required by compiled (chandler runtime-paths)"
  ;;
  ;; 修法:内容既然已由指纹证明相同,**touch 对象**即可,不必重编 —— 既保住
  ;; 「touch 不重编」,又让 Chez 的视角与我们一致。Chez 没有 utime 绑定,故用
  ;; 「拷到临时名 + rename」做原子替换(rename 保证中途失败不会留下半个对象)。
  ;;
  ;; (另一条路是编译时把自己的根也按「只给对象」挂,让 Chez 根本看不见源码 ——
  ;;  更彻底,但会把「图里漏了一条边」从静默回退变成硬错,影响面大得多。)
  (define (refresh-object-mtime! target)
    (let ((node (hashtable-ref compile-nodes target #f)))
      (when node
        (let ((newest (newest-source-mtime node)))
          (when (and newest (time>? newest (file-modification-time target)))
            (touch-file! target))))))

  (define (newest-source-mtime node)
    (let loop ((ps (cons (lib-node-path node) (lib-node-includes node))) (best #f))
      (cond
        ((null? ps) best)
        ((not (file-exists? (car ps))) (loop (cdr ps) best))
        (else
         (let ((m (file-modification-time (car ps))))
           (loop (cdr ps) (if (or (not best) (time>? m best)) m best)))))))

  (define (touch-file! path)
    (let ((tmp (string-append path ".chandler-touch")))
      (ignore-errors
        (copy-file path tmp)
        (move-file tmp path))
      (ignore-errors (when (file-exists? tmp) (delete-file tmp)))))

  (define (fp-manifest-path) (string-append (build-dir) "/.bake-manifest"))

  (define (load-fp-manifest!)
    (let ((p (fp-manifest-path)))
      (when (file-exists? p)
        (call-with-input-file p
          (lambda (port)
            (let loop ()
              (let ((line (get-line port)))
                (unless (eof-object? line)
                  (let ((sp (char-index line #\space)))
                    (when sp
                      (hashtable-set! fp-manifest
                                      (substring line 0 sp)
                                      (substring line (+ sp 1) (string-length line)))))
                  (loop)))))))))

  (define (fingerprint-target? t)
    (or (hashtable-contains? compile-nodes t)
        (hashtable-contains? fingerprint-providers t)))

  (define (write-fp-manifest!)
    (when (or (> (hashtable-size compile-nodes) 0)
              (> (hashtable-size fingerprint-providers) 0))
      (ensure-dir (build-dir))
      (call-with-output-file (fp-manifest-path)
        (lambda (port)
          (for-each (lambda (target)
                      (let ((fp (hashtable-ref fp-manifest target #f)))
                        (when fp
                          (put-string port target) (put-string port " ")
                          (put-string port fp) (put-string port "\n"))))
                    ;; 清单 GC:只写**本次**取过指纹的目标(编译节点或自定义提供者)
                    ;; —— 丢掉被删/被改 recipe 的陈条目,防止无限增长。
                    (list-sort string<?
                      (filter fingerprint-target?
                              (vector->list (hashtable-keys fp-manifest))))))
        'truncate)))

  ;; entry:源码路径字符串,或形如 '(app c) 的 lib-ref。
  (define (entry->path entry)
    (cond
      ((string? entry) entry)
      ((and (pair? entry) (for-all symbol? entry))
       (or (resolve-lib-path entry)
           (bail-config "cannot locate library ~a for library-task; searched: ~a"
                        (ref->string entry) (string-join (candidates entry) ", "))))
      (else (bail-config "library-task entry must be a path string or lib-ref, got ~s"
                         entry))))

  (define (entry-nodes entry-path)
    (guard (e ((eq? e 'bake-error) (raise e))
              (#t (bail-config "~a" (condition->string-fallback e))))
      (build-graph (list entry-path))))

  (define (find-entry-node nodes entry-path)
    (find (lambda (n) (string=? (lib-node-path n) entry-path)) nodes))

  ;; recipe 面:在一个 phony `name` 下构建 `entry` 及其传递依赖。
  (define (library-task name entry)
    (let* ((entry-path (entry->path entry))
           (nodes (entry-nodes entry-path)))
      (for-each register-compile-task! nodes)
      (let ((entry-node (find-entry-node nodes entry-path)))
        (register-task! name 'phony (list (node->so entry-node)) #f #f))))

  ;; ====================================================================
  ;; §18c 全程序交付 + WPO — designs/09
  ;;   (program-task name "src/main.sps") → 一个可跑的全程序 .so,落
  ;;   _build/<mt>/<name>.so。整轮打开 WPO(难点 6)。
  ;; ====================================================================

  ;; 把程序的 .wpo 与它全部库的 .wpo 链接成一个 .so。
  (define (link-whole-program prog-node target)
    (ensure-dir (parent-dir-or-dot target))
    (let ((wpo (path-swap-ext (node->so prog-node) ".wpo")))
      (parameterize ((library-directories (lib-dir-pairs)))
        (compile-whole-program wpo target)))
    (hashtable-set! fp-manifest target (fingerprint-of target)))

  ;; recipe 面:把 `entry`(.sps)+ 全部依赖建成一个全程序 .so。
  (define (program-task name entry)
    (*generate-wpo* #t)              ; 本轮每次编译都必须产 .wpo
    (let* ((entry-path (entry->path entry))
           (nodes (entry-nodes entry-path)))
      (for-each register-compile-task! nodes)
      (let* ((prog-node (find-entry-node nodes entry-path))
             (prog-so   (node->so prog-node))
             (delivery  (string-append (build-dir) "/" (symbol->string name) ".so")))
        ;; 交付物的指纹复用程序节点(输入相同)。
        (hashtable-set! compile-nodes delivery prog-node)
        (register-task! delivery 'file (list prog-so)
                        (lambda (t deps) (link-whole-program prog-node t)) #f)
        (register-task! name 'phony (list delivery) #f #f))))

  ;; ====================================================================
  ;; §18g boot 文件交付 — make-boot-file
  ;;   (boot-task name "src/main.ss") → 可跑的 .boot,落 _build/<mt>/<name>.boot。
  ;;   **不**碰 *generate-wpo*(boot 是 fasl 级,无 WPO)。入口走 compile-file、
  ;;   库走 compile-library,再调 Chez 的 make-boot-file 组装。
  ;; ====================================================================

;; make-boot-file 的基础 boot:优先 scheme.boot(带编译器),回落 petite.boot
;; (对分发友好)。
  (define *boot-bases* '("scheme" "petite"))

  ;; 同 register-compile-task!,但把目标标成 'boot-entry,于是 compile-lib
  ;; (以及并行 worker)把它路由到 compile-file。
  (define (register-boot-entry-task! node)
    (let* ((target  (node->so node))
           (up-sos  (map (lambda (e) (ref->so (dep-edge-ref e))) (non-builtin-edges node)))
           (prereqs (append (list (lib-node-path node)) up-sos (lib-node-includes node)))
           (action  (lambda (t deps) (compile-lib node t))))
      (hashtable-set! compile-kinds target 'boot-entry)
      (hashtable-set! compile-nodes target node)
      (register-task! target 'file prereqs action #f)))

  ;; .so 目标的拓扑序:依赖在前,入口在后。对非内建边做 DFS 后序;
  ;; 不认识的依赖(内建)跳过。
  ;; 后序结果**逆序累积、末尾一次 reverse** —— 原先每收一个目标就
  ;; (append out (list so)),把已排好的整段复制一遍(对节点数是平方级)。
  (define (topo-sort-sos nodes)
    (let ((by-so (make-hashtable string-hash string=?))
          (state (make-hashtable string-hash string=?))   ; so → 'done
          (out   '()))
      (for-each (lambda (n) (hashtable-set! by-so (node->so n) n)) nodes)
      (let visit ((ns nodes))
        (for-each
          (lambda (n)
            (let ((so (node->so n)))
              (unless (hashtable-ref state so #f)
                (hashtable-set! state so 'done)
                (for-each
                  (lambda (e)
                    (let* ((dso (ref->so (dep-edge-ref e)))
                           (dn  (hashtable-ref by-so dso #f)))
                      (when dn (visit (list dn)))))
                  (non-builtin-edges n))
                (set! out (cons so out)))))
          ns))
      (reverse out)))

  ;; 组装 .boot:基础 boot 在前,然后是拓扑排好的 .so 输入。
  (define (link-boot-file topo-sos target)
    (ensure-dir (parent-dir-or-dot target))
    (apply make-boot-file (cons* target *boot-bases* topo-sos))
    (hashtable-set! fp-manifest target (fingerprint-of target)))

  ;; recipe 面:把 `entry`(顶层 .ss)+ 依赖建成一个 .boot。
  (define (boot-task name entry)
    ;; 注意:**不**设 *generate-wpo* —— boot 是 fasl 级,无 WPO。
    (let* ((entry-path (entry->path entry))
           (nodes (entry-nodes entry-path)))
      (for-each
        (lambda (node)
          (if (lib-node-name node)
              (register-compile-task! node)        ; 库 → 'library(默认)
              (register-boot-entry-task! node)))   ; 入口 → 'boot-entry
        nodes)
      (let* ((entry-node (find-entry-node nodes entry-path))
             (topo-sos  (topo-sort-sos nodes))
             (entry-so  (node->so entry-node))
             ;; 即便拓扑序把入口排在前面,也强制它最后。
             (topo-sos  (append (filter (lambda (s) (not (string=? s entry-so))) topo-sos)
                                (list entry-so)))
             (delivery  (string-append (build-dir) "/" (symbol->string name) ".boot")))
        ;; 交付物的指纹复用入口节点(输入相同)。
        (hashtable-set! compile-nodes delivery entry-node)
        (register-task! delivery 'file topo-sos
                        (lambda (t deps) (link-boot-file topo-sos t)) #f)
        (register-task! name 'phony (list delivery) #f #f))))

  ;; ====================================================================
  ;; §18e 并行构建 — 多进程波前(designs/11,难点 7)
  ;;   在正常执行器**之前**跑:用一池子进程把所有需要的 .so 编出来、更新清单;
  ;;   之后执行器只管链接 + 跑 phony(编译产物已新鲜)。
  ;;
  ;;   **与 bake 的差异**:bake 的 worker 是 `bake --script <自己> --compile-one …`
  ;;   自调用。chandler 的 CLI 是 .sps 程序,自调用要连带解决「worker 上哪找
  ;;   (chandler …) 库」;而 worker 干的事只需要 (chezscheme)。故改为**生成一份
  ;;   自含的 worker 脚本**放进 _build/<mt>/,worker 不依赖 chandler 装在哪、
  ;;   也不需要 CLI 留 `--compile-one` 暗门。
  ;; ====================================================================

  ;; worker 用哪个可执行文件。**父进程所在的运行时**是唯一正确的默认:跨一次构建
  ;; 混用 Chez 版本会出 fasl 不匹配。CHANDLER_SKIFF / CHANDLER_SCHEME 指定具体
  ;; 可执行文件(与 run/exec/repl/启动器同一套)。
  (define (worker-runtime)
    (case (current-runtime)
      ((skiff) (or (getenv* "CHANDLER_SKIFF") "skiff"))
      (else    (or (getenv* "CHANDLER_SCHEME") "scheme"))))

  (define (worker-script-path) (string-append (build-dir) "/.compile-one.ss"))

  ;; 自含 worker 的源码:只 import (chezscheme),编一个单元就退出。
  ;; argv = (kind wpo opt source target build-dir root ...)
  (define (worker-forms)
    (let ((sep (string-append (path-sep) (path-sep))))
      `((import (chezscheme))
        (define (parent-or-dot p)
          (let loop ((i (- (string-length p) 1)))
            (cond ((< i 0) ".")
                  ((char=? (string-ref p i) #\/) (substring p 0 i))
                  (else (loop (- i 1))))))
        (define (ensure-dir d)
          (unless (or (string=? d "") (string=? d ".") (file-exists? d))
            (ensure-dir (parent-or-dot d))
            (guard (e (#t (unless (file-exists? d) (raise e))))   ; 容忍并发竞态
              (mkdir d))))
        (define pair-sep ,sep)
        (define (arg->root s)
          (let ((n (string-length s)) (m (string-length pair-sep)))
            (let loop ((i 0))
              (cond ((> (+ i m) n) s)
                    ((string=? (substring s i (+ i m)) pair-sep)
                     (cons (substring s 0 i) (substring s (+ i m) n)))
                    (else (loop (+ i 1)))))))
        (define (main args)
          (let ((kind   (list-ref args 0))
                (wpo    (string=? (list-ref args 1) "1"))
                (opt    (string->number (list-ref args 2)))
                (source (list-ref args 3))
                (target (list-ref args 4))
                (bdir   (list-ref args 5))
                (roots  (list-tail args 6)))
            (guard (e (#t (fprintf (current-error-port)
                                   "chandler: compile worker ~a failed~%" target)
                          (display-condition e (current-error-port))
                          (newline (current-error-port))
                          (exit 1)))
              (let ((s (getenv "CHANDLER_WORKER_SLEEP")))   ; 测试钩子(designs/11 L4)
                (when s (system (string-append "sleep " s))))
              (ensure-dir (parent-or-dot target))
              (parameterize ((library-directories
                               (map (lambda (a)
                                      (let ((r (arg->root a)))
                                        (if (pair? r) r (cons r bdir))))
                                    roots))
                             (optimize-level opt)
                             (generate-wpo-files wpo))
                (cond
                  ((string=? kind "lib")  (compile-library source target))
                  ((string=? kind "prog") (compile-program source target))
                  ((string=? kind "boot") (compile-file source target))
                  (else (error 'compile-worker (string-append "unknown kind: " kind))))))
            (exit 0)))
        (main (command-line-arguments)))))

  (define (write-worker-script!)
    (let ((path (worker-script-path)))
      (ensure-dir (parent-dir-or-dot path))
      (write-text-if-changed
        path
        (let ((p (open-output-string)))
          (put-string p ";;; generated by chandler --- parallel compile worker (do not edit)\n")
          (for-each (lambda (f) (write f p) (newline p)) (worker-forms))
          (get-output-string p)))
      path))

  ;; 真正的编译单元 = compile-nodes 里目标恰是该 node 自己 .so 的条目
  ;; (排除全程序/boot 交付目标 —— 那是链接不是编译)。
  (define (compile-units)
    (filter (lambda (u) (and (cdr u) (string=? (car u) (node->so (cdr u)))))
            (map (lambda (target) (cons target (hashtable-ref compile-nodes target #f)))
                 (vector->list (hashtable-keys compile-nodes)))))

  (define (unit-deps node)
    (map (lambda (e) (ref->so (dep-edge-ref e))) (non-builtin-edges node)))

  ;; 单元 DAG 上的最长路径深度(build-graph 已经拒过环)。
  (define (unit-level target node cache)
    (or (hashtable-ref cache target #f)
        (let* ((deps (unit-deps node))
               (lvl (if (null? deps) 0
                        (+ 1 (apply max (map (lambda (d)
                                               (let ((dn (hashtable-ref compile-nodes d #f)))
                                                 (if dn (unit-level d dn cache) 0)))
                                             deps))))))
          (hashtable-set! cache target lvl)
          lvl)))

  (define (worker-cmd target node)
    (let ((kind (case (or (hashtable-ref compile-kinds target #f)
                          (if (lib-node-name node) 'library 'program))
                  ((library) "lib")
                  ((program) "prog")
                  ((boot-entry) "boot"))))
      (string-append (worker-runtime) " --script " (shq (worker-script-path))
                     " " kind
                     " " (if (*generate-wpo*) "1" "0")
                     " " (number->string *optimize-level*)
                     " " (shq (lib-node-path node)) " " (shq target) " " (shq (build-dir))
                     (apply string-append
                            (map (lambda (r) (string-append " " (shq (root->arg r)))) (lib-roots))))))

  (define (split-at* lst n)
    (let loop ((i 0) (acc '()) (rest lst))
      (if (or (= i n) (null? rest))
          (values (reverse acc) rest)
          (loop (+ i 1) (cons (car rest) acc) (cdr rest)))))

  ;; 并发启一批命令,全部等完,汇总退出码。
  (define (run-chunk cmds)
    (let ((tmp (fp-tmp)) (n (length cmds)))
      (call-with-output-file tmp
        (lambda (p)
          (put-string p "rc=0\n")
          (for-each (lambda (i cmd)
                      (put-string p (string-append cmd " & p" (number->string i) "=$!\n")))
                    (iota n) cmds)
          (for-each (lambda (i)
                      (put-string p (string-append "wait $p" (number->string i) " || rc=1\n")))
                    (iota n))
          (put-string p "exit $rc\n"))
        'truncate)
      ;; tmp 落在 system-temp-dir 下,TMPDIR 含空格时不引用就会被 sh 拆成两个参数
      (let ((rc (system (string-append "sh " (shq tmp)))))
        (delete-file tmp)
        (= rc 0))))

  (define (run-bounded cmds n)
    (let loop ((cs cmds))
      (or (null? cs)
          (let-values (((chunk rest) (split-at* cs n)))
            (and (run-chunk chunk) (loop rest))))))

  ;; 用至多 N 个并发子进程编出每个需要的单元。
  (define (parallel-build! n)
    (let* ((units  (compile-units))
           (needed (filter (lambda (u) (needed-unit? (car u))) units)))
      (unless (null? needed)
        (write-worker-script!)
        (let ((cache (make-hashtable string-hash string=?)))
          (for-each (lambda (u) (unit-level (car u) (cdr u) cache)) units)
          (let ((maxlvl (apply max (map (lambda (u) (hashtable-ref cache (car u) 0)) needed))))
            (let loop ((lvl 0))
              (when (<= lvl maxlvl)
                (let ((batch (filter (lambda (u) (= (hashtable-ref cache (car u) 0) lvl)) needed)))
                  (unless (null? batch)
                    (unless (*quiet*)
                      (eprintf "chandler: -j~a level ~a: ~a unit(s)~%" n lvl (length batch)))
                    (unless (run-bounded (map (lambda (u) (worker-cmd (car u) (cdr u))) batch) n)
                      (bail-exec "parallel compile failed at level ~a" lvl))))
                (loop (+ lvl 1)))))
          ;; 成功 → 记下指纹,于是执行器不会再编一遍
          (for-each (lambda (u) (hashtable-set! fp-manifest (car u) (fingerprint-of (car u))))
                    needed)))))

  (define (needed-unit? target)
    (or (not (file-exists? target))
        (let ((rec (hashtable-ref fp-manifest target #f)))
          (not (and rec (string=? rec (fingerprint-of target)))))))

  ;; ====================================================================
  ;; §18h dev 态工效 — designs/24 §dev 态工效
  ;;   生成的 loader 只以**编译对象**形态活在 _build/<mt>/,故 dev shell 需要把
  ;;   对象目录挂上库路径 —— 单靠 `scheme --libdirs .` 已解析不到
  ;;   (<lib> native-loader)。codegen 根(_build/.gen)有意**排除**:消费者只从
  ;;   对象侧解析 loader,把源码根也给出去会让陈旧的生成源码遮蔽编译对象。
  ;; ====================================================================

  (define (consumer-lib-roots)
    (filter (lambda (r) (not (member r (*gen-roots*)))) (lib-roots)))

  ;; 与编译器用的是同一组对,故 `-j` worker 的 --libdirs 解析每个库的方式与构建一致。
  ;; (bake 那份写死 ":"/"::";这里走 (chandler layout) 的 libdirs->arg,分隔符随平台。)
  (define (libdirs-string)
    (libdirs->arg (map (lambda (r) (root->dir-pair r (build-dir))) (consumer-lib-roots))))

  ;; ====================================================================
  ;; §18d clean — 删掉我们声明过的产物(designs/10,难点 9)
  ;; ====================================================================

  (define (clean-report path)
    (unless (*quiet*) (display "rm ") (display path) (newline)))

  ;; 只删**声明过的**产物:我们生产的 file 任务目标(action ≠ #f)加整棵 _build/。
  ;; 从不碰源码(合成出来的 file 任务 action = #f),也不碰 phony。
  (define (cmd-clean)
    (let ((removed 0))
      (for-each
        (lambda (name)
          (let ((t (hashtable-ref task-registry name #f)))
            (when (and t (eq? (task-kind t) 'file) (task-action t)
                       (string? name) (file-exists? name))
              (clean-report name)
              (delete-file name)
              (sweep-empty-parents name)
              (set! removed (+ removed 1)))))
        (vector->list (hashtable-keys task-registry)))
      (when (file-exists? "_build")
        (clean-report "_build")
        (rm-rf "_build")
        (set! removed (+ removed 1)))
      (unless (*quiet*)
        (display "removed ") (display removed) (display " item(s)") (newline)))
    (*exit-code* exit-ok))

  ;; ====================================================================
  ;; §recipe 面 API — (prebuilt …) / (define-lib-roots …)
  ;; ====================================================================

  ;; (prebuilt "lib") —— 一个**预构建**库根:`chandler install` 铺下的
  ;; {src,<mt>} 对(designs/21 §落点、designs/25)。产出
  ;; ("lib/src" . "lib/<mt>"),于是:
  ;;
  ;;   (define-lib-roots "." (prebuilt "lib"))
  ;;
  ;; 从 lib/src/ 解析依赖**源码**、从 lib/<mt>/ 取它们的**编译对象** —— 消费这些
  ;; 对象而不重编,`chandler pack` 也交付它们。丢掉 <mt> 那半、只写 "lib/src",
  ;; 对纯 Scheme 依赖能建,一旦某个依赖带 native 就崩:它的 native/ 产物在这里
  ;; 重建不出来,而它生成的 (<lib> native-loader) 压根没有源码可编。
  ;;
  ;; 两参形显式点名两半,供不按标准 machine-type 分区的布局用。
  (define prebuilt
    (case-lambda
      ((dir) (cons (string-append dir "/src")
                   (string-append dir "/" (current-machine-type))))
      ((src obj) (cons src obj))))

  ;; (define-lib-roots "src" ...) —— 设库搜索根。codegen 根(*gen-roots*,
  ;; designs/24)被接回去:本形式**覆盖** lib-roots,一份写 (define-lib-roots ".")
  ;; 的 recipe 否则会把 _build/.gen 丢掉,build-graph 就解析不到生成的
  ;; (<lib> native-loader)。
  (define-syntax define-lib-roots
    (syntax-rules ()
      ((_ r ...) (lib-roots (append (list r ...) (*gen-roots*))))))

  ;; ── 装配:注册 task-engine 钩子 + 把自己挂进 recipe 求值环境 ──
  ;;
  ;; **必须显式调用**,不能只靠库体副作用:Chez **惰性实例化**库 —— 库体直到有
  ;; 绑定被真正引用才跑。而这里要的顺序恰恰相反:recipe 里的 (library-task …)
  ;; 要求「加载 recipe 之**前**」环境里就有它,那时还没人引用过 compile 的任何
  ;; 绑定。实测:只留库体副作用,`(define-lib-roots ".")` 报 unbound。
  ;; 调用点 = 任何将要 load-recipe 的入口(B6 的 CLI build 通路、测试)。幂等。
  ;;
  ;; (对照:(chandler miniregex) 的钩子注册不需要这一套 —— 它由
  ;; register-rule! 调 `regexp` 时强制实例化,而没有 rule 时那个钩子根本不会被用。)
  (define (install-compile-hooks!)
    (current-fingerprint-judge fingerprint-target?)
    (current-compile-needed needed-compile?)
    (register-recipe-library! '(chandler compile))
    (register-recipe-reset! 'compile reset-compile-state!))

  ;; 每次 load-recipe 前把本模块的全局构建状态清干净(理由见 recipe 的
  ;; recipe-reset-hooks:bake 靠进程退出复位,库化之后必须显式复位)。
  ;; fp-manifest **不**清 —— 它是磁盘上的记录,由 load-fp-manifest! 负责。
  (define (reset-compile-state!)
    (hashtable-clear! compile-nodes)
    (hashtable-clear! compile-kinds)
    (hashtable-clear! fp-cache)
    (hashtable-clear! fingerprint-providers)
    (reset-classify-cache!)
    (*generate-wpo* #f)
    (*gen-roots* '())
    (lib-roots (list ".")))

  ;; 库体也调一次(尽力而为:一旦有人引用过本库,后续就无需显式装配)。
  (install-compile-hooks!)

  )
