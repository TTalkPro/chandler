#!chezscheme
;;; chandler/build.ss --- 排单 + **进程内**编译(designs/07 §2-3, 08 §3)
;;;
;;; **2026-07-24(P6 阶段 B6)**:bake 的编译引擎已整体吸收进 chandler 的 dev-time 层
;;; ((chandler compile) / (chandler native-build)),本模块因此不再 **spawn bake**:
;;;   旧:生成 `.chandler-build.ss` → `run-check "bake" '("-f" … "build-all")` → 删文件
;;;   新:直接调 `library-task` / `native-task*` 排单,`invoke` 就地编译
;;; 少一次子进程往返、少一个写进依赖树里的临时文件,错误也不必再从子进程的 stderr
;;; 里捞。`CHANDLER_BAKE` 与 mock bake 随之作废。
;;;
;;; **C0(2026-07-24):不再有汇总的 lib/**。每个依赖在**它自己的 _vendor/ 树**里
;;; 就地编(cwd = 该树,搜索根 = "."),产物留在原地:
;;;   _vendor/<dep>/<srcdir>/_build/<mt>/   ← 编译产物,依赖之间互不干扰
;;; 按 lock 的 topo-order 逐个编,已编好的上游作为**预构建根** `(prebuilt src obj)`
;;; 挂进来(compile 里变 (obj . obj),只给对象、不重编,designs/25),故 A 依赖 B
;;; 时 B 的对象已就位。末尾再挂全局前缀作兜底(chandler 运行时门住在那)。
;;;
;;; 安全:依赖的 native 构建 = 别人的代码 = RCE,须 --allow-build 授权,且授权绑
;;; 「构建描述哈希」写入 .chandler-approvals —— 描述变了(脚本掉包)则授权失效重提示。
;;; 吸收之后这条**更要紧**:构建不再隔在子进程里,而是在本进程 eval/exec,故授权
;;; 判定必须在**排单之前**完成(下面第 1 步),不能等到 native-task 已经注册。

(library (chandler build)
  (export build build-project tree-library-files
          build-chandler-runtime!)
  (import (chezscheme)
          (chandler util)
          (chandler fs)
          (chandler proc)
          (chandler layout)
          (chandler sexp)
          (chandler manifest)
          (chandler lock)
          (chandler install)
          (chandler hash)
          (chandler task-engine)
          (chandler recipe)
          (chandler import-graph)
          (chandler compile)
          (chandler native-build))

  ;; ── 主入口:build root opts ──
  ;; opts: (allow-build . (#t | "a,b,..")) (production . bool) (verbose . bool)
  (define (build root opts)
    (let* ([lpath (project-lock-path root)])
      ;; 没有 lock = 没有依赖要编(零依赖项目如 chandler 自身从不跑 deps)。
      ;; 不是错:直接跳过依赖编译,让 cmd-build 接着编项目自身。先前无条件要求
      ;; lock,零依赖项目只能靠上一轮残留的 lock 蒙混过关(C0 e2e 时暴露)。
      (if (not (file-exists? lpath))
          0
          (build-with-lock root opts lpath))))

  (define (build-with-lock root opts lpath)
    (let* ([lk (read-lock lpath)]
           [order (topo-order lk)]
           [allow (alist-ref opts 'allow-build)]
           [approvals-path (join-paths root ".chandler-approvals")]
           [approvals (read-approvals approvals-path)])
      ;; C0 之后没有 lib/ 可查 —— 每个依赖的 _vendor 树在不在,由 build-one-dep
      ;; 逐条报(带上是哪个依赖),比这里一句笼统的前置检查更可操作。
      ;; 1) 收集需授权的 native 构建 + 校验授权
      (let ([pending '()] [to-record '()])
          (for-each
            (lambda (d)
              (let ([name (symbol->string (locked-dep-name d))])
                (unless (null? (locked-dep-natives d))
                  (let* ([spec (dep-native-spec root name)]
                         [h (approval-hash spec)])
                    (cond
                      [(approved? approvals name h) (void)]         ; 旧授权且描述未变
                      [(allowed? allow name)                        ; 本次授权 → 记录
                       (set! to-record (cons (cons name h) to-record))]
                      [else (set! pending (cons name pending))])))))
            order)
          (unless (null? pending)
            (let ([names (reverse pending)])
              (error 'build
                     (format "these dependencies need native library builds (running their build scripts means trusting their code): ~a~%  authorize with: --allow-build (all) or --allow-build=~a (these only)"
                             (string-join names ", ") (string-join names ",")))))
        ;; 2) 按拓扑序逐个依赖:就地在它自己的 _vendor/<dep>/…/_build/<mt>/ 编译
        (build-deps root order (and (alist-ref opts 'verbose) #t))

        ;; 4) 落授权(描述哈希绑定)
        (unless (null? to-record)
          (write-approvals approvals-path
                           (merge-approvals approvals (reverse to-record))))
        (unless (null? order)
          (printf "build: ~a ~a compiled into _vendor/~%"
                  (length order) (plural (length order) "dependency" "dependencies")))
        0)))

  ;; ── 逐个依赖:在**它自己的 _vendor/ 树里**就地编译,产物留在原地 ──
  ;; **拓扑序**要紧:A 依赖 B 时,编 A 需要 B 的对象已就位。故按 lock 的 topo-order
  ;; 逐个编,已编好的上游作为**预构建对象根**挂进去(见 upstream-prebuilt-roots)。
  ;;
  ;; gate 根与 fallback 根在整趟里是常量,故**提到循环外算一次**:先前每个依赖都要
  ;; 重新读一遍项目 manifest(gate-prebuilt-roots),并重新扫一遍整个全局前缀的
  ;; .registry/(fallback-roots → global-libdir)。upstream-prebuilt-roots 同理 ——
  ;; 它先前对每个依赖都把 lock 重读 + 重做一次 topo-order,而 order 就在手边。
  (define (build-deps root order verbose?)
    (let ([gate (gate-prebuilt-roots root)]
          [fallback (fallback-roots root)])
      (for-each (lambda (d) (build-one-dep root d order gate fallback verbose?)) order)))

  (define (build-one-dep root d order gate fallback verbose?)
    (let* ([name   (symbol->string (locked-dep-name d))]
           [srcdir (vendor-dir root (locked-dep-name d))])
      (unless (file-directory? srcdir)
        (error 'build (format "~a not vendored; run `chandler deps` first" srcdir)))
      (build-tree!
        srcdir
        ;; 已经建好的上游按**它们各自的**预构建根消费(C0:不再有汇总的 lib/)。
        ;; topo 序保证「排在自己前面的」都已编好;prebuilt 根在 compile 里会变成
        ;; (obj . obj),即只给对象、不给源码 —— 那正是避免「不同编译实例」的做法。
        ;; gate-prebuilt-roots 排在 upstream 与 fallback 之间:chandler 运行时门的对象
        ;; 在 _vendor/chandler/_build/<mt>/(build-chandler-runtime! 编的),优先于
        ;; 全局前缀(避免实例分歧,BUG-1)。
        (cons "." (append gate
                          (upstream-prebuilt-roots root d order)
                          fallback))
        (lambda ()
          ;; 顺序与旧的生成 recipe 一致:native 先(它把 _build/.gen 挂进搜索根,
          ;; 随后的 library-task 才解析得到生成的 (<lib> native-loader)),库在后。
          (derive-native-tasks! name (native-items (dep-native-spec root name)))
          (derive-library-tasks! (tree-library-files srcdir name)))
        all-file-targets
        verbose?
        (format "dependency ~a" name))))

  ;; 一个依赖的预构建根 (src . obj):只在它已经有 _build/<mt> 时才算(否则 #f)。
  (define (dep-prebuilt-root root u)
    (let* ([src (vendor-dir root (locked-dep-name u))]
           [obj (join-paths src "_build" (current-machine-type))])
      (and (file-directory? obj) (prebuilt src obj))))

  ;; 本依赖之前(topo 序)那些依赖的预构建根 —— 编 d 时它们必须已就位。
  ;; order 由调用方传入(build-deps 手里就有那份 topo-order),不再自己重读 lock。
  (define (upstream-prebuilt-roots root d order)
    (let loop ([ds order] [acc '()])
      (cond
        [(null? ds) (reverse acc)]
        [(eq? (locked-dep-name (car ds)) (locked-dep-name d)) (reverse acc)]
        [else (loop (cdr ds)
                    (let ([r (dep-prebuilt-root root (car ds))])
                      (if r (cons r acc) acc)))])))

  ;; 全部依赖的预构建根 —— 编项目自身时用(它可能 import 任何一个)。
  (define (all-dep-prebuilt-roots root)
    (let ([lpath (project-lock-path root)])
      (if (file-exists? lpath)
          (filter values
                  (map (lambda (u) (dep-prebuilt-root root u))
                       (topo-order (read-lock lpath))))     ; 先前这里把 lock 读了两遍
          '())))

  ;; 兜底根:chandler 运行时门(designs/12 §5)与全局装的库都住在全局前缀,而它们
  ;; **不在 lock**(gate 不是 dep)。故编译时把全局前缀作为预构建根挂在末尾 ——
  ;; 与 run 期 resolved-libdirs 的全局兜底同一条路径。它是个 (src . obj) 对,
  ;; 在 compile 里当预构建根 → (obj . obj),只给对象、不重编。
  (define (fallback-roots root)
    (filter (lambda (p) (file-directory? (cdr p))) (global-libdir)))

  ;; ── chandler 运行时门:把 CHANDLER_HOME 的对象 copy 进 _vendor(BUG-1,2026-07-24)──
  ;; deps 的 install-chandler-runtime! 已把 runtime subset 源码铺进
  ;; _vendor/chandler/chandler/<sub>.ss;此处把 CHANDLER_HOME(= 正在跑的 chandler 的
  ;; 前缀)里**已编译**的 runtime subset .so copy 进 _vendor/chandler/_build/<mt>/chandler/。
  ;;
  ;; **为什么 copy 而不是就地重编**:Chez 编译 app(import (chandler …))时,R6RS 语义
  ;; 下已加载的库(library-list)**优先**于 library-directories。chandler 自己就在跑,
  ;; (chandler runtime-paths) 等已活在进程内存里 —— Chez 编译 app 时用的是**这个内存
  ;; 实例**,其 UID = CHANDLER_HOME/ta6le/chandler/runtime-paths.so 的 UID。就地重编产生
  ;; 的是**另一个**实例,Chez 根本不看它;pack 若交付重编的那份,启动即报
  ;; "different compilation instance"。copy CHANDLER_HOME 的对象则与内存实例同源 →
  ;; build 用的实例 = pack 交付的实例 = 同一个物理对象文件。
  ;;
  ;; 故本函数**不编译**(名字沿用作 cli 入口,语义是"确保 chandler runtime 对象就位")。
  ;; 前提:正在跑的 chandler 经 bootstrap 安装(CHANDLER_HOME 有编译对象);平铺仓库
  ;; `./bin/chandler` 不满足,不应构建依赖 chandler 的 app。
  (define (build-chandler-runtime! root)
    (let* ([home (global-prefix)]            ; = chandler-home = CHANDLER_HOME
           [mt   (current-machine-type)]
           [src  (join-paths home mt "chandler")]
           [vdir (vendor-dir root 'chandler)]
           [bd   (join-paths vdir "_build" mt "chandler")])
      (unless (file-directory? (join-paths vdir "chandler"))
        (error 'build
               (format "chandler runtime source not vendored at ~a~%  (run `chandler deps` first)"
                       (join-paths vdir "chandler"))))
      (unless (file-directory? src)
        (error 'build
               (format "chandler runtime objects not found at ~a~%  (CHANDLER_HOME has no compiled chandler; the running chandler must be installed via bootstrap.ss, not run from a flat checkout)"
                       src)))
      (rm-rf (join-paths vdir "_build"))
      (for-each
        (lambda (sub)
          (let* ([f (string-append (symbol->string sub) ".so")]
                 [s (join-paths src f)])
            (when (file-exists? s)
              (let ([d (join-paths bd f)])
                (ensure-parent d)
                (copy-file s d)))))
        chandler-runtime-sublibs)))

  ;; chandler 运行时门的预构建根(BUG-1):清单声明 (chandler …) 且 _vendor/chandler
  ;; 已就地编译(对象在 _vendor/chandler/_build/<mt>/)时,返回一个 (src . obj) 预构建根。
  ;; import-graph 的 classify-libref 对 (chandler …) 遂命中 prebuilt —— 既不下降(无源码
  ;; 边可解析),也不回落到前缀源码重编(实例分歧根因)。排在 fallback 之前:项目本地
  ;; 这份才是 build/pack 同源的对象;home 前缀那份可能是另一个实例。
  (define (gate-prebuilt-roots root)
    (let* ([vdir (vendor-dir root 'chandler)]
           [obj  (join-paths vdir "_build" (current-machine-type))]
           [mpath (join-paths root "chandler-manifest.ss")])
      (if (and (file-directory? obj)
               (file-exists? mpath)
               (manifest-chandler (read-manifest mpath)))
          (list (prebuilt vdir obj))
          '())))

  ;; ── 进程内构建一棵树:切 cwd、复位状态、设搜索根、排单、跑 ──
  ;;
  ;; cwd 必须切进去:编译层的落点(`_build/<mt>/`)、搜索根(`"."`)、native 的
  ;; `(dir …)` 全是**相对该树根**的,与旧方案「在依赖树里跑 bake」语义一致。
  ;; register! 是排单回调(在 cwd 已切好、搜索根已设好之后调用);
  ;; select! 决定跑哪些目标 —— 推导出来的构建跑**全部** file 目标(等价旧的
  ;; build-all),而加载 chandler-tasks.ss 时跑它自己的 default-task(别的任务如 test
  ;; 不该被 build 顺手带跑)。
  (define (build-tree! dir roots register! select! verbose? what)
    (let ([old (current-directory)])
      (dynamic-wind
        (lambda () (current-directory dir))
        (lambda ()
          (install-compile-hooks!)
          (install-native-hooks!)
          (reset-registries!)              ; 每棵树从干净的登记表 + 构建状态起步
          (lib-roots roots)
          (register!)
          (load-fp-manifest!)
          (let ([targets (select!)])
            (quietly verbose?
              (lambda ()
                ;; 'bake-error 是引擎内部的哨兵(裸符号,不是 condition);具体原因
                ;; 它已经打到 stderr 了,这里补一句「哪棵树」的上下文再抛出去。
                (guard (e [(eq? e 'bake-error)
                           (error 'build (format "compiling ~a failed" what))])
                  (for-each (lambda (t) (invoke t '())) targets))))
            (write-fp-manifest!)))
        (lambda () (current-directory old)))))

  ;; 编译进度默认收敛(旧方案 run-check 捕获 bake 输出,用户只看到 chandler 自己的
  ;; 行);`--verbose` 放出来。Chez 的 compile-library 自己往 stdout 打
  ;; "compiling … with output to …",不受 *quiet* 管,故这里换端口而不只是设 *quiet*。
  (define (quietly verbose? thunk)
    (if verbose?
        (thunk)
        (let ([sink (open-output-string)])
          (guard (e [#t (raise e)])       ; 先解开 parameterize 再抛,免得错误信息被吞
            (parameterize ([current-output-port sink] [*quiet* #t])
              (thunk))))))

  ;; ── 排单:native(designs/20)──
  ;; 只对**已授权**的依赖调用(授权判定在 build 的第 1 步完成)。clause 列表的形状
  ;; 与 recipe 里手写 `(native-task 'x (lib y) …)` 完全一致 —— native-task* 收到的
  ;; 本就是 quote 过的字面数据,故这里程序化构造走的是同一条路径。
  (define (derive-native-tasks! owner items)
    (for-each
      (lambda (item)
        (let ([soname (native-item-soname item)])
          (native-task* soname
                        (list (list 'lib (string->symbol owner))
                              (list 'dir (native-item-path item))
                              (list 'build (native-item-backend item))
                              (list 'produces (symbol->string soname))))))
      items))

  ;; ── 排单:库(designs/06)──
  ;; 一个库包的整棵源码树就是它的公开面 —— 消费方会 import umbrella 从不引用的
  ;; 子库(chez-markding 的 extensions/ 全是选择性启用的,umbrella 一个都不 import)。
  ;; 只编 umbrella 闭包,装出来的 lib/<mt>/ 就残缺:实测 chez-markding 107 个库只
  ;; 出 49 个对象。
  ;;
  ;; 残缺还会被悄悄掩盖:消费方遇到没有对象的库会退回从 lib/src/ 现编进**应用自己
  ;; 的** _build/<mt>/(designs/25 分类第 4 档),于是同一个依赖被劈成两棵对象树,
  ;; 看着能跑而已。
  (define (derive-library-tasks! rels)
    (for-each
      (lambda (rel) (library-task (string->symbol (string-append "c-" (task-suffix rel))) rel))
      rels))

  ;; ── 编译产物**不再搬运**(C0,2026-07-24)──
  ;; 先前把 _build/<mt>/ 拷进 lib/<mt>/,是为了凑出一个「项目本地安装前缀」给消费方
  ;; 挂。既然 library-directories 收的是一**列**条目,逐依赖挂它自己的树即可:
  ;; 产物就留在 `chandler build` 编出它们的地方(_vendor/<dep>/<srcdir>/_build/<mt>/),
  ;; 少一次全量拷贝,也少一处会与 _vendor 漂移的副本。

  ;; 登记表里的全部 file 目标(推导式构建没有 default-task,跑全部即「build-all」)。
  (define (all-file-targets)
    (list-sort string<?
               (filter string? (vector->list (hashtable-keys task-registry)))))

  ;; ── 根项目自己的编译 ──
  ;;
  ;; **chandler-tasks.ss 是可选的**(2026-07-24):它是**程序**(任意 Scheme,加载即
  ;; 求值),只对根项目有意义 —— 依赖的 chandler-tasks.ss 永不执行(designs/08 §3)。
  ;; 而绝大多数项目的 build 段完全可以从清单推出来:`(name)` 给库名与 umbrella、
  ;; `(srcdir)` 给搜索根、`(native …)` 给 native 任务。故:
  ;;   有 chandler-tasks.ss → 加载它,跑它的 default-task(需要自定义任务时才写)
  ;;   没有         → 从 manifest 推导,一行 recipe 也不用写
  ;; 清单与 recipe 因此**不需要合并成一个文件**:数据仍只 read 不求值,程序仍是可选的
  ;; 单独文件,而「一个文件说清一个项目」在常见场合已经成立。
  (define (build-project root verbose?)
    (let ([recipe (join-paths root default-tasks-file)])
      (if (file-exists? recipe)
          ;; chandler-tasks.ss 自己用 (define-lib-roots …) 说搜索根,这里不越俎代庖。
          (build-tree! root (list ".")
                       (lambda () (load-recipe default-tasks-file))
                       (lambda () (select-targets '()))
                       verbose? "project recipe")
          (let ([mpath (join-paths root "chandler-manifest.ss")])
            (when (file-exists? mpath)
              (let* ([mf (read-manifest mpath)]
                     [name (manifest-name mf)]
                     [app  (manifest-app mf)]
                     [sd   (let ([s (manifest-srcdir mf)])
                             (if (or (not s) (string=? s "")) "." s))])
                (build-tree!
                  root
                  ;; C0:项目 import 的依赖在各 _vendor 树里,按预构建根消费
                  ;; (已 build 过的对象直接用,不重编);不再有汇总的 lib/。
                  ;; gate-prebuilt-roots:chandler 运行时门对象(_vendor/chandler/_build/<mt>/
                  ;; —— build-chandler-runtime! 编的),优先于全局前缀,避免实例分歧(BUG-1)。
                  (cons sd (append (all-dep-prebuilt-roots root)
                                   (gate-prebuilt-roots root)
                                   (fallback-roots root)))
                  (lambda ()
                    ;; 你自己 manifest 里的 native 是**可信**的(designs/08 §3
                    ;; 「你 manifest 里 path native 的构建」),不需要 --allow-build。
                    (derive-native-tasks! name (native-items (project-native-spec root)))
                    (if app
                        ;; app:入口库(可能与 manifest name 不同名 —— skiff-demo 的
                        ;; 清单叫 "skiff-demo",入口却是 (mdserver))决定要编什么。
                        ;; library-task 从入口走 build-graph:编入口闭包,依赖(预构建
                        ;; 根)不下降。这正是旧 recipe 的 (library-task 'build entry)。
                        (library-task 'build (app-entry app))
                        ;; lib:没有单一入口,按约定编 <name>.ss + <name>/ 全部库。
                        (derive-library-tasks! (project-library-entries root name sd))))
                  all-file-targets
                  verbose? (format "project ~a" name))))))))

  ;; 项目自己的库文件,路径相对**项目根**(build-tree! 把 cwd 切到根)。
  (define (project-library-entries root name sd)
    (let ([rels (tree-library-files (srcdir-join root sd) name)])
      (if (string=? sd ".") rels (map (lambda (r) (join-paths sd r)) rels))))

  (define (project-native-spec root)
    (let ([mpath (join-paths root "chandler-manifest.ss")])
      (if (file-exists? mpath)
          (let ([datum (read-datum-file mpath)])
            (or (assq 'native (cdr datum)) '(native)))
          '(native))))

  ;; ── 一棵库树里的全部库文件(相对该树根的路径,给 library-task 当 entry)──
  ;; 只收**真的是库**的文件:首个 datum 为 (library …)。包里也会有测试程序、脚本,
  ;; 那些交给 bake 会走 compile-program,既无意义也可能失败。
  (define (tree-library-files srcdir name)
    (let* ([pre    (string-append srcdir "/")]
           [umb    (find-umbrella srcdir name)]
           [subs   (let ([d (join-paths srcdir name)])
                     (if (file-directory? d)
                         (filter library-source? (files-under d))
                         '()))])
      (map (lambda (abs) (strip-prefix abs pre))
           (list-sort string<? (append (if umb (list umb) '()) subs)))))

  (define (find-umbrella srcdir name)
    (let loop ([exts '(".chezscheme.sls" ".sls" ".ss" ".sc")])
      (cond
        [(null? exts) #f]
        [(file-exists? (join-paths srcdir (string-append name (car exts))))
         (join-paths srcdir (string-append name (car exts)))]
        [else (loop (cdr exts))])))

  (define (library-source? path)
    (and (or (string-suffix? ".ss" path) (string-suffix? ".sls" path)
             (string-suffix? ".sc" path))
         ;; ignore-errors = (guard (e [#t #f]) body ...) —— body 的**最后一个**
         ;; 表达式是它的值,所以这里不能再跟一个 #f 兜底,那会让它恒假。
         (ignore-errors
           (let ([d (call-with-input-file path read)])
             (and (pair? d) (eq? 'library (car d)))))))

  ;; 路径 → 合法且唯一的任务名片段:非字母数字一律 "-"
  (define (task-suffix rel)
    (list->string
      (map (lambda (c) (if (or (char-alphabetic? c) (char-numeric? c)) c #\-))
           (string->list rel))))

  ;; ── native 项解析(manifest native 字段:(native (<soname> (path …) (build <后端>) …) …))──
  (define (native-items spec)                ; spec = (native item…) 或 (native)
    (if (and (pair? spec) (eq? (car spec) 'native)) (cdr spec) '()))
  (define (native-item-soname item) (car item))
  (define (native-item-path item)
    (let ([c (assq 'path (cdr item))])
      (if c (cadr c) (string-append "native/" (symbol->string (native-item-soname item))))))
  (define (native-item-backend item)
    (let ([c (assq 'build (cdr item))]) (if c (cadr c) 'make)))

  ;; ── native 构建描述:读依赖 lib/<name>/chandler-manifest.ss 的 native 项 ──
  (define (dep-native-spec root name)
    (let ([mpath (join-paths (vendor-dir root (string->symbol name)) "chandler-manifest.ss")])
      (if (file-exists? mpath)
          (let ([mf (read-manifest mpath)])
            ;; 用原始 native sexpr(而非 record)哈希更稳:重读 datum 取 native 字段
            (let ([datum (read-datum-file mpath)])
              (or (assq 'native (cdr datum)) '(native))))
          '(native))))

  ;; ── 授权文件:((name . hash) …)──
  (define (read-approvals path)
    (if (file-exists? path)
        (let ([datum (read-datum-file path)])
          (if (and (pair? datum) (eq? (car datum) 'approvals))
              (map (lambda (e) (cons (car e) (cadr e))) (cdr datum))
              '()))
        '()))

  (define (write-approvals path approvals)
    (write-canonical-file path
      `(approvals ,@(map (lambda (p) (list (car p) (cdr p)))
                         (list-sort (lambda (a b) (string<? (car a) (car b))) approvals)))))

  (define (approval-hash spec) (sha256-string (canonical-inline spec)))

  (define (approved? approvals name h)
    (let ([p (assoc name approvals)]) (and p (string=? (cdr p) h))))

  (define (merge-approvals old new)
    (append new (filter (lambda (p) (not (assoc (car p) new))) old)))

  ;; ── 授权判定 ──
  (define (allowed? allow name)
    (cond
      [(eq? allow #t) #t]
      [(string? allow) (and (member name (string-split allow #\,)) #t)]
      [else #f]))

  ;; ── 工具 ──
  (define (canonical-inline datum)
    ;; 单行 canonical 串(授权哈希用);复用 write 到 string
    (let ([op (open-output-string)]) (write datum op) (get-output-string op))))
