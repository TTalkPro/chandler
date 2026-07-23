#!chezscheme
;;; chandler/install.ss --- vendor/ 物化 + bake install → lib/{src,<mt>} + 生成 setup(designs/01)
;;;
;;; 依赖模型(Bundler 式,2026-07-22 对齐 bake install 的 src/mt 拆分):
;;;   git 依赖整仓 checkout → vendor/<name>/;再由 **bake install** 从 vendor 装进 lib/,
;;;   lib/ 成为一个 Chez 库目录**前缀**,内含 src/mt 拆分(结构同 ~/.local/share/chez):
;;;     lib/src/          ← 源码(umbrella <name>.ss + <name>/… 各依赖并存)
;;;     lib/<mt>/         ← 平台绑定产物(编译 .so + native/<lib>/…),chandler build 后填充
;;;   故库搜索挂**一对** (lib/src . lib/<mt>);消费方一条 pair 同时解析源码与对象。
;;;   path 依赖不进 vendor/lib,activate/run 时直挂其源目录(live)。
;;;   install 生成 chandler-setup.ss:app 主脚本顶部 (load) 它即自动激活(每次执行)。
;;;   install 依赖 bake 可用。

(library (chandler install)
  (export install verify sync-status list-deps
          vendor-dir lib-dir project-lock-path project-manifest-path
          library-search-dirs native-load-paths write-setup-file
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
  (define (setup-path root) (join-paths root "chandler-setup.ss"))
  (define (bake-command) (or (getenv* "CHANDLER_BAKE") "bake"))

  ;; ── install:主命令 ──
  ;; opts: (production . bool) (force . bool) (keep-extra . bool) (offline . bool)
  (define (install root opts)
    (let* ([mpath (project-manifest-path root)]
           [lpath (project-lock-path root)])
      (unless (file-exists? mpath)
        (error 'install "manifest.ss not found; run `chandler init` first" root))
      (parameterize ([offline? (opt opts 'offline #f)])
        (let* ([mf (read-manifest mpath)]
               [lk (obtain-lock root mf mpath lpath opts)]
               [git-deps (filter (lambda (d)
                                   (and (eq? 'git (locked-dep-source-kind d))
                                        (or (not (opt opts 'production #f))
                                            (not (eq? 'dev (locked-dep-scope d))))))
                                 (lock-deps lk))])
          ;; 1) git 依赖整仓 → vendor/<name>
          (for-each (lambda (d) (sync-dep root d opts)) git-deps)
          (clean-orphans root lk opts)
          ;; 2) bake install:从 vendor 装进 lib/{src,<mt>}(先清空 lib/ 重建)。
          ;;    install 只发源码(vendor 是干净 checkout,无 _build);编译产物由
          ;;    `chandler build` 补进 lib/<mt>/。
          (rm-rf (project-libdir root))
          (bake-install-deps root git-deps)
          ;; M1: 复制依赖声明资源到 lib/share/<libpath>/resources/(designs/11 §5)
          (install-resources root git-deps)
          ;; 3) 生成 chandler-setup.ss(一行激活文件)
          (write-setup-file root)
          (printf "install: ~a ~a vendored, installed to lib/{src,~a}; wrote chandler-setup.ss~%"
                  (length git-deps) (plural (length git-deps) "dependency" "dependencies")
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

  ;; ── 单依赖 checkout → vendor/<name>(幂等 + 脏拒动)──
  (define (sync-dep root ld opts)
    (let ([dir (vendor-dir root (locked-dep-name ld))]
          [url (locked-dep-source-loc ld)]
          [rev (locked-dep-rev ld)])
      (cond
        [(not (file-directory? dir)) (materialize url rev dir)]
        [(dirty? dir)
         (if (opt opts 'force #f)
             (begin (rm-rf dir) (materialize url rev dir))
             (error 'install
                    (format "~a has local changes; refusing to overwrite (use --force)~%  ~a"
                            (locked-dep-name ld) dir)))]
        [(string=? (head-rev dir) rev) (void)]
        [else
         (unless (has-rev? url rev) (update-mirror url))
         (checkout-detach dir rev)])))

  ;; ── bake install:生成一份含所有 git 依赖 install-task 的 recipe,一次 bake 装进 lib/{src,<mt>} ──
  (define (bake-install-deps root git-deps)
    (when (pair? git-deps)
      (let ([recipe (join-paths root ".chandler-install.ss")])
        (call-with-output-file recipe
          (lambda (p)
            (for-each
              (lambda (d)
                (let* ([name (symbol->string (locked-dep-name d))]
                       [from (srcdir-join (join-paths "vendor" name) (locked-dep-srcdir d))])
                  ;; (from …) 相对 bake cwd=root;(target (prefix "lib")) → root/lib
                  (fprintf p "(install-task 'i-~a (lib ~a) (from ~s) (target (prefix \"lib\")))~%"
                           name name from)))
              git-deps)
            (fprintf p "(task 'install-all '(~a) (lambda () (void)))~%"
                     (string-join (map (lambda (d)
                                         (string-append "i-" (symbol->string (locked-dep-name d))))
                                       git-deps) " "))
            (fprintf p "(default-task 'install-all)~%"))
          'truncate)
        (guard (e [#t (delete-if-exists recipe) (raise e)])
          (run-check (bake-command) (list "-f" recipe "install-all") (list (cons 'cwd root)))
          (delete-if-exists recipe)))))

  (define (delete-if-exists p) (when (file-exists? p) (delete-file p)))

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
        (error 'verify "no manifest.lock; run `chandler install` first" root))
      (let ([lk (read-lock lpath)] [ok #t])
        (for-each
          (lambda (d)
            (when (eq? 'git (locked-dep-source-kind d))
              (let ([dir (vendor-dir root (locked-dep-name d))])
                (cond
                  [(not (file-directory? dir))
                   (set! ok #f)
                   (fprintf (current-error-port) "missing: vendor/~a (run `chandler install`)~%" (locked-dep-name d))]
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
          (fprintf (current-error-port) "missing: lib/src (run `chandler install` to rebuild)~%"))
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

  ;; ── 生成 chandler-setup.ss(位置无关:依入口脚本目录解析 root;src/mt 拆分)──
  ;;   纯 Chez(无 (chandler) 依赖):挂 lib/ 一对(源.对象)+ path 源目录 + 全局兜底一对。
  ;;   native 走 designs/24 分层:**挂好对本身就使 bake 生成的 native-loader 自加载生效**
  ;;   (loader 候选 2 = library-directories 的 obj 侧 = lib/<mt>),故不再预加载有 loader
  ;;   的库;仅对无 loader 的第三方库运行时扫描兜底(故 install 后再 build 亦生效)。
  (define (write-setup-file root)
    (let ([path-rels (relativize root (path-dep-source-dirs root))])
      (call-with-output-file (setup-path root)
        (lambda (p) (emit-setup p path-rels))
        'truncate)))

  (define (relativize root paths)
    (let ([pre (string-append root "/")])
      (map (lambda (x) (strip-prefix x pre)) paths)))

  (define (emit-setup p path-rels)
    (put-string p ";;; chandler-setup.ss --- generated by chandler; (load) it at the top of your\n")
    (put-string p ";;; main script. DO NOT EDIT -- regenerated on every `chandler install`.\n")
    (put-string p ";;;\n")
    (put-string p ";;; Resolves the project root from the entry script's own location (this file\n")
    (put-string p ";;; sits beside it), so the project can be moved and run from any cwd.\n")
    (put-string p ";;;\n")
    (put-string p ";;; Library search uses Chez (source-dir . object-dir) PAIRS -- lib/src with\n")
    (put-string p ";;; lib/<machine-type> (the src/mt split produced by `bake install`).\n")
    (put-string p ";;;\n")
    (put-string p ";;; Native (FFI) libraries are layered: mounting that pair is by itself enough\n")
    (put-string p ";;; for bake-generated `(<lib> native-loader)` libraries to self-load, since a\n")
    (put-string p ";;; loader locates its .so via the object side of library-directories. That is\n")
    (put-string p ";;; lazy -- nothing is dlopen'd unless the FFI is actually used. The scan below\n")
    (put-string p ";;; is only a fallback for third-party libraries built WITHOUT bake (no\n")
    (put-string p ";;; generated loader), so it skips any library shipping a native-loader.so.\n")
    (put-string p ";;;\n")
    (put-string p ";;;\n")
    (put-string p ";;; APP_ROOT is set to the project root when the environment does not already\n")
    (put-string p ";;; carry one. It is the single variable a `chandler pack` launcher exports, and\n")
    (put-string p ";;; everything else in a distribution hangs off it at a convention-fixed path\n")
    (put-string p ";;; (resources/, lib/<mt>/<lib>/native/). Setting it here means application code\n")
    (put-string p ";;; reads ONE thing in every state -- source checkout, install, pack -- instead\n")
    (put-string p ";;; of branching on whether it happens to be deployed. An already-set value wins:\n")
    (put-string p ";;; inside a pack the launcher got there first and is authoritative.\n")
    (put-string p ";;;\n")
    (put-string p ";;; Recommended (location-independent) at the top of your main script:\n")
    (put-string p ";;;   (load (string-append (let ([d (path-parent (car (command-line)))])\n")
    (put-string p ";;;                          (if (string=? d \"\") \".\" d)) \"/chandler-setup.ss\"))\n")
    (put-string p ";;; If you always run from the project root, simply: (load \"chandler-setup.ss\")\n")
    (pretty-print (setup-datum path-rels) p))

  ;; 构造 setup 主体为数据(避免手工字符串转义);machine-type 于**加载期**求值,
  ;; 故项目跨机亦对(对象目录随 mt 走)。
  (define (setup-datum path-rels)
    `(let* ([argv (command-line)]
            [script (if (pair? argv) (car argv) ".")]
            [root (let loop ([i (- (string-length script) 1)])
                    (cond [(< i 0) "."]
                          [(char=? #\/ (string-ref script i)) (substring script 0 i)]
                          [else (loop (- i 1))]))]
            [mt (symbol->string (machine-type))]
            [J (lambda (rel) (string-append root "/" rel))]
            [_approot (let ([cur (getenv "APP_ROOT")])
                        (when (or (not cur) (string=? cur ""))
                          (putenv "APP_ROOT" root)))]
            [gpfx (string-append (or (getenv "HOME") ".") "/.local/share/chez")]
            [bn (lambda (d)
                  (let loop ([i (- (string-length d) 1)])
                    (cond [(< i 0) d]
                          [(char=? #\/ (string-ref d i)) (substring d (+ i 1) (string-length d))]
                          [else (loop (- i 1))])))]
            [pd (lambda (d)
                  (let loop ([i (- (string-length d) 1)])
                    (cond [(< i 0) "."]
                          [(char=? #\/ (string-ref d i)) (substring d 0 i)]
                          [else (loop (- i 1))])))]
            [ends? (lambda (s suf)
                     (let ([ls (string-length s)] [lu (string-length suf)])
                       (and (>= ls lu) (string=? suf (substring s (- ls lu) ls)))))]
            [nativeso? (lambda (q) (or (ends? q ".so") (ends? q ".dylib") (ends? q ".dll")))]
            ;; a library that ships <lib>/native-loader.so self-loads its own native
            [self-loading? (lambda (d) (file-exists? (string-append (pd d) "/native-loader.so")))])
       ;; Library search: project lib/ pair, then path-dep sources, then the global
       ;; prefix pair -- project entries first so they win.
       (library-directories
         (append (list (cons (J "lib/src") (J (string-append "lib/" mt))))
                 (map J ',path-rels)
                 (list (cons (string-append gpfx "/src") (string-append gpfx "/" mt)))
                 (library-directories)))
       ;; Native fallback ONLY for libraries with no bake-generated loader:
       ;; scan lib/<mt>/**/native/*.{so,dylib,dll}, skipping self-loading libraries.
       (let walk ([dir (J (string-append "lib/" mt))])
         (when (file-directory? dir)
           (for-each
             (lambda (e)
               (unless (or (string=? e ".") (string=? e ".."))
                 (let ([q (string-append dir "/" e)])
                   (cond [(file-directory? q) (walk q)]
                         [(and (string=? "native" (bn dir))
                               (nativeso? q)
                               (not (self-loading? dir)))
                          (load-shared-object q)]))))
             (directory-list dir))))))

  ;; ── 工具 ──
  (define (opt opts k default) (alist-ref opts k default))
  (define (dot-entry? e) (and (> (string-length e) 0) (char=? #\. (string-ref e 0))))
  (define (short-rev rev)
    (if (and (string? rev) (>= (string-length rev) 10)) (substring rev 0 10) rev)))
