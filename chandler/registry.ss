#!chezscheme
;;; chandler/registry.ss --- 全局安装文件清单事务(designs/05)
;;;
;;; 让 --global 安装可审计、可干净卸载、可检测冲突。注册表 = <libdir>/.chandler/registry/<name>.ss,
;;; 记已装文件 + sha256。安装事务:冲突检测 → staging → 进位 → 登记(registry 最后写 = 弱事务)。
;;; bake install 复用本库(designs/07 §5),故导出干净、不 import 上层。

(library (chandler registry)
  (export default-user-libdir default-system-libdir
          install-global uninstall-global list-global doctor-global
          registry-dir registry-file installed-files)
  (import (chezscheme)
          (chandler proc)
          (chandler layout)
          (chandler sexp)
          (chandler hash))

  (define (home) (or (getenv "HOME") (getenv "USERPROFILE") "."))
  (define (default-user-libdir)
    (join-paths (or (getenv "XDG_DATA_HOME") (join-paths (home) ".local/share"))
                "chez/lib"))
  (define (default-system-libdir) "/usr/local/share/chez/lib")

  (define (registry-dir libdir) (join-paths libdir ".chandler/registry"))
  (define (registry-file libdir name) (join-paths (registry-dir libdir) (string-append name ".ss")))
  (define (staging-dir libdir name) (join-paths libdir (string-append ".chandler/staging/" name)))

  ;; ── 安装:src(布局规范库根)→ libdir ──
  ;; meta: (name version source-datum installed-at installer) — 时钟由调用方传入
  ;; opts: (adopt . #t) (force . #t)
  (define (install-global src libdir meta opts)
    (let* ([name (car meta)]
           [files (enumerate-lib src name)])       ; 相对 src 的文件清单
      (when (null? files)
        (error 'install-global "源目录不含可安装库文件(缺 <name>.ss 与 <name>/)" src name))
      (let ([old (and (file-exists? (registry-file libdir name))
                      (installed-files (read-registry libdir name)))])
        (check-conflicts files libdir name opts)
        (let ([staging (staging-dir libdir name)])
          (rm-rf staging)
          ;; 1) 拷到 staging
          (for-each (lambda (rel)
                      (let ([s (join-paths src rel)] [d (join-paths staging rel)])
                        (ensure-parent d) (copy-file s d)))
                    files)
          ;; 2) 进位:staging → libdir
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
                                (format "文件被包 ~a 占有,拒绝覆盖:~a" owner rel))]
                  [(assq-val 'adopt opts) (void)]                    ; 收编野文件
                  [(assq-val 'force opts) (void)]
                  [else (error 'install-global
                               (format "目标已有野文件(无主),--adopt 收编或 --force:~a" rel))])))))
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
        (error 'uninstall-global "未安装该包" name libdir))
      (let* ([reg (read-registry libdir name)]
             [entries (registry-file-entries reg)])
        (for-each
          (lambda (e)
            (let* ([rel (car e)] [want (cadr e)] [target (join-paths libdir rel)])
              (when (file-exists? target)
                (if (and (string=? want (sha256-file target)))
                    (delete-file target)
                    (if (assq-val 'keep-modified opts)
                        (fprintf (current-error-port) "保留已改动文件:~a~%" rel)
                        (begin (fprintf (current-error-port) "warning: ~a 已被改动,仍删除~%" rel)
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
               (filter (lambda (e) (has-suffix? e ".ss")) (dir-entries rd)))
          '())))

  ;; ── 库文件枚举:<name>.ss + <name>/** + native/** ──
  (define (enumerate-lib src name)
    (append
      (if (file-exists? (join-paths src (string-append name ".ss")))
          (list (string-append name ".ss")) '())
      (find-rel src name)
      (find-rel src "native")))

  ;; find <src>/<sub> -type f,返回相对 src 的路径
  (define (find-rel src sub)
    (let ([base (join-paths src sub)])
      (if (file-directory? base)
          (let ([r (run-capture "find" (list base "-type" "f"))])
            (if (= 0 (proc-result-code r))
                (map (lambda (abs) (strip-prefix abs (string-append src "/")))
                     (filter (lambda (s) (> (string-length s) 0))
                             (split-nl (proc-result-out r))))
                '()))
          '())))

  ;; ── 文件工具(shell out;POSIX)──
  (define (copy-file s d) (run-check "cp" (list "-p" s d) '()))
  (define (move-file s d) (run-check "mv" (list s d) '()))
  (define (rm-rf p) (run-check "rm" (list "-rf" p) '()))
  (define (delete-if-exists p) (when (file-exists? p) (delete-file p)))
  (define (ensure-parent path) (ensure-dir (parent-dir path)))
  (define (ensure-dir dir)
    (unless (or (string=? dir "") (file-directory? dir))
      (ensure-dir (parent-dir dir))
      (guard (e [#t (void)]) (mkdir dir))))
  (define (parent-dir path)
    (let loop ([i (- (string-length path) 1)])
      (cond [(< i 0) ""]
            [(char=? #\/ (string-ref path i)) (substring path 0 i)]
            [else (loop (- i 1))])))

  ;; 删除因卸载而变空的目录(仅删涉及路径的祖先链中已空者)
  (define (prune-empty-dirs libdir rels)
    (for-each
      (lambda (rel)
        (let loop ([d (parent-dir (join-paths libdir rel))])
          (when (and (> (string-length d) (string-length libdir))
                     (file-directory? d)
                     (null? (dir-entries d)))
            (guard (e [#t (void)]) (delete-directory d))
            (loop (parent-dir d)))))
      rels))

  (define (dir-entries dir)
    (let ([r (run-capture "ls" (list "-A" dir))])
      (if (= 0 (proc-result-code r))
          (filter (lambda (s) (> (string-length s) 0)) (split-nl (proc-result-out r)))
          '())))

  ;; ── 字符串 ──
  (define (assq-val k alist) (let ([p (assq k alist)]) (and p (cdr p))))
  (define (strip-ss s) (substring s 0 (- (string-length s) 3)))
  (define (has-suffix? s suf)
    (let ([ls (string-length s)] [lf (string-length suf)])
      (and (>= ls lf) (string=? suf (substring s (- ls lf) ls)))))
  (define (strip-prefix s pre)
    (let ([lp (string-length pre)])
      (if (and (>= (string-length s) lp) (string=? pre (substring s 0 lp)))
          (substring s lp (string-length s)) s)))
  (define (split-nl s)
    (let loop ([chars (string->list s)] [cur '()] [acc '()])
      (cond
        [(null? chars) (reverse (cons (list->string (reverse cur)) acc))]
        [(char=? #\newline (car chars)) (loop (cdr chars) '() (cons (list->string (reverse cur)) acc))]
        [else (loop (cdr chars) (cons (car chars) cur) acc)]))))
