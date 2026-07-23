#!chezscheme
;;; chandler/install.ss --- vendor/ 物化 + 源码安装 → 项目前缀 lib/(designs/01)
;;;
;;; 依赖模型(Bundler 式,2026-07-22 对齐 bake install 的 src/mt 拆分):
;;;   git 依赖整仓 checkout → vendor/<name>/;chandler 再把源码装进 lib/,
;;;   lib/ 成为一个 Chez 库目录**前缀**,与 ~/.local/share/chez 及解开的 pack 逐层同构:
;;;     lib/src/                        ← 源码(umbrella <name>.ss + <name>/… 各依赖并存)
;;;     lib/<mt>/                       ← 平台绑定产物(编译 .so + native/<lib>/…),
;;;                                        `chandler build` 后填充
;;;     lib/share/<libpath>/resources/  ← 资源(依赖声明的 + 本项目自己的 resources/)
;;;     lib/.chandler/<name>/manifest.ss ← 清单快照(应用名由此可辨,见 runtime-paths)
;;;   故库搜索挂**一对** (lib/src . lib/<mt>);消费方一条 pair 同时解析源码与对象。
;;;   path 依赖不进 vendor/lib,activate/run 时直挂其源目录(live)。
;;;
;;;   **APP_ROOT 即这个前缀**(2026-07-23):`chandler run`/`repl`/`activate` 把它指向
;;;   <project>/lib,pack 启动器指向包根 —— 三态同一形状,应用代码与 bake 生成的
;;;   native-loader 都只认 `$APP_ROOT/<mt>/…` 与 `$APP_ROOT/share/<app>/resources/`
;;;   一种拼法。生成 chandler-setup.ss 的旧做法已取消:启动统一走 `chandler run`。

