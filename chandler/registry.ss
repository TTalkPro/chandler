#!chezscheme
;;; chandler/registry.ss --- 全局安装文件清单事务(designs/05;src/mt 拆分)
;;;
;;; 让 --global 安装可审计、可干净卸载、可检测冲突。注册表 = <prefix>/.chandler/registry/<name>.ss,
;;; 记已装文件 + sha256。安装事务:冲突检测 → staging → 进位 → 登记(registry 最后写 = 弱事务)。
;;; bake install 复用本库(designs/07 §5),故导出干净、不 import 上层。
;;;
;;; 2026-07-22 对齐 bake install 的 src/mt 拆分:目标是库**前缀**(~/.local/share/chez),
;;; 源码落 <prefix>/src/、编译产物整棵 _build/<mt>/ 落 <prefix>/<mt>/(与 bake install
;;; 同一全局库目录,消费方一条 <prefix>/src::<prefix>/<mt> 解析二者)。注册记录的相对
;;; 路径已含 src//<mt>/ 前缀,故冲突检测/卸载/doctor 逻辑不变,只是相对路径带了命名空间。

(library (chandler registry)
  (export default-user-libdir default-system-libdir default-user-bindir default-system-bindir
          chandler-home
          install-global uninstall-global list-global doctor-global
          registry-dir registry-file installed-files)
  (import (chezscheme)
          (chandler util)
          (chandler fs)
          (chandler layout)
          (chandler sexp)
          (chandler hash))

  ;; ── 库前缀(下含 src/ 与 <mt>/)──
  ;;
  ;; **两个用户前缀,平台感知**(2026-07-24):
  ;;   --user   POSIX ~/.local/share/chez        Windows %LOCALAPPDATA%\chez
  ;;   --system POSIX /usr/local/share/chez      Windows %ProgramData%\chez
  ;; 这是 install/uninstall/doctor 的**落点**(由 --user/--system 旗标选,默认 --user)。
  (define (win?) (windows-mt? (current-machine-type)))

  (define (default-user-libdir)
    (if (win?)
        (join-paths (or (getenv* "LOCALAPPDATA") (home-dir)) "chez")
        (string-append (home-dir) "/.local/share/chez")))

  (define (default-system-libdir)
    (if (win?)
        (join-paths (or (getenv* "ProgramData") "C:/ProgramData") "chez")
        "/usr/local/share/chez"))

  ;; bin/ 落点(P3:app install 的命令行入口)。POSIX 不在前缀内(~/.local/bin 而非
  ;; ~/.local/share/chez/bin,遵循 XDG 惯例);Windows 在前缀子目录(chez\bin)。
  (define (default-user-bindir)
    (if (win?)
        (join-paths (default-user-libdir) "bin")
        (string-append (home-dir) "/.local/bin")))

  (define (default-system-bindir)
    (if (win?)
        (join-paths (default-system-libdir) "bin")
        "/usr/local/bin"))

  ;; ── CHANDLER_HOME:正在跑的 chandler 自己的库前缀(src/mt 布局)──
  ;;
  ;; 由启动器设(装好的 = 装的前缀;bootstrap --dev = <repo>/dist/chez)。**读侧**用它:
  ;; deps 从这里 copy chandler runtime 子集进 _vendor、run/build 的全局兜底挂它。
  ;; 未设 → 默认 --user 前缀(即"我大概装在用户位置")。
  ;; 与"安装落点"(--user/--system 旗标)是**两回事**:常见情形重合,--system 装 / dev
  ;; 前缀时不重合。故这里不看旗标,只认 CHANDLER_HOME 或 --user 默认。
  (define (chandler-home)
    (or (getenv* "CHANDLER_HOME") (default-user-libdir)))

  (define (registry-dir libdir) (join-paths libdir ".chandler/registry"))
  (define (registry-file libdir name) (join-paths (registry-dir libdir) (string-append name ".ss")))
  (define (staging-dir libdir name) (join-paths libdir (string-append ".chandler/staging/" name)))

  ;; ── 安装:src(布局规范库根)→ libdir ──
  ;; meta: (name version source-datum installed-at installer) — 时钟由调用方传入
  ;; opts: (adopt . #t) (force . #t)
  (define (install-global src libdir meta opts)
    (let* ([name (car meta)]
           [entries (enumerate-lib src name)]      ; ((dest-rel . src-abs) …);dest-rel 已带 src//<mt>/ 命名空间
           [files (map car entries)])              ; 相对 <prefix> 的目标路径清单
      (when (null? entries)
        (error 'install-global "source directory has no installable library files (no <name>.ss and no <name>/)" src name))
      (let ([old (and (file-exists? (registry-file libdir name))
                      (installed-files (read-registry libdir name)))])
        (check-conflicts files libdir name opts)
        (let ([staging (staging-dir libdir name)])
          (rm-rf staging)
          ;; 1) 拷到 staging(源 src-abs → staging/dest-rel)
          (for-each (lambda (e)
                      (let ([s (cdr e)] [d (join-paths staging (car e))])
                        (ensure-parent d) (copy-file s d)))
                    entries)
          ;; 2) 进位:staging → libdir(按 dest-rel)
          (for-each (lambda (rel)
                      (let ([s (join-paths staging rel)] [d (join-paths libdir rel)])
                        (ensure-parent d) (move-file s d)))
                    files)
          (rm-rf staging)
          ;; 3) 孤儿清理(升级:旧有、新无的文件删除)
          (when old
            (for-each (lambda (rel)
                        (unless (member rel files)
                          (delete-if-exists (join-paths libdir rel))))
                      old))
          ;; 4) 登记(最后写 = 安装完整标志)
          (write-registry libdir name meta files
                          (map (lambda (rel) (sha256-file (join-paths libdir rel))) files))
          name))))

  ;; 冲突检测:计划集中每路径若已属其它包 → 错;野文件 → 拒(--adopt 收编);属本包 → 升级
  (define (check-conflicts files libdir name opts)
    (let ([owners (path-owner-map libdir)])
      (for-each
        (lambda (rel)
          (let ([target (join-paths libdir rel)])
            (when (file-exists? target)
              (let ([owner (hashtable-ref owners rel #f)])
                (cond
                  [(and owner (string=? owner name)) (void)]        ; 本包 → 升级
                  [owner (error 'install-global
                                (format "file is owned by package ~a; refusing to overwrite: ~a" owner rel))]
                  [(alist-ref opts 'adopt) (void)]                    ; 收编野文件
                  [(alist-ref opts 'force) (void)]
                  [else (error 'install-global
                               (format "unowned file already at target; use --adopt or --force: ~a" rel))])))))
        files)))

  ;; 反查:libdir 下每相对路径 → 拥有它的包名(据各 registry files 字段)
  (define (path-owner-map libdir)
    (let ([ht (make-hashtable string-hash string=?)])
      (for-each
        (lambda (rname)
          (for-each (lambda (rel) (hashtable-set! ht rel rname))
                    (installed-files (read-registry libdir rname))))
        (list-registry-names libdir))
      ht))

  ;; ── 卸载:据 registry 逐文件(哈希核对)删除 ──
  ;; opts: (keep-modified . #t)
  (define (uninstall-global name libdir opts)
    (let ([rf (registry-file libdir name)])
      (unless (file-exists? rf)
        (error 'uninstall-global "package is not installed" name libdir))
      (let* ([reg (read-registry libdir name)]
             [entries (registry-file-entries reg)])
        (for-each
          (lambda (e)
            (let* ([rel (car e)] [want (cadr e)] [target (join-paths libdir rel)])
              (when (file-exists? target)
                (if (and (string=? want (sha256-file target)))
                    (delete-file target)
                    (if (alist-ref opts 'keep-modified)
                        (fprintf (current-error-port) "keeping modified file: ~a~%" rel)
                        (begin (fprintf (current-error-port) "warning: ~a was modified; deleting anyway~%" rel)
                               (delete-file target)))))))
          entries)
        (prune-empty-dirs libdir (map car entries))
        (delete-file rf)
        name)))

  ;; ── list / doctor ──
  (define (list-global libdir)
    (map (lambda (name)
           (let ([reg (read-registry libdir name)])
             (list name
                   (field-ref (cdr reg) 'version)
                   (field-ref (cdr reg) 'installer))))
         (list-registry-names libdir)))

  ;; doctor:野文件 / 缺失 / 哈希漂移 / 残留 staging
  (define (doctor-global libdir)
    (let ([issues '()])
      (define (add! x) (set! issues (cons x issues)))
      ;; 每包:文件在否、哈希对否
      (for-each
        (lambda (name)
          (for-each
            (lambda (e)
              (let ([target (join-paths libdir (car e))])
                (cond
                  [(not (file-exists? target)) (add! (list 'missing name (car e)))]
                  [(not (string=? (cadr e) (sha256-file target)))
                   (add! (list 'drift name (car e)))])))
            (registry-file-entries (read-registry libdir name))))
        (list-registry-names libdir))
      ;; 残留 staging
      (let ([sd (join-paths libdir ".chandler/staging")])
        (when (and (file-directory? sd) (pair? (dir-entries sd)))
          (add! (list 'stale-staging sd))))
      (reverse issues)))

  ;; ── registry 读写 ──
  (define (write-registry libdir name meta files hashes)
    (let ([rf (registry-file libdir name)])
      (ensure-parent rf)
      (write-canonical-file rf
        `(installed
           (format 1)
           (name ,(car meta))
           (version ,(list-ref meta 1))
           (source ,(list-ref meta 2))
           (installed-at ,(list-ref meta 3))
           (installer ,(list-ref meta 4))
           (files ,@(map (lambda (rel h) `(,rel (sha256 ,h))) files hashes))))))

  (define (read-registry libdir name)
    (read-datum-file (registry-file libdir name)))

  (define (installed-files reg)
    (map car (field-ref* (cdr reg) 'files)))

  ;; ((rel sha) ...) → ((rel hash) ...)
  (define (registry-file-entries reg)
    (map (lambda (f) (list (car f) (field-ref (cdr f) 'sha256)))
         (field-ref* (cdr reg) 'files)))

  (define (list-registry-names libdir)
    (let ([rd (registry-dir libdir)])
      (if (file-directory? rd)
          (map strip-ss
               (filter (lambda (e) (string-suffix? ".ss" e)) (dir-entries rd)))
          '())))

  ;; ── 库文件枚举 → ((dest-rel . src-abs) …);dest-rel 相对 <prefix>,已含 src//<mt>/ 命名空间──
  ;;   源码 <name>.ss + <name>/**            → src/<...>
  ;;   编译产物整棵 _build/<mt>/**(若在)   → <mt>/<...>(编译 .so + native;排除构建内部物)
  (define (enumerate-lib src name)
    (append
      ;; 源码 → src/
      (let ([srcs (append
                    (if (file-exists? (join-paths src (string-append name ".ss")))
                        (list (string-append name ".ss")) '())
                    (rel-files-under src name))])
        (map (lambda (rel) (cons (join-paths "src" rel) (join-paths src rel))) srcs))
      ;; 编译产物 _build/<mt>/ → <mt>/(排除 .bake-manifest 指纹缓存与 *.wpo 中间物)
      (let ([bdir (join-paths src "_build" (current-machine-type))])
        (if (file-directory? bdir)
            (filter-map
              (lambda (abs)
                (let ([rel (strip-prefix abs (string-append bdir "/"))])
                  (and (deliverable? rel)
                       (cons (join-paths (current-machine-type) rel) abs))))
              (files-under bdir))
            '()))))

  (define (filter-map f xs)
    (fold-right (lambda (x acc) (let ([r (f x)]) (if r (cons r acc) acc))) '() xs))

  ;; 构建内部非交付物:.bake-manifest(指纹缓存)、*.wpo(WPO 中间物)不装
  (define (deliverable? rel)
    (not (or (string=? (base-name rel) ".bake-manifest")
             (string-suffix? ".wpo" rel))))

  ;; <src>/<sub> 下所有文件,返回相对 src 的路径(通用 FS 来自 (chandler fs))
  (define (rel-files-under src sub)
    (map (lambda (abs) (strip-prefix abs (string-append src "/")))
         (files-under (join-paths src sub))))

  (define (delete-if-exists p) (when (file-exists? p) (delete-file p)))

  ;; 删除因卸载而变空的目录(仅删涉及路径的祖先链中已空者,止于 libdir 边界)
  (define (prune-empty-dirs libdir rels)
    (for-each
      (lambda (rel)
        (let loop ([d (parent-dir (join-paths libdir rel))])
          (when (and (> (string-length d) (string-length libdir))
                     (file-directory? d) (dir-empty? d))
            (ignore-errors (delete-directory d))
            (loop (parent-dir d)))))
      rels))

  (define (strip-ss s) (strip-suffix s ".ss")))
