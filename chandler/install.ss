#!chezscheme
;;; chandler/install.ss --- 依赖物化 → _vendor/(每依赖 live,逐依赖挂载)
;;;
;;; **C0(2026-07-24):不再有汇总的 lib/**。每个依赖留在 _vendor/<name>/ 自己的
;;;   src/ 与 _build/<mt>/;resolved-libdirs 逐依赖挂一条 (src . obj) 对,挂上即生效。
;;;   资源同理 live 在 _vendor/<dep>/<srcdir>/resources/<libpath>/。
;;;
;;;   git 依赖整仓 checkout → _vendor/<name>/;chandler 运行时门从 CHANDLER_HOME copy
;;;   进 _vendor/chandler/。path 依赖不进 _vendor,activate/run 时直挂其源目录(live)。
;;;   启动统一走 `chandler run`(早期的 `chandler-setup.ss` Bundler 模型已取消)。

(library (chandler install)
  (export install verify list-deps
           vendor-dir project-lock-path project-manifest-path
           native-load-paths
           chandler-runtime-sublibs
           global-prefix global-libdir
           project-mode? resolved-libdirs
           install-project-payload! project-locked-deps)
  (import (chezscheme)
          (chandler util)
          (chandler fs)
          (chandler proc)
          (chandler layout)
          (chandler sexp)
          (chandler manifest)
          (chandler lock)
          (chandler resolve)
          (chandler version)
          (chandler registry)
          (chandler fetch))

  (define (project-manifest-path root) (join-paths root "chandler-manifest.ss"))
  (define (project-lock-path root) (join-paths root "chandler-manifest.lock"))
  (define (vendor-dir root name) (join-paths (join-paths root "_vendor") (symbol->string name)))

  ;; ── install:主命令 ──
  ;; opts: (production . bool) (force . bool) (keep-extra . bool) (offline . bool)
  ;;         (update . bool)   — 强制重解析(忽略旧 lock)
  (define (install root opts)
    (let* ([mpath (project-manifest-path root)]
           [lpath (project-lock-path root)])
      (unless (file-exists? mpath)
        (error 'deps "chandler-manifest.ss not found; run `chandler init` first" root))
      ;; --update:删旧 lock 触发重解析
      (when (opt opts 'update #f)
        (when (file-exists? lpath) (delete-file lpath)))
      (parameterize ([offline? (opt opts 'offline #f)])
        (let* ([mf (read-manifest mpath)]
               [lk (obtain-lock root mf mpath lpath opts)]
               ;; 所有需要 vendor 的依赖(git + path);path dep 从本地拷入 vendor/
               [deps-to-vendor (filter (lambda (d)
                                         (and (memq (locked-dep-source-kind d) '(git path))
                                              (or (not (opt opts 'production #f))
                                                  (not (eq? 'dev (locked-dep-scope d))))))
                                       (lock-deps lk))])
          ;; 1) 依赖 → vendor/<name>(git: clone;path: 本地拷贝)
          (for-each (lambda (d) (sync-dep root d opts)) deps-to-vendor)
          ;; chandler 是**运行时门**不是依赖:实体取自全局前缀,进 vendor/chandler
          (when (manifest-chandler mf) (install-chandler-runtime! root (manifest-chandler mf)))
          (clean-orphans root lk (if (manifest-chandler mf) '("chandler") '()) opts)
          ;; **对象不再由 deps 拷**(BUG-1,2026-07-24):原先从全局前缀拷已编译的 .so,
          ;; 但前缀里那份实例未必与 build 期 app 链到的实例一致 —— Chez 每次编译盖
          ;; 新实例印章,pack 出来的包一加载就报 "different compilation instance"。
          ;; 改为:deps 只铺源码(上面的 install-chandler-runtime!),对象的编译由
          ;; build 层负责(`build-chandler-runtime!`),就地从 vendored 源码编一次,
          ;; build 与 pack 同源 → 实例一致。cli 层(cmd-deps)在 install 后触发编译。
          ;; **不再往 lib/ 拷任何东西**(C0):依赖的源码、对象、资源各自 live 在
          ;; _vendor/<dep>/ 里,由 resolved-libdirs 逐依赖挂成 (src . obj) 对。
          (printf "deps: ~a ~a vendored to _vendor/~%"
                  (length deps-to-vendor) (plural (length deps-to-vendor) "dependency" "dependencies"))
          0))))

  ;; 取 lock:新鲜则用旧;否则解析 + 写(填 manifest-sha256)
  (define (obtain-lock root mf mpath lpath opts)
    (if (and (file-exists? lpath)
             (let ([old (read-lock lpath)]) (and (lock-fresh? old mpath) old)))
        (read-lock lpath)
        (let* ([res (resolve mf (list (cons 'root-dir root)
                                      (cons 'production (opt opts 'production #f))))]
               [lk0 (resolution-lock res)]
               [lk  (with-manifest-sha lk0 (manifest-content-sha256 mpath))])
          (for-each (lambda (w) (fprintf (current-error-port) "warning: ~a~%" w))
                    (resolution-warnings res))
          (write-lock lpath lk)
          lk)))

  (define (with-manifest-sha lk sha)
    (make-lock (lock-format lk) sha (lock-chandler lk) (lock-deps lk)))

  ;; ── 单依赖 → vendor/<name>(git: clone;path: 本地拷贝)──
  (define (sync-dep root ld opts)
    (let ([dir (vendor-dir root (locked-dep-name ld))])
      (case (locked-dep-source-kind ld)
        [(git) (sync-git-dep root ld dir opts)]
        [(path) (sync-path-dep root ld dir opts)]
        [else (void)])))

  (define (sync-git-dep root ld dir opts)
    (let ([url (locked-dep-source-loc ld)]
          [rev (locked-dep-rev ld)])
      (cond
        [(not (file-directory? dir)) (materialize url rev dir)]
        [(dirty? dir)
         (if (opt opts 'force #f)
             (begin (rm-rf dir) (materialize url rev dir))
             (error 'deps
                    (format "~a has local changes; refusing to overwrite (use --force)~%  ~a"
                            (locked-dep-name ld) dir)))]
        [(string=? (head-rev dir) rev) (void)]
        [else
         (unless (has-rev? url rev) (update-mirror url))
          (checkout-detach dir rev)])))

  ;; path 依赖:从本地源目录拷贝到 vendor/<name>/(chandler 自举用)
  (define (sync-path-dep root ld dir opts)
    (let ([src (locked-dep-source-loc ld)])
      (unless (file-directory? src)
        (error 'deps (format "~a: source path ~a does not exist" (locked-dep-name ld) src)))
      (when (or (not (file-directory? dir))
                (opt opts 'force #f))
        (rm-rf dir)
        (ensure-dir dir)
        (for-each
          (lambda (abs)
            (let* ([pre (string-append src "/")]
                   [rel (strip-prefix abs pre)]
                   [dst (join-paths dir rel)])
              (ensure-parent dst)
              (copy-file abs dst)))
          (files-under src)))))

  ;; 依赖声明的资源**不再复制**(C0):它们 live 在
  ;;   _vendor/<dep>/<srcdir>/resources/<libpath>/
  ;; 而 resolved-libdirs 把那个 src 侧挂上了,(chandler runtime-paths) 的
  ;; resource-path 扫 src 侧即命中 —— 改依赖的资源即时生效,不必重跑 deps。
  ;; **约定**:依赖仓库把资源摆在 `<srcdir>/resources/<libpath>/`(与安装前缀里
  ;; `<prefix>/src/resources/<libpath>/` 同一形状)。manifest 的 `(resources …)`
  ;; 声明退化为**交付期映射** —— install/pack 据它把任意路径搬到规范落点。

  ;; ══════════════════════════════════════════════════════════════════
  ;; chandler 自身:**运行时门,不是依赖**(designs/12 §5)
  ;;   manifest 写 (chandler ">=0.1.4") —— 只有版本区间,没有 URL:实体是全局前缀
  ;;   ~/.local/share/chez 里装好的那一份(bootstrap.ss 装的 {src,<mt>})。deps 阶段
  ;;   把它的 **runtime 子集**复制进 vendor/chandler/ 与 lib/{src,<mt>},于是下游
  ;;   一律照常走既有路径:bake 的 (prebuilt "lib") 能解析、`chandler build` 不必
  ;;   特判、`chandler run` 挂的还是那一对。
  ;;
  ;;   只复制 runtime 子集:dev-time 的那半边(cli/build/pack/install/…)是**工具**,
  ;;   不该出现在应用的库搜索路径里,更不该进包(designs/12 §6.3)。
  ;; ══════════════════════════════════════════════════════════════════

  ;; runtime 子集 = (chandler base) umbrella 及其覆盖的 9 个库(与 chandler 自身
  ;; manifest 的 (runtime-subset …) 一致)。pack 复用同一份定义,免得两处漂移。
  (define chandler-runtime-sublibs
    '(base runtime-paths hash version util fs sexp layout runtime-detector proc))

  ;; rel 形如 "chandler/pack.so" / "chandler/hash.ss" → 是不是 dev-only?
  ;; 判据与扩展名无关:嵌套(chandler/cli/main.*)一律 dev,顶层看是否在子集里。
  ;; 注:strip-prefix 是 (strip-prefix s pre) —— 参数写反会让 sub 恒为 "chandler/",
  ;; 于是**每个** chandler 库都被判成 dev-only(pack 的 N6 过滤器原先正是这个 bug,
  ;; 被「应用自己的 _build 里也编了一份」掩盖着)。
  (define (chandler-dev-only-rel? rel)
    (and (string-prefix? "chandler/" rel)
         (let* ([sub (strip-prefix rel "chandler/")]
                [dot (char-index sub #\.)]
                [stem (if dot (substring sub 0 dot) sub)])
           (or (string-contains? stem "/")
               (not (memq (string->symbol stem) chandler-runtime-sublibs))))))

  ;; 运行时门(2026-07-24 改为自引用):deps copy 的就是**正在跑的这个 chandler**,
  ;; 故版本 = 进程内常量 `chandler-version`(不再读前缀里的 .chandler/chandler/chandler-manifest.ss
  ;; 快照),校验是纯进程内一句;而它的代码在 `CHANDLER_HOME`(= chandler-home)。
  (define (install-chandler-runtime! root range)
    (unless (version-match? range chandler-version)
      (error 'deps
             (format "manifest requires chandler ~s, but the running chandler is ~a~%  (upgrade chandler, or relax the range in chandler-manifest.ss)"
                     range chandler-version)))
    ;; <home>/src/chandler/<sub>.ss → _vendor/chandler/chandler/<sub>.ss
    ;; _vendor/ 是「依赖源码原样」那一层,chandler 也照此摆,故 verify/清理/阅读
    ;; 三处都不必为它开特例。umbrella chandler.ss 不来:那是 dev facade
    ;; (export activate…),应用要的是 (chandler base) 与各 runtime 子库。
    (let* ([home (chandler-home)]
           [src  (join-paths home "src" "chandler")]
           [dst  (join-paths (vendor-dir root (quote chandler)) "chandler")])
      (unless (file-directory? src)
        (error 'deps
               (format "cannot locate chandler's own libraries at ~a~%  (set CHANDLER_HOME, or reinstall chandler with bootstrap.ss)"
                       home)))
      (rm-rf (vendor-dir root (quote chandler)))
      (copy-runtime-subset! src dst ".ss")))

  ;; **对象编译移交 build 层**(BUG-1,2026-07-24):原先这里有个 copy-chandler-runtime!
  ;; 从全局前缀拷已编译 .so 进 _vendor/chandler/_build/<mt>/。但前缀里的实例与 build
  ;; 期 app 链到的实例可能不同(Chez 每次编译盖新印章),pack 出来的包一加载就报
  ;; "different compilation instance"。改为由 `(chandler build)` 的 build-chandler-runtime!
  ;; 就地编译 vendored 源码,build/pack 同源。本模块不再负责 chandler 对象。

  ;; 平铺复制 <from>/<sub><ext> —— 只取 runtime 子集,子目录(cli/test)整个不看
  (define (copy-runtime-subset! from to ext)
    (when (file-directory? from)
      (for-each
        (lambda (e)
          (let ([p (join-paths from e)])
            (when (and (not (file-directory? p))
                       (string-suffix? ext e)
                       (not (chandler-dev-only-rel? (string-append "chandler/" e))))
              (let ([dst (join-paths to e)])
                (ensure-parent dst)
                (copy-file p dst)))))
        (dir-entries from))))

  ;; ── 通用树拷贝原语(消除 merge-tree!/copy-obj-tree! 重复)──
  ;; 本模块私有(不导出):pack 走 install-project-payload! 这条更高层的入口,
  ;; 并不直接用它 —— 「P7:install/pack 共享」那句注释早已过时。
  ;; 把 src 下所有文件拷到 dst。语义差异由参数表达(而非两个函数):
  ;;   skip-dirs   路径首段在其中的整棵跳过(如 ("_build" ".git"))
  ;;   file-filter 谓词 (rel → bool),只拷满足的文件;全拷传 (lambda (_) #t)
;;   policy      'skip-existing — dst 已存在则跳(累积前缀,如 install --user)
;;               'overwrite      — 总是拷(隔离目标,如 pack 的 rm-rf 后目录)
  ;;   warn?       skip-existing 命中时往 stderr 警告(抓依赖间同名悄悄丢的 latent bug)
  ;;
  ;; **为什么不硬编码 policy**:全局前缀是跨安装的**累积存储**(不是 R6RS 单程序),
  ;; 别包拥有的文件不许静默覆盖(registry check-conflicts 兜硬错;这里补的 warn 抓
  ;; merge-tree! 原先静默 skip 的 latent bug)。pack 写进 rm-rf 过的隔离目录,无累积
  ;; 污染可能,overwrite 安全。安全来自目标隔离,不来自 R6RS 单命名空间。
  (define (copy-tree! src dst skip-dirs file-filter policy warn?)
    (when (file-directory? src)
      (ensure-dir dst)
      (let ([pre (string-append src "/")])
        (for-each
          (lambda (abs)
            (let* ([rel (strip-prefix abs pre)]
                   [head (let ([i (char-index rel #\/)]) (if i (substring rel 0 i) rel))])
              (unless (member head skip-dirs)
                (when (file-filter rel)
                  (let ([d (join-paths dst rel)])
                    (cond
                      [(and (eq? policy 'skip-existing) (file-exists? d))
                       (when warn?
                         (fprintf (current-error-port)
                                  "warning: skip existing file (name collision): ~a~%" d))]
                      [else (ensure-parent d) (copy-file abs d)]))))))
          (files-under src)))))

  ;; ── 孤儿清理:vendor/ 下有、lock 无的目录(extra-keep:非 lock 来源的合法住户)──
  (define (clean-orphans root lk extra-keep opts)
    (let ([vd (join-paths root "_vendor")])
      (when (file-directory? vd)
        (let ([keep (append extra-keep
                            (map (lambda (d) (symbol->string (locked-dep-name d))) (lock-deps lk)))])
          (for-each
            (lambda (entry)
              (let ([full (join-paths vd entry)])
                (when (and (file-directory? full) (not (member entry keep)) (not (dot-entry? entry)))
                  (if (opt opts 'keep-extra #f)
                      (fprintf (current-error-port) "note: keeping extra directory vendor/~a~%" entry)
                      (begin (fprintf (current-error-port) "removing orphaned dependency vendor/~a~%" entry)
                             (rm-rf full))))))
            (dir-entries vd))))))

  ;; ── verify:vendor/ 对 lock 一致性(rev 匹配 + 无脏)+ lib/ 存在 ──
  (define (verify root)
    (let ([lpath (project-lock-path root)])
      (unless (file-exists? lpath)
        (error 'verify "no chandler-manifest.lock; run `chandler deps` first" root))
      (let ([lk (read-lock lpath)] [ok #t])
        (for-each
          (lambda (d)
            (when (eq? 'git (locked-dep-source-kind d))
              (let ([dir (vendor-dir root (locked-dep-name d))])
                (cond
                  [(not (file-directory? dir))
                   (set! ok #f)
                   (fprintf (current-error-port) "missing: vendor/~a (run `chandler deps`)~%" (locked-dep-name d))]
                  [(not (string=? (head-rev dir) (locked-dep-rev d)))
                   (set! ok #f)
                   (fprintf (current-error-port) "rev mismatch: vendor/~a is at ~a, lock says ~a~%"
                            (locked-dep-name d) (head-rev dir) (locked-dep-rev d))]
                  [(dirty? dir)
                   (set! ok #f)
                   (fprintf (current-error-port) "dirty: vendor/~a has local changes~%" (locked-dep-name d))]))))
          (lock-deps lk))
        ;; C0 之后没有 lib/ 可查:每个 git 依赖的 _vendor 树在不在,上面逐条已经查过
        ;; (rev / dirty),这里只补「一条都没 vendor 过」的情形。
        ok)))

  ;; sync-status:list/tree 用
  (define (sync-status root)
    (let ([lpath (project-lock-path root)])
      (if (file-exists? lpath)
          (map (lambda (d)
                 (list (locked-dep-name d) (short-rev (locked-dep-rev d))
                       (locked-dep-source-loc d) (locked-dep-scope d)))
               (lock-deps (read-lock lpath)))
          '())))

  (define (list-deps root) (sync-status root))

;; ── 库搜索路径(每依赖 _vendor/<dep>/{src,_build/<mt>} 对 + path 依赖源目录)──
;; 正在跑的 chandler 的库前缀 = CHANDLER_HOME(见 (chandler registry) chandler-home)。
;; 读侧用它:deps 从这里 copy chandler runtime 进 _vendor、run/build 的全局兜底挂它。
;; (2026-07-24:原 global-prefix 读 CHANDLER_PREFIX,已统一到 CHANDLER_HOME;
;;  "安装落点"是另一回事,走 --user/--system,见 registry。)
  (define (global-prefix) (chandler-home))
  ;; 全局库目录条目:v3 扫中心 .registry/,把每个已装 (name, version) 展开成
  ;; (src . obj) 对。返回 list of pairs(可能为空)。
  ;; list-registered 一次读盘 + 一次解析就给出 registered 记录 —— 先前是
  ;; list-registered-names 解析一遍、再逐 name read-registered 解析第二遍,而本函数
  ;; 在每次 `chandler run` / `build` / `repl` 启动时都要跑(resolved-libdirs 的兜底段)。
  (define (global-libdir)
    (let ([home (chandler-home)])
      (if (not (file-directory? home))
          '()
          (let ([mt (current-machine-type)])
            (fold-left
              (lambda (acc p)
                (let ([name-sym (car p)])
                  (fold-left
                    (lambda (acc v)
                      (let* ([vroot (version-root home name-sym (car v))]
                             [src (join-paths vroot "src")])
                        (if (file-directory? src)
                            (cons (cons src (join-paths vroot mt)) acc)
                            acc)))
                    acc (registered-versions (cdr p)))))
              '() (list-registered home))))))

  ;; path 依赖的源目录(相对 root 拼成路径),供 live 挂载
  (define (path-dep-source-dirs root)
    (let ([mpath (project-manifest-path root)])
      (if (file-exists? mpath)
          (let ([mf (read-manifest mpath)])
            (map (lambda (d) (join-paths root (dep-source-loc d)))
                 (filter (lambda (d) (eq? 'path (dep-source-kind d)))
                         (append (manifest-deps mf) (manifest-dev-deps mf)))))
          '())))

  ;; run/exec/activate 用:lib/ 对 (src . obj)(若 lib/ 在)+ path 依赖源目录
  ;; ── per-dep (源 . 对象) 对(C0,2026-07-24)──
  ;;
  ;; 一个依赖挂一条:源在 _vendor/<name>/<srcdir>,对象在它自己的 _build/<mt>/
  ;; (`chandler build` 就是在那棵树里、以 srcdir 为 cwd 编的)。
  ;;
  ;; **为什么不再有 lib/**:先前要一个「项目本地安装前缀」,是因为消费方只能挂一个
  ;; 目录对,于是必须把各依赖的源码与对象摊平进去。既然 library-directories 本来就
  ;; 收一**列**条目,直接逐依赖挂它自己的树即可 —— 少一次全量拷贝、少一处会与
  ;; _vendor 漂移的副本,改依赖源码即时生效(dev 期全 live)。
  ;; 资源同理:各依赖的 <srcdir>/resources/<libpath>/ 被 resource-path 的 src 侧
  ;; 扫描直接读到,不必先拷进某个前缀。
  (define (dep-src-dir root d)
    (vendor-dir root (locked-dep-name d)))

  (define (dep-pair root d)
    (let ([src (dep-src-dir root d)])
      (cons src (join-paths src "_build" (current-machine-type)))))

  ;; 项目自身:源在 <root>/<srcdir>,对象在 <root>/_build/<mt>
  (define (project-pair root)
    (cons (srcdir-join root (proj-srcdir root))
          (join-paths root "_build" (current-machine-type))))

  (define (locked-deps-of root)
    (let ([lpath (project-lock-path root)])
      (if (file-exists? lpath) (lock-deps (read-lock lpath)) '())))

  (define (library-search-dirs root)
    (append
      (map (lambda (d) (dep-pair root d))
           (filter (lambda (d) (file-directory? (dep-src-dir root d))) (locked-deps-of root)))
      (path-dep-source-dirs root)))

  ;; ── 统一库搜索规则(run / exec / repl / activate 共用)──
  ;;   项目模式(lock 存在且有依赖):lib/ + path 源目录 + 项目自身库根 + 全局兜底(项目最高优先)
  ;;   非项目:直接全局
  ;; 项目模式:有 lock 就算(C0 之后不再看 lib/ 在不在 —— 它已经不存在了)
  (define (project-mode? root)
    (file-exists? (project-lock-path root)))

  (define (resolved-libdirs root)
    (if (project-mode? root)
        (append (library-search-dirs root)
                (list (project-pair root))
                (global-libdir))
        (global-libdir)))

  (define (proj-srcdir root)
    (let ([mp (project-manifest-path root)])
      (if (file-exists? mp) (manifest-srcdir (read-manifest mp)) ".")))

;; ── native 兜底加载清单(自加载优先、统一加载兜底)──
;;   bake 现为每个带 native 的库生成 `(<lib> native-loader)`,其编译产物
;;   _build/<mt>/<lib>/native-loader.so 随交付树落位;该库 FFI 被引用时,loader 自己
;;   按候选序定位并 load —— 候选 2 正是 (library-directories) 各根的 obj 侧,
;;   而 resolved-libdirs 挂的各 per-dep (src . obj) 对,obj 侧恰是 native 落点,
;;   故**天然命中**。
;;   ⇒ 有 loader 的库**无需预加载**(且自加载是惰性的:不碰 FFI 就不 dlopen);
;;      这里只为「无生成 loader」的第三方库保留统一加载兜底。
  ;;   **2026-07-24(C2)**:扫的范围从「只有项目自己的 lib/<mt>」推广到
  ;;   **所有挂载条目的 obj 侧** —— 与资源定位(C1)同一条原则:进程对着哪些前缀跑,
  ;;   `(library-directories)` / `resolved-libdirs` 就是权威答案,兜底不该只认其中一个。
  ;;   原先全局前缀里手放的、无 loader 的第三方 native 一律漏掉。
  ;;   代价是每次起进程多走几棵 obj 树;但 self-loading? 会滤掉带 loader 的库,而
  ;;   chandler/bake 装的东西**都**带 loader,故实际命中极少、纯属兜底。
  ;;   项目自己的 obj 目录**无条件**在扫描集里:resolved-libdirs 在非 project-mode
  ;;   (没有 lock)时只返回全局前缀,而一个刚 build 完、还没 deps 过的树照样可能有
  ;;   lib/<mt>/…/native/。取并集,严格是旧行为的超集,不会漏。
  (define (native-load-paths root)
    (let loop ([dirs (dedupe-strings
                       (cons (cdr (project-pair root))
                             (map entry-obj-side (resolved-libdirs root))))]
               [acc '()])
      (if (null? dirs)
          (reverse acc)
          (loop (cdr dirs) (append (reverse (native-sos-under (car dirs))) acc)))))

  ;; 库目录条目 → obj 侧(pair 取 cdr;字符串条目源=对象)
  (define (entry-obj-side e) (if (pair? e) (cdr e) e))

  (define (dedupe-strings xs)
    (let loop ([xs xs] [seen '()] [out '()])
      (cond
        [(null? xs) (reverse out)]
        [(member (car xs) seen) (loop (cdr xs) seen out)]
        [else (loop (cdr xs) (cons (car xs) seen) (cons (car xs) out))])))

  ;; 扫 obj 树找 native 动态库:落点不变量是 <lib>/native/<soname>.<ext>
  ;; (与该库的编译 Scheme .so 区分:后者不在 native/ 子目录里);自加载的库滤掉。
  ;;
  ;; **只递归目录,遇到 native/ 才列文件**。先前是 (files-under obj-dir) 把整棵树的
  ;; 文件路径全物化成一张表,再逐条按父目录名过滤 —— 一个装了几十个包的全局前缀里
  ;; 那是上万条 .so 路径 + 上万次 base-name/parent-dir 字符串切分,而命中的通常是零条。
  ;; 本函数在每次 `chandler run` / `test` / `repl` 启动时对**每个**挂载前缀跑一遍,
  ;; 属于纯启动开销,值得按形状剪枝。
  ;;
  ;; self-loading 的判定也随之从「每个 .so 一次 file-exists?」降到「每个 native/ 一次」
  ;; —— native-loader.so 与 native/ 同级,而我们此刻手里正好有那个 <lib> 目录。
  ;;
  ;; 另一半开销是**每个目录项一次 file-directory?**(即一次 stat)。实测一棵 4200 个
  ;; .so 的对象树,8.9ms 里有 6.1ms 是这些 stat —— 而其中绝大多数是在问「这个 .so 是
  ;; 目录吗」。对象树是 chandler 自己生成的格式(designs/06),编译产物的扩展名是封闭
  ;; 集合,故按扩展名先筛掉一定不是目录的项,只对余下的 stat。这个假设**只在这里**成立,
  ;; 不能下沉到 (chandler fs) 的通用 files-under —— 那个要走用户的任意源码树。
  (define obj-tree-file-exts '(".so" ".wpo" ".boot"))

  (define (obj-tree-file-name? e)
    (exists (lambda (ext) (string-suffix? ext e)) obj-tree-file-exts))

  (define (native-sos-under obj-dir)
    (reverse
      (let walk ([d obj-dir] [acc '()])
        (fold-left
          (lambda (acc e)
            (cond
              [(obj-tree-file-name? e) acc]                ; 编译产物,不可能是目录:免 stat
              [(not (file-directory? (join-paths d e))) acc]
              [(not (string=? e "native")) (walk (join-paths d e) acc)]
              [(self-loading-lib? d) acc]                  ; 有生成 loader → 惰性自加载,不预载
              [else
               (let ([nd (join-paths d e)])
                 (fold-left
                   (lambda (acc f)
                     ;; native/ 下就是 .so/.dylib/.dll 本体,同样按名字判、不 stat
                     (if (native-so? f) (cons (join-paths nd f) acc) acc))
                   acc (dir-entries nd)))]))
          acc (dir-entries d)))))

  ;; 该库是否自带生成 loader:<lib>/native-loader.so 与 <lib>/native/ 同级
  (define (self-loading-lib? lib-dir)
    (file-exists? (join-paths lib-dir "native-loader.so")))

  ;; ── 项目自身的资源:**不再铺进任何前缀**(C0)──
  ;;   项目的源码根本来就被 resolved-libdirs 挂着,故 <root>/resources/<name>/
  ;;   被 resource-path 的 src 侧扫描直接读到 —— 改一个资源文件即时生效,
  ;;   不必重跑 deps,也不需要 APP_ROOT。
  ;;   (先前要拷进 lib/ 是因为「APP_ROOT 指向唯一前缀」那套模型;C1 把资源定位
  ;;    改成扫 library-directories 之后,那个理由消失了。)

  ;; ── 工具 ──
  (define (opt opts k default) (alist-ref opts k default))
  (define (dot-entry? e) (and (> (string-length e) 0) (char=? #\. (string-ref e 0))))

  ;; ═══════════════════════════════════════════════════════════════════
  ;; 安装载荷(cmd-install 步骤 1-4,不含 app launcher)
  ;;   供两处复用,保证 install 与 pack 的载荷字节级一致(I2 by construction):
  ;;     cmd-install  register?=#t → install-global(staging + .registry/)
  ;;     pack 阶段1   register?=#f → install-payload-global(直拷,无注册表)
  ;; ═══════════════════════════════════════════════════════════════════

  (define (project-locked-deps root)
    (let ([lpath (project-lock-path root)])
      (if (file-exists? lpath) (lock-deps (read-lock lpath)) '())))

  ;; 把各依赖装进全局前缀(合并,不覆盖同名)。C0:来源是**每个依赖自己的树**。
  (define (merge-lib-to-global! root libdir)
    (let ([mt (current-machine-type)]
          [all (lambda (_) #t)])
      (for-each
        (lambda (d)
          (let* ([name (symbol->string (locked-dep-name d))]
                 [version (locked-dep-pin-val d)]
                 [src-root (vendor-dir root (locked-dep-name d))]
                 [vroot (version-root libdir (locked-dep-name d) version)]
                 [src-dest (join-paths vroot "src")]
                 [obj-dest (join-paths vroot mt)]
                 [obj (join-paths src-root "_build" mt)])
            ;; P7:共享 copy-tree!。累积前缀 → skip-existing + warn。
            (copy-tree! src-root src-dest '("_build" ".git") all 'skip-existing #t)
            (copy-tree! obj obj-dest '() all 'skip-existing #t)))
        (project-locked-deps root))))

  ;; ISO-ish 时间戳(installed-at,纯记录)
  (define (now-iso)
    (let ([t (current-date)])
      (format "~a-~a-~aT~a:~a:~a"
              (date-year t) (pad2 (date-month t)) (pad2 (date-day t))
              (pad2 (date-hour t)) (pad2 (date-minute t)) (pad2 (date-second t)))))
  (define (pad2 n) (if (< n 10) (format "0~a" n) (format "~a" n)))

  ;; install-project-payload!:app 自身 + 依赖合并 + manifest/lock 快照。
  ;; opts:(register? . #t/#f) (adopt . b) (force . b)。
  ;; 调用方负责前置检查(manifest/lock 存在)与 app launcher 生成(如有)。
  (define (install-project-payload! root libdir name version entry opts)
    ;; 1. 项目自身
    (if (alist-ref opts 'register?)
        (install-global root libdir
                        (list name version `(path ,root) (now-iso) 'chandler)
                        version
                        (list (cons 'adopt (alist-ref opts 'adopt))
                              (cons 'force (alist-ref opts 'force)))
                        entry)
        (install-payload-global root libdir name version entry))
    ;; 2. 合并依赖源码 + 编译产物(从 _vendor → 前缀)
    (merge-lib-to-global! root libdir)
    ;; 3. manifest + lock 快照 → <vroot>/.chandler/
    ;;    lock 必须同去:run.sps(D18)启动时读它挂精确 dep 版本,缺即崩。
    ;;    无清单场景(pack --name/--entry 临时打包)由调用方自行合成。
    (let ([manifest-dir (join-paths (version-root libdir name version) ".chandler")]
          [mpath (project-manifest-path root)]
          [lpath (project-lock-path root)])
      (ensure-dir manifest-dir)
      (when (file-exists? mpath)
        (copy-file mpath (join-paths manifest-dir "chandler-manifest.ss")))
      (when (file-exists? lpath)
        (copy-file lpath (join-paths manifest-dir "chandler-manifest.lock"))))))
