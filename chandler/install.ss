#!chezscheme
;;; chandler/install.ss --- lib/ 物化 / install 判定 / verify(designs/01 §install 判定, 05)
;;;
;;; install 判定:lock 过期?→ 解析重写 lock;→ 逐依赖物化到 lib/<name>@rev(幂等);
;;; → 清理 lock 中已无的孤儿目录。脏改动默认拒动。path 依赖不物化(activate 时按 manifest 挂)。

(library (chandler install)
  (export install verify sync-status list-deps
          lib-dir project-lock-path project-manifest-path
          library-search-dirs native-load-paths)
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
  (define (lib-dir root name) (join-paths (join-paths root "lib") (symbol->string name)))

  ;; ── install:主命令 ──
  ;; opts: (production . bool) (force . bool) (keep-extra . bool) (offline . bool)
  (define (install root opts)
    (let* ([mpath (project-manifest-path root)]
           [lpath (project-lock-path root)])
      (unless (file-exists? mpath)
        (error 'install "未找到 manifest.ss,先跑 chandler init" root))
      (parameterize ([offline? (opt opts 'offline #f)])
        (let* ([mf (read-manifest mpath)]
               [lk (obtain-lock root mf mpath lpath opts)])
          ;; 物化每个 git 依赖(dev 依 production 决定)
          (let ([targets (filter (lambda (d)
                                   (and (eq? 'git (locked-dep-source-kind d))
                                        (or (not (opt opts 'production #f))
                                            (not (eq? 'dev (locked-dep-scope d))))))
                                 (lock-deps lk))])
            (for-each (lambda (d) (sync-dep root d opts)) targets)
            (clean-orphans root lk opts))
          (printf "install 完成:~a 个依赖已就绪~%" (length (lock-deps lk)))
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

  ;; ── 单依赖物化(幂等 + 脏拒动)──
  (define (sync-dep root ld opts)
    (let ([dir (lib-dir root (locked-dep-name ld))]
          [url (locked-dep-source-loc ld)]
          [rev (locked-dep-rev ld)])
      (cond
        [(not (file-directory? dir))
         (materialize url rev dir)]
        [(dirty? dir)
         (if (opt opts 'force #f)
             (begin (rm-rf dir) (materialize url rev dir))
             (error 'install
                    (format "~a 有本地改动,拒绝覆盖(--force 强制)~%  ~a"
                            (locked-dep-name ld) dir)))]
        [(string=? (head-rev dir) rev) (void)]        ; 已在目标 rev,幂等跳过
        [else
         (unless (has-rev? url rev) (update-mirror url))
         (checkout-detach dir rev)])))

  ;; ── 孤儿清理:lib/ 下有、lock 无的目录 ──
  (define (clean-orphans root lk opts)
    (let ([libd (join-paths root "lib")])
      (when (file-directory? libd)
        (let ([keep (map (lambda (d) (symbol->string (locked-dep-name d))) (lock-deps lk))])
          (for-each
            (lambda (entry)
              (let ([full (join-paths libd entry)])
                (when (and (file-directory? full)
                           (not (member entry keep))
                           (not (dot-entry? entry)))
                  (if (opt opts 'keep-extra #f)
                      (fprintf (current-error-port) "note: 保留额外目录 lib/~a~%" entry)
                      (begin
                        (fprintf (current-error-port) "清理孤儿依赖 lib/~a~%" entry)
                        (rm-rf full))))))
            (dir-entries libd))))))

  ;; ── verify:lib/ 对 lock 一致性(rev 匹配 + 无脏)──
  (define (verify root)
    (let ([lpath (project-lock-path root)])
      (unless (file-exists? lpath)
        (error 'verify "无 manifest.lock,先跑 chandler install" root))
      (let ([lk (read-lock lpath)]
            [ok #t])
        (for-each
          (lambda (d)
            (when (eq? 'git (locked-dep-source-kind d))
              (let ([dir (lib-dir root (locked-dep-name d))])
                (cond
                  [(not (file-directory? dir))
                   (set! ok #f)
                   (fprintf (current-error-port) "缺失:lib/~a(跑 chandler install)~%"
                            (locked-dep-name d))]
                  [(not (string=? (head-rev dir) (locked-dep-rev d)))
                   (set! ok #f)
                   (fprintf (current-error-port) "rev 不符:lib/~a 当前 ~a,锁定 ~a~%"
                            (locked-dep-name d) (head-rev dir) (locked-dep-rev d))]
                  [(dirty? dir)
                   (set! ok #f)
                   (fprintf (current-error-port) "有改动:lib/~a~%" (locked-dep-name d))]))))
          (lock-deps lk))
        ok)))

  ;; sync-status:list/tree 用,返回每依赖 (name rev source scope 状态)
  (define (sync-status root)
    (let ([lpath (project-lock-path root)])
      (if (file-exists? lpath)
          (map (lambda (d)
                 (list (locked-dep-name d)
                       (short-rev (locked-dep-rev d))
                       (locked-dep-source-loc d)
                       (locked-dep-scope d)))
               (lock-deps (read-lock lpath)))
          '())))

  (define (list-deps root) (sync-status root))

  ;; ── run/exec 用:库搜索路径 + native 加载路径 ──
  ;; 库搜索根:lock 各依赖的 lib/<name>/<srcdir> + manifest 的 path 依赖根
  (define (library-search-dirs root)
    (let ([lpath (project-lock-path root)]
          [mpath (project-manifest-path root)])
      (append
        (if (file-exists? lpath)
            (map (lambda (d) (lib-root root (symbol->string (locked-dep-name d))
                                       (locked-dep-srcdir d)))
                 (lock-deps (read-lock lpath)))
            '())
        (if (file-exists? mpath)
            (let ([mf (read-manifest mpath)])
              (map (lambda (d) (join-paths root (dep-source-loc d)))
                   (filter (lambda (d) (eq? 'path (dep-source-kind d)))
                           (append (manifest-deps mf) (manifest-dev-deps mf)))))
            '()))))

  ;; native .so 绝对/相对路径,按拓扑序(被依赖先)
  (define (native-load-paths root)
    (let ([lpath (project-lock-path root)])
      (if (file-exists? lpath)
          (let ([lk (read-lock lpath)])
            (apply append
              (map (lambda (d)
                     (map (lambda (nat)
                            (native-path (lib-dir root (locked-dep-name d))
                                         (symbol->string nat)))
                          (locked-dep-natives d)))
                   (topo-order lk))))
          '())))

  ;; ── 工具(通用来自 util/fs:opt→alist-ref、rm-rf/dir-entries→fs)──
  (define (opt opts k default) (alist-ref opts k default))

  (define (dot-entry? e)
    (and (> (string-length e) 0) (char=? #\. (string-ref e 0))))

  (define (short-rev rev)
    (if (and (string? rev) (>= (string-length rev) 10)) (substring rev 0 10) rev)))