(library (chandler install)
  (export install verify sync-status list-deps
          vendor-dir lib-dir project-lock-path project-manifest-path
          library-search-dirs native-load-paths sync-app-prefix!
          project-libdir project-lib-pair project-obj-dir
          global-prefix global-libdir path-dep-source-dirs
          project-mode? resolved-libdirs)
  (import (chezscheme)
          (chandler util)
          (chandler fs)
          (chandler proc)
          (chandler layout)
          (chandler sexp)
          (chandler manifest)
          (chandler lock)
          (chandler resolve)
          (chandler fetch))

  (define (project-manifest-path root) (join-paths root "manifest.ss"))
  (define (project-lock-path root) (join-paths root "manifest.lock"))
  (define (vendor-dir root name) (join-paths (join-paths root "vendor") (symbol->string name)))
  (define (lib-dir root name) (vendor-dir root name))   ; 兼容:依赖源码树现居 vendor/
  ;; ── 项目本地安装前缀 lib/ 的 src/mt 拆分 ──
  (define (project-libdir root) (join-paths root "lib"))                 ; 安装前缀(base)
  (define (project-lib-pair root) (split-pair (project-libdir root)))    ; (lib/src . lib/<mt>)
  (define (project-obj-dir root) (join-paths (project-libdir root) (current-machine-type))) ; lib/<mt>

  ;; ── install:主命令 ──
  ;; opts: (production . bool) (force . bool) (keep-extra . bool) (offline . bool)
  ;;         (update . bool)   — 强制重解析(忽略旧 lock)
  (define (install root opts)
    (let* ([mpath (project-manifest-path root)]
           [lpath (project-lock-path root)])
      (unless (file-exists? mpath)
        (error 'deps "manifest.ss not found; run `chandler init` first" root))
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
          (clean-orphans root lk opts)
          ;; 2) 源码安装:从 vendor/ 装进 lib/src/(in-process,无 bake 子进程)。
          (rm-rf (project-libdir root))
          (install-dep-sources! root deps-to-vendor)
          ;; M1: 复制依赖声明资源到 lib/share/<libpath>/resources/
          (install-resources root deps-to-vendor)
          ;; 3) 把项目自己也铺进这个前缀:resources/ → lib/share/<name>/resources/,
          ;;    manifest 快照 → lib/.chandler/<name>/ —— lib/ 由此是个**完整前缀**,
          ;;    APP_ROOT 指向它即可,应用四态读同一条路径。
          (sync-app-prefix! root mf)
          (printf "deps: ~a ~a vendored, installed to lib/{src,~a}~%"
                  (length deps-to-vendor) (plural (length deps-to-vendor) "dependency" "dependencies")
                  (current-machine-type))
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

  ;; ── 源码安装:vendor/ → lib/src/(in-process,无 bake 子进程;design 13 §3)──
  ;; chandler 是安装的唯一执行者。每依赖:找 umbrella + 拷整棵源码子树。
  ;; 与 bake 旧 run-install 等价(步骤 1-2),但不经过子进程。
  (define lib-source-extensions '(".chezscheme.sls" ".sls" ".ss" ".sc"))

  (define (find-umbrella-file srcdir name)
    (let loop ([exts lib-source-extensions])
      (cond
        [(null? exts) #f]
        [else
         (let ([p (join-paths srcdir (string-append name (car exts)))])
           (if (file-exists? p) p (loop (cdr exts))))])))

  (define (install-dep-sources! root git-deps)
    (when (pair? git-deps)
      (let ([lib-src (join-paths (project-libdir root) "src")])
        (ensure-dir lib-src)
        (for-each
          (lambda (d)
            (let* ([name (symbol->string (locked-dep-name d))]
                   [vdir (vendor-dir root (locked-dep-name d))]
                   [srcdir (srcdir-join vdir (or (locked-dep-srcdir d) "."))]
                   [from-prefix (string-append srcdir "/")])
              ;; 1. umbrella: srcdir/<name>.{ext} → lib/src/<name>.{ext}
              (let ([umb (find-umbrella-file srcdir name)])
                (when umb
                  (let ([dst (join-paths lib-src (base-name umb))])
                    (ensure-parent dst)
                    (copy-file umb dst))))
              ;; 2. source subtree: srcdir/<name>/** → lib/src/<name>/**
              (let ([subtree (join-paths srcdir name)])
                (when (file-directory? subtree)
                  (for-each
                    (lambda (abs)
                      (let* ([rel (strip-prefix abs from-prefix)]
                             [dst (join-paths lib-src rel)])
                        (ensure-parent dst)
                        (copy-file abs dst)))
                    (files-under subtree))))))
          git-deps))))

  ;; M1: 复制依赖声明资源到 lib/share/<libpath>/resources/(designs/11 §5)
  ;; 资源是 ABI-independent,落 share/ 层(与 src/ <mt>/ 并列);lock 驱动,不重读 dep manifest。
  (define (install-resources root git-deps)
    (for-each
      (lambda (d)
        (let ([resources (locked-dep-resources d)])
          (when resources
            (let ([vdir (vendor-dir root (locked-dep-name d))])
              (for-each
                (lambda (entry)
                  (let* ([libref (car entry)]
                         [rel-path (cdr entry)]
                         [src-dir (join-paths vdir rel-path)]
                         [libpath (string-join (map symbol->string libref) "/")]
                         [dst-base (join-paths (project-libdir root) "share" libpath "resources")])
                    (when (file-directory? src-dir)
                      (copy-resource-tree src-dir dst-base))))
                resources)))))
      git-deps))

  ;; 递归复制目录树:files-under 给绝对路径,copy-file 自动建父目录
  (define (copy-resource-tree src-dir dst-dir)
    (let* ([prefix (if (string-suffix? "/" src-dir) src-dir (string-append src-dir "/"))]
           [files (files-under src-dir)])
      (for-each
        (lambda (f)
          (let* ([rel (strip-prefix f prefix)]
                 [dst (path-join* dst-dir rel)])
            (copy-file f dst)))
        files)))

  ;; ── 孤儿清理:vendor/ 下有、lock 无的目录 ──
  (define (clean-orphans root lk opts)
    (let ([vd (join-paths root "vendor")])
      (when (file-directory? vd)
        (let ([keep (map (lambda (d) (symbol->string (locked-dep-name d))) (lock-deps lk))])
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
        (error 'verify "no manifest.lock; run `chandler deps` first" root))
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
        (unless (or (null? (filter (lambda (d) (eq? 'git (locked-dep-source-kind d))) (lock-deps lk)))
                    (file-directory? (car (project-lib-pair root))))   ; lib/src 存在
          (set! ok #f)
          (fprintf (current-error-port) "missing: lib/src (run `chandler deps` to rebuild)~%"))
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

  ;; ── 库搜索路径(src/mt 拆分:lib/ 一对 (src . obj) + path 依赖源目录)──
  ;; 全局安装前缀(bake user target 落点):~/.local/share/chez;下含 src/ 与 <mt>/。
  (define (global-prefix) (string-append (home-dir) "/.local/share/chez"))
  ;; 全局库目录条目:一对 (~/.local/share/chez/src . ~/.local/share/chez/<mt>)。
  (define global-libdir
    (case-lambda
      [() (split-pair (global-prefix))]))

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
  (define (library-search-dirs root)
    (append
      (if (file-directory? (project-libdir root)) (list (project-lib-pair root)) '())
      (path-dep-source-dirs root)))

  ;; ── 统一库搜索规则(run / exec / repl / activate 共用)──
  ;;   项目模式(lock 存在且有依赖):lib/ + path 源目录 + 项目自身库根 + 全局兜底(项目最高优先)
  ;;   非项目:直接全局
  (define (project-mode? root)
    (and (file-exists? (project-lock-path root))
         (or (file-directory? (project-libdir root))
             (pair? (path-dep-source-dirs root)))))

  (define (resolved-libdirs root)
    (if (project-mode? root)
        (append (library-search-dirs root)
                (list (srcdir-join root (proj-srcdir root)))   ; 项目自身库根
                (list (global-libdir)))                        ; 全局兜底
        (list (global-libdir))))

  (define (proj-srcdir root)
    (let ([mp (project-manifest-path root)])
      (if (file-exists? mp) (manifest-srcdir (read-manifest mp)) ".")))

  ;; ── native 兜底加载清单(designs/24 分层:自加载优先、统一加载兜底)──
  ;;   bake 现为每个带 native 的库生成 `(<lib> native-loader)`,其编译产物
  ;;   lib/<mt>/<lib>/native-loader.so 随交付树落位;该库 FFI 被引用时,loader 自己
  ;;   按候选序定位并 load —— 候选 2 正是 (library-directories) 各根的 obj 侧,
  ;;   而 chandler 挂的 lib/src::lib/<mt> 对,obj 侧恰是 native 落点,故**天然命中**。
  ;;   ⇒ 有 loader 的库**无需预加载**(且自加载是惰性的:不碰 FFI 就不 dlopen);
  ;;      这里只为「非 bake 构建、无生成 loader」的第三方库保留统一加载兜底。
  (define (native-load-paths root)
    (native-sos-under (project-obj-dir root)))

  ;; 扫 obj 树:凡父目录名为 "native" 且扩展名匹配者即 native 动态库
  ;; (与该库的编译 Scheme .so 区分:后者不在 native/ 子目录里);再滤掉自加载的。
  (define (native-sos-under obj-dir)
    (if (file-directory? obj-dir)
        (filter (lambda (f)
                  (and (native-so? f)
                       (string=? "native" (base-name (parent-dir f)))
                       (not (self-loading? f))))
                (files-under obj-dir))
        '()))

  ;; 该 native 所属库是否自带生成 loader:<lib>/native-loader.so 与 native/ 同级
  ;; (f = <lib>/native/<soname>.<ext> → 所属库目录 = f 的祖父目录)。
  (define (self-loading? f)
    (file-exists? (join-paths (parent-dir (parent-dir f)) "native-loader.so")))

  ;; ── 项目自身铺进前缀 lib/(2026-07-23:取代生成 chandler-setup.ss)──
  ;;   lib/ 与 ~/.local/share/chez、解开的 pack 三态同构,APP_ROOT 恒指向这样一个前缀。
  ;;   要做到这点,项目自己的两样东西也得进去:
  ;;     resources/                  → lib/share/<name>/resources/   应用数据
  ;;     manifest.ss                 → lib/.chandler/<name>/manifest.ss  清单快照
  ;;   后者顺便让 (chandler runtime-paths) 的 app-name 认出「这个前缀属于谁」——
  ;;   依赖不写 .chandler/,故项目自己恒是唯一条目。
  ;;
  ;;   run/repl 每次启动也调它:资源是开发期高频改动的东西,拷贝陈旧比不拷更糟。
  ;;   只补新增与更新(mtime 比较),删除由 `chandler deps` 重铺 lib/ 时收敛。
  (define sync-app-prefix!
    (case-lambda
      [(root)
       (let ([mpath (project-manifest-path root)])
         (when (file-exists? mpath) (sync-app-prefix! root (read-manifest mpath))))]
      [(root mf)
       (let ([name (or (manifest-name mf) (base-name root))])
         (sync-app-resources! root name)
         (snapshot-app-manifest! root name))]))

  (define (sync-app-resources! root name)
    (let ([src (join-paths root "resources")])
      (when (file-directory? src)
        (let ([pre (string-append src "/")]
              [dst-base (join-paths (project-libdir root) "share" name "resources")])
          (for-each
            (lambda (abs) (copy-if-stale! abs (join-paths dst-base (strip-prefix abs pre))))
            (files-under src))))))

  (define (snapshot-app-manifest! root name)
    (let ([mpath (project-manifest-path root)]
          [dst (join-paths (project-libdir root) ".chandler" name "manifest.ss")])
      (when (file-exists? mpath) (copy-if-stale! mpath dst))))

  ;; 只在内容可能变了时拷:mtime 严格更新即拷(相等则认为没变 —— 拷贝时 dst 恒不早于 src)
  (define (copy-if-stale! src dst)
    (when (or (not (file-exists? dst)) (mtime>? src dst))
      (ensure-parent dst)
      (copy-file src dst)))

  (define (mtime>? a b)
    (let ([ta (file-modification-time a)] [tb (file-modification-time b)])
      (or (> (time-second ta) (time-second tb))
          (and (= (time-second ta) (time-second tb))
               (> (time-nanosecond ta) (time-nanosecond tb))))))

  ;; ── 工具 ──
  (define (opt opts k default) (alist-ref opts k default))
  (define (dot-entry? e) (and (> (string-length e) 0) (char=? #\. (string-ref e 0))))
  (define (short-rev rev)
    (if (and (string? rev) (>= (string-length rev) 10)) (substring rev 0 10) rev)))
