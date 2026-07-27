#!chezscheme
;;; chandler/registry.ss --- 全局安装文件清单事务(designs/06 §5) — v3 facade

(library (chandler registry)
  (export
    default-user-libdir default-system-libdir
    default-user-bindir default-system-bindir
    chandler-home
    install-global uninstall-global switch-active
    install-payload-global
    doctor-global list-global
    make-registered registered? registered-name registered-kind
    registered-versions registered-active registered-has-version?
    registered-add-version registered-remove-version registered-set-active
    registered-clear-active registered->datum datum->registered
    make-version-entry version-entry? version-entry-version
    version-entry-installed-at version-entry-source version-entry-installer
    registry-dir registry-file
    read-registered write-registered! remove-registered!
    list-registered list-registered-names list-registry-files
    with-registry-lock!
    staging-dir staging-path with-staging!
    stale-staging-list promote-staging!)
  (import (chezscheme)
          (chandler util)
          (chandler fs)
          (chandler layout)
          (chandler sexp)
          (chandler hash)
          (chandler registered)
          (chandler registry data)
          (chandler registry io)
          (chandler registry lock)
          (chandler registry staging))

  ;; ── 路径 ──
  (define (win?) (windows-mt? (current-machine-type)))

  (define (default-user-libdir)
    (if (win?)
        (join-paths (or (getenv* "LOCALAPPDATA") (home-dir)) "chez")
        (string-append (home-dir) "/.local/share/chez")))

  (define (default-system-libdir)
    (if (win?)
        (join-paths (or (getenv* "ProgramData") "C:/ProgramData") "chez")
        "/usr/local/chez"))

  (define (default-user-bindir)
    (if (win?)
        (join-paths (default-user-libdir) "bin")
        (string-append (home-dir) "/.local/bin")))

  (define (default-system-bindir)
    (if (win?)
        (join-paths (default-system-libdir) "bin")
        "/usr/local/bin"))

  (define (chandler-home)
    (or (getenv* "CHANDLER_HOME") (default-user-libdir)))

  ;; ── 文件枚举(v3:沿用 v2 的 enumerate-lib)──
  (define (enumerate-lib src name-str)
    (let ([name-str (if (symbol? name-str) (symbol->string name-str) name-str)])
      (append
        (let ([srcs (append
                      (if (file-exists? (join-paths src (string-append name-str ".ss")))
                          (list (string-append name-str ".ss")) '())
                      (rel-files-under src name-str))])
          (map (lambda (rel) (cons (join-paths "src" rel) (join-paths src rel))) srcs))
        (let ([bdir (join-paths src "_build" (current-machine-type))])
          (if (file-directory? bdir)
              (filter-map
                (lambda (abs)
                  (let ([rel (strip-prefix abs (string-append bdir "/"))])
                    (and (deliverable? rel)
                         (cons (join-paths (current-machine-type) rel) abs))))
                (files-under bdir))
              '())))))

  (define (deliverable? rel)
    (not (or (string=? (base-name rel) ".bake-manifest")
             (string-suffix? ".wpo" rel))))

  (define (rel-files-under src sub)
    (map (lambda (abs) (strip-prefix abs (string-append src "/")))
         (files-under (join-paths src sub))))

  ;; ── install-global ──
  ;; 整段包在 per-prefix 锁里:staging promote + registry read-modify-write 是一个事务。
  (define install-global
    (case-lambda
      [(src libdir meta version opts)
       (install-global src libdir meta version opts #f)]
      [(src libdir meta version opts entry)
       (with-registry-lock! libdir
         (lambda ()
           (let* ([name (car meta)]
                  [name-sym (if (symbol? name) name (string->symbol name))]
                  [src-name (and (pair? entry) (car entry))]
                  [src-name-str (if src-name (symbol->string src-name)
                                    (symbol->string name-sym))]
                  [vroot (version-root libdir name-sym version)]
                  [entries (enumerate-lib src src-name-str)]
                  [existing0 (read-registered libdir name-sym)]
                  [incoming-kind (if entry 'app 'lib)])
             (when (null? entries)
               (error 'install-global
                      "source directory has no installable library files" src name))
             ;; kind 校验:registry 已存在时,incoming kind 必须与已登记的一致,
             ;; 否则 app 记进 lib registry(或反之),永远无法 active
             (when (and existing0 (not (eq? incoming-kind (registered-kind existing0))))
               (error 'install-global
                      (format "kind mismatch: registry has ~a, incoming is ~a"
                              (registered-kind existing0) incoming-kind)
                      name-sym))
             (with-staging! libdir name-sym version
               (lambda ()
                 (let ([sp (staging-path libdir name-sym version)])
                   (for-each (lambda (e)
                               (let ([s (cdr e)] [d (join-paths sp (car e))])
                                 (ensure-parent d) (copy-file s d)))
                             entries)
                   ;; 整目录单次 rename 落位(原子;覆盖装走 backup 回滚)
                   (promote-staging! libdir name-sym version vroot))))
             (let* ([source-datum (list-ref meta 2)]
                    [installed-at (list-ref meta 3)]
                    [installer (list-ref meta 4)]
                    [entry-ve (make-version-entry version installed-at source-datum installer)]
                    [existing (or existing0 (make-registered name-sym incoming-kind))]
                    [first-install? (not (registered-has-version? existing version))]
                    [with-new (registered-add-version existing entry-ve)]
                    [final-reg (if (and first-install?
                                        (eq? 'app (registered-kind with-new))
                                        (not (registered-active with-new))
                                        (alist-ref opts 'set-active #t))
                                   (registered-set-active with-new version)
                                   with-new)])
               (write-registered! libdir name-sym final-reg)))))]))

  ;; ── install-payload-global:只铺文件,不写 .registry/、不走 staging ──
  ;; 用于可再分发前缀(pack 的 share/chez):注册表是安装机私有状态(且含构建机
  ;; 绝对路径 source),不该进包;pack 目录全新,也不需要 staging 的原子性。
  ;; 文件集与 install-global 完全相同(同一 enumerate-lib),保证 payload 字节级一致。
  (define (install-payload-global src libdir name version entry)
    (let* ([name-sym (if (symbol? name) name (string->symbol name))]
           [src-name (and (pair? entry) (car entry))]
           [src-name-str (if src-name (symbol->string src-name)
                             (symbol->string name-sym))]
           [vroot (version-root libdir name-sym version)]
           [entries (enumerate-lib src src-name-str)])
      (when (null? entries)
        (error 'install-payload-global
               "source directory has no installable library files" src name))
      (for-each (lambda (e)
                  (let ([s (cdr e)] [d (join-paths vroot (car e))])
                    (ensure-parent d)
                    (when (file-exists? d) (delete-file d))
                    (copy-file s d)))
                entries)))

  ;; ── uninstall-global ──
  (define uninstall-global
    (case-lambda
      [(name libdir opts)
       (error 'uninstall-global "v3 requires --version" name)]
      [(name libdir opts version)
       (with-registry-lock! libdir
         (lambda ()
           (let* ([name-sym (if (symbol? name) name (string->symbol name))]
                  [reg (or (read-registered libdir name-sym)
                           (error 'uninstall-global "package not registered" name))]
                  [vroot (version-root libdir name-sym version)])
             (rm-rf vroot)
             (let* ([after-remove (registered-remove-version reg version)]
                    [remaining (registered-versions after-remove)])
               (if (null? remaining)
                   (remove-registered! libdir name-sym)
                   (write-registered! libdir name-sym after-remove)))
             (symbol->string name-sym))))]))

  ;; ── switch-active ──
  ;; 锁内完成 read-modify-write;切前验证目标 version 真在盘上 ——
  ;; 切到已删的 vroot / 缺 runner 的 app,switch 成功但启动即崩。
  (define (switch-active libdir name version)
    (with-registry-lock! libdir
      (lambda ()
        (let ([name-sym (if (symbol? name) name (string->symbol name))])
          (let ([reg (or (read-registered libdir name-sym)
                         (error 'switch-active "name not registered" name))])
            (unless (registered-has-version? reg version)
              (error 'switch-active "version not installed; install it first"
                     name version))
            (let ([vroot (version-root libdir name-sym version)])
              (unless (file-directory? vroot)
                (error 'missing-vroot "version root not on disk" name version))
              (when (eq? 'app (registered-kind reg))
                (unless (file-exists? (join-paths vroot ".chandler" "run.sps"))
                  (error 'missing-runner "app runner not on disk (.chandler/run.sps)"
                         name version))))
            (write-registered! libdir name-sym (registered-set-active reg version)))
          (symbol->string name-sym)))))

  ;; ── doctor-global ──
  ;; 直扫 .registry/*.ss(list-registry-files,不解析不过滤),逐个自己解析 ——
  ;; 坏文件必须变成 malformed-registry issue,不能被 list-registered-names 剔掉。
  (define (doctor-global libdir)
    (let ([issues '()]
          [parsed '()])   ; ((name-sym . registered) ...) 成功解析的,orphan 检测用
      (define (add! x) (set! issues (cons x issues)))
      ;; ── 逐 registry 文件 ──
      (for-each
        (lambda (nf)
          (let ([file-name (car nf)] [path (cdr nf)])
            (guard (e [else
                       (add! (list 'malformed-registry path (condition-brief e)))])
              (let ([reg (read-registered libdir file-name)])
                (set! parsed (cons (cons file-name reg) parsed))
                ;; name 与文件名必须一致(.registry/foo.ss ↔ (name foo))
                (unless (eq? (registered-name reg) file-name)
                  (add! (list 'name-filename-mismatch file-name (registered-name reg))))
                ;; version 字符串无重复(本 Chez 的 member 无 comparator 参数,用 memp)
                (let loop ([vs (map car (registered-versions reg))] [seen '()])
                  (cond
                    [(null? vs) (void)]
                    [(memp (lambda (s) (string=? s (car vs))) seen)
                     (add! (list 'duplicate-version file-name (car vs)))]
                    [else (loop (cdr vs) (cons (car vs) seen))]))
                ;; 每个 version:vroot 在盘上;app 还要有 runner
                (for-each
                  (lambda (p)
                    (let* ([ver (car p)]
                           [vroot (version-root libdir file-name ver)])
                      (if (not (file-directory? vroot))
                          (add! (list 'missing-vroot file-name ver))
                          (when (eq? 'app (registered-kind reg))
                            (unless (file-exists? (join-paths vroot ".chandler" "run.sps"))
                              (add! (list 'missing-runner file-name ver)))))))
                  (registered-versions reg))
                ;; active 的 vroot 必须在
                (let ([active (registered-active reg)])
                  (when (and active
                             (not (file-directory? (version-root libdir file-name active))))
                    (add! (list 'missing-active file-name active))))))))
        (list-registry-files libdir))
      ;; ── orphan-vroot:盘上有 <libdir>/<name>/<version>/ 但 registry 未登记 ──
      (for-each
        (lambda (entry)
          (let ([name-dir (join-paths libdir entry)])
            (when (and (file-directory? name-dir)
                       (not (string=? entry ".registry")))
              (let ([hit (assoc (string->symbol entry) parsed)])
                ;; registry 文件存在但 malformed → 不知道登记了啥,跳过(已报 malformed);
                ;; 无 registry 文件 → 该 name 下所有 version 目录都是 orphan
                (when (or hit (not (file-exists? (registry-file libdir entry))))
                  (let ([registered-vers
                         (if hit (map car (registered-versions (cdr hit))) '())])
                    (for-each
                      (lambda (vdir)
                        (when (and (file-directory? (join-paths name-dir vdir))
                                   (not (memp (lambda (s) (string=? s vdir))
                                              registered-vers)))
                          (add! (list 'orphan-vroot (string->symbol entry) vdir))))
                      (dir-entries name-dir))))))))
        (dir-entries libdir))
      ;; ── stale staging ──
      (for-each
        (lambda (p) (add! (list 'stale-staging p)))
        (stale-staging-list libdir))
      (reverse issues)))

  (define (condition-brief e)
    (if (and (condition? e) (message-condition? e))
        (condition-message e)
        "unreadable registry file"))

  ;; ── list-global ──
  ;; 返回 list of (name-str version-str tag installer-symbol)
  ;; tag = "active" 或 ""
  ;; list-registered 已经解析好记录,不再逐 name 重读一遍注册表文件。
  (define (list-global libdir)
    (apply append
           (map (lambda (p)
                  (let* ([name-sym (car p)]
                         [reg (cdr p)]
                         [active (registered-active reg)]
                         [versions (registered-versions reg)])
                    ;; 拆分:active 排第一,其余按注册序
                    (let loop ([vs versions] [active-row #f] [rest '()])
                      (cond
                        [(null? vs)
                         (let ([rest-rows (reverse rest)])
                           (if active-row
                               (cons active-row rest-rows)
                               rest-rows))]
                        [(and active (string=? (caar vs) active))
                         (loop (cdr vs) (make-row name-sym (cdar vs) "active") rest)]
                        [else
                         (loop (cdr vs) active-row
                               (cons (make-row name-sym (cdar vs) "") rest))]))))
                (list-registered libdir))))

  (define (make-row name-sym ve tag)
    (list (symbol->string name-sym)
          (version-entry-version ve)
          tag
          (version-entry-installer ve)))

  )
