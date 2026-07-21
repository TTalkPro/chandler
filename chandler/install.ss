#!chezscheme
;;; chandler/install.ss --- vendor/ 物化 + bake install → 扁平 lib/ + 生成 setup(designs/01)
;;;
;;; 依赖模型(Bundler 式):
;;;   git 依赖整仓 checkout → vendor/<name>/;再由 **bake install** 从 vendor 装进 lib/,
;;;   lib/ 成为一个扁平 Chez 库目录(结构同 ~/.local/share/chez/lib:lib/<name>.ss、
;;;   lib/<name>/…、lib/native/<mt>/…)。故库搜索只需挂 lib/ 一个目录。
;;;   path 依赖不进 vendor/lib,activate/run 时直挂其源目录(live)。
;;;   install 生成 chandler-setup.ss:app 主脚本顶部 (load) 它即自动激活(每次执行)。
;;;   install 依赖 bake 可用。

(library (chandler install)
  (export install verify sync-status list-deps
          vendor-dir lib-dir project-lock-path project-manifest-path
          library-search-dirs native-load-paths write-setup-file
          project-libdir global-libdir path-dep-source-dirs
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
  (define (project-libdir root) (join-paths root "lib"))
  (define (setup-path root) (join-paths root "chandler-setup.ss"))
  (define (bake-command) (or (getenv* "CHANDLER_BAKE") "bake"))

  ;; ── install:主命令 ──
  ;; opts: (production . bool) (force . bool) (keep-extra . bool) (offline . bool)
  (define (install root opts)
    (let* ([mpath (project-manifest-path root)]
           [lpath (project-lock-path root)])
      (unless (file-exists? mpath)
        (error 'install "未找到 manifest.ss,先跑 chandler init" root))
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
          ;; 2) bake install:从 vendor 装进扁平 lib/(先清空 lib/ 重建)
          (rm-rf (project-libdir root))
          (bake-install-deps root git-deps)
          ;; 3) 生成 chandler-setup.ss(一行激活文件)
          (write-setup-file root)
          (printf "install 完成:~a 个依赖 → vendor/,已 bake install 到 lib/;生成 chandler-setup.ss~%"
                  (length git-deps))
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
                    (format "~a 有本地改动,拒绝覆盖(--force 强制)~%  ~a"
                            (locked-dep-name ld) dir)))]
        [(string=? (head-rev dir) rev) (void)]
        [else
         (unless (has-rev? url rev) (update-mirror url))
         (checkout-detach dir rev)])))

  ;; ── bake install:生成一份含所有 git 依赖 install-task 的 recipe,一次 bake 装进 lib/ ──
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
                      (fprintf (current-error-port) "note: 保留额外目录 vendor/~a~%" entry)
                      (begin (fprintf (current-error-port) "清理孤儿依赖 vendor/~a~%" entry)
                             (rm-rf full))))))
            (dir-entries vd))))))

  ;; ── verify:vendor/ 对 lock 一致性(rev 匹配 + 无脏)+ lib/ 存在 ──
  (define (verify root)
    (let ([lpath (project-lock-path root)])
      (unless (file-exists? lpath)
        (error 'verify "无 manifest.lock,先跑 chandler install" root))
      (let ([lk (read-lock lpath)] [ok #t])
        (for-each
          (lambda (d)
            (when (eq? 'git (locked-dep-source-kind d))
              (let ([dir (vendor-dir root (locked-dep-name d))])
                (cond
                  [(not (file-directory? dir))
                   (set! ok #f)
                   (fprintf (current-error-port) "缺失:vendor/~a(跑 chandler install)~%" (locked-dep-name d))]
                  [(not (string=? (head-rev dir) (locked-dep-rev d)))
                   (set! ok #f)
                   (fprintf (current-error-port) "rev 不符:vendor/~a 当前 ~a,锁定 ~a~%"
                            (locked-dep-name d) (head-rev dir) (locked-dep-rev d))]
                  [(dirty? dir)
                   (set! ok #f)
                   (fprintf (current-error-port) "有改动:vendor/~a~%" (locked-dep-name d))]))))
          (lock-deps lk))
        (unless (or (null? (filter (lambda (d) (eq? 'git (locked-dep-source-kind d))) (lock-deps lk)))
                    (file-directory? (project-libdir root)))
          (set! ok #f)
          (fprintf (current-error-port) "缺失:lib/(跑 chandler install 重建)~%"))
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

  ;; ── 库搜索路径(新模型:扁平 lib/ 一个目录 + path 依赖源目录)──
  (define global-libdir
    (case-lambda
      [() (string-append (home-dir) "/.local/share/chez/lib")]))

  ;; path 依赖的源目录(相对 root 拼成路径),供 live 挂载
  (define (path-dep-source-dirs root)
    (let ([mpath (project-manifest-path root)])
      (if (file-exists? mpath)
          (let ([mf (read-manifest mpath)])
            (map (lambda (d) (join-paths root (dep-source-loc d)))
                 (filter (lambda (d) (eq? 'path (dep-source-kind d)))
                         (append (manifest-deps mf) (manifest-dev-deps mf)))))
          '())))

  ;; run/exec/activate 用:lib/(若在)+ path 依赖源目录
  (define (library-search-dirs root)
    (append
      (if (file-directory? (project-libdir root)) (list (project-libdir root)) '())
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

  ;; native .so:扁平 lib/native/<mt>/*.so
  (define (native-load-paths root)
    (let ([nd (native-dir (project-libdir root))])   ; lib/native/<mt>
      (if (file-directory? nd)
          (filter (lambda (f) (string-suffix? (string-append "." (so-ext)) f))
                  (files-under nd))
          '())))

  ;; ── 生成 chandler-setup.ss(位置无关:依入口脚本目录解析 root)──
  (define (write-setup-file root)
    (let* ([path-rels (relativize root (path-dep-source-dirs root))]
           [native-rels (relativize root (native-load-paths root))])
      (call-with-output-file (setup-path root)
        (lambda (p) (emit-setup p path-rels native-rels))
        'truncate)))

  (define (relativize root paths)
    (let ([pre (string-append root "/")])
      (map (lambda (x) (strip-prefix x pre)) paths)))

  (define (emit-setup p path-rels native-rels)
    (put-string p ";;; chandler-setup.ss --- 由 chandler 生成;于主脚本顶部 (load) 它(勿手改)。\n")
    (put-string p ";;; 依入口脚本(与本文件同目录)位置解析项目根,故项目可整体移动、任意 cwd 皆可。\n")
    (put-string p ";;; 主脚本顶部推荐写(位置无关加载):\n")
    (put-string p ";;;   (load (string-append (let ([d (path-parent (car (command-line)))])\n")
    (put-string p ";;;                          (if (string=? d \"\") \".\" d)) \"/chandler-setup.ss\"))\n")
    (put-string p ";;; 若总从项目根运行,简写即可:  (load \"chandler-setup.ss\")\n")
    (put-string p "(let* ([argv (command-line)]\n")
    (put-string p "       [script (if (pair? argv) (car argv) \".\")]\n")
    (put-string p "       [root (let loop ([i (- (string-length script) 1)])\n")
    (put-string p "               (cond [(< i 0) \".\"]\n")
    (put-string p "                     [(char=? #\\/ (string-ref script i)) (substring script 0 i)]\n")
    (put-string p "                     [else (loop (- i 1))]))]\n")
    (put-string p "       [J (lambda (rel) (string-append root \"/\" rel))]\n")
    (put-string p "       [global (string-append (or (getenv \"HOME\") \".\") \"/.local/share/chez/lib\")])\n")
    (put-string p "  (library-directories\n")
    (put-string p "    (append (map J '")
    (write (cons "lib" path-rels) p)
    (put-string p ") (list global) (library-directories)))\n")
    (put-string p "  (for-each (lambda (rel) (let ([so (J rel)]) (when (file-exists? so) (load-shared-object so))))\n")
    (put-string p "    '")
    (write native-rels p)
    (put-string p "))\n"))

  ;; ── 工具 ──
  (define (opt opts k default) (alist-ref opts k default))
  (define (dot-entry? e) (and (> (string-length e) 0) (char=? #\. (string-ref e 0))))
  (define (short-rev rev)
    (if (and (string? rev) (>= (string-length rev) 10)) (substring rev 0 10) rev)))
