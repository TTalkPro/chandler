#!chezscheme
;;; chandler/cli/commands.ss --- 各子命令实现(designs/01)
;;;
;;; 命令函数取 (root flags),返回退出码(sysexits 风格,见 main.ss)。
;;; 依赖获取/物化归 (chandler install);解析归 (chandler resolve)。

(library (chandler cli commands)
  (export cmd-init cmd-install cmd-update cmd-verify cmd-list cmd-tree
          cmd-add cmd-remove cmd-run cmd-exec
          cmd-uninstall cmd-doctor cmd-build
          ensure-gitignore-lib skeleton-manifest-datum)
  (import (chezscheme)
          (chandler util)
          (chandler fs)
          (chandler proc)
          (chandler sexp)
          (chandler layout)
          (chandler manifest)
          (chandler lock)
          (chandler install)
          (chandler registry)
          (chandler build)
          (chandler cli args))

  ;; ── init ──
  (define (cmd-init root flags)
    (let* ([name (or (flag flags 'name) (basename root))]
           [mpath (join-paths root "manifest.ss")])
      (when (and (file-exists? mpath) (not (flag? flags 'force)))
        (error 'init "manifest.ss 已存在;--force 覆盖" mpath))
      (write-canonical-file mpath (skeleton-manifest-datum name))
      (ensure-gitignore-lib root)
      (when (flag? flags 'lib) (scaffold-lib root name))
      (printf "已生成 ~a~%" mpath)
      0))

  (define (skeleton-manifest-datum name)
    `(manifest (format 1) (name ,name) (version "0.1.0") (chez ">=10.0") (srcdir ".") (deps)))

  ;; ── install / update ──
  ;; --global:装当前项目库树到全局 libdir(注册表事务,designs/05)
  (define (cmd-install root flags)
    (if (flag? flags 'global)
        (cmd-install-global root flags)
        (install root (install-opts flags))))

  (define (cmd-install-global root flags)
    (let* ([libdir (target-libdir flags)]
           [mpath (join-paths root "manifest.ss")]
           [mf (and (file-exists? mpath) (read-manifest mpath))]
           [name (or (and mf (manifest-name mf)) (basename root))]
           [version (or (and mf (manifest-version mf)) "0.0.0")]
           [meta (list name version `(path ,root) (now-iso) 'chandler)]
           [opts (list (cons 'adopt (flag? flags 'adopt)) (cons 'force (flag? flags 'force)))])
      (install-global root libdir meta opts)
      (printf "已全局安装 ~a ~a → ~a~%" name version libdir)
      0))

  (define (cmd-uninstall root flags)
    (unless (flag? flags 'global) (error 'uninstall "仅支持 --global"))
    (let ([libdir (target-libdir flags)]
          [name (flag flags 'name)])
      (unless name (error 'uninstall "用法:chandler uninstall --global --name=<name>"))
      (uninstall-global name libdir (list (cons 'keep-modified (flag? flags 'keep-modified))))
      (printf "已卸载 ~a~%" name)
      0))

  (define (cmd-doctor root flags)
    (let* ([libdir (target-libdir flags)]
           [issues (doctor-global libdir)])
      (if (null? issues)
          (begin (printf "doctor: 全局库目录 ~a 无异常~%" libdir) 0)
          (begin
            (for-each (lambda (i) (fprintf (current-error-port) "  ~a~%" i)) issues)
            (fprintf (current-error-port) "doctor: ~a 处异常~%" (length issues))
            65))))

  (define (target-libdir flags)
    (cond
      [(flag? flags 'system) (default-system-libdir)]
      [(and (string? (flag flags 'global))) (flag flags 'global)]  ; --global=dir
      [else (default-user-libdir)]))

  ;; ISO-ish 时间戳(installed-at,纯记录)
  (define (now-iso)
    (let ([t (current-date)])
      (format "~a-~a-~aT~a:~a:~a"
              (date-year t) (pad2 (date-month t)) (pad2 (date-day t))
              (pad2 (date-hour t)) (pad2 (date-minute t)) (pad2 (date-second t)))))
  (define (pad2 n) (if (< n 10) (format "0~a" n) (format "~a" n)))

  (define (cmd-update root flags)
    ;; 删 lock 触发重解析(全量);具名 update 的增量留待细化
    (let ([lpath (project-lock-path root)])
      (when (file-exists? lpath) (delete-file lpath)))
    (install root (install-opts flags)))

  (define (install-opts flags)
    (list (cons 'production (flag? flags 'production))
          (cons 'force (flag? flags 'force))
          (cons 'keep-extra (flag? flags 'keep-extra))
          (cons 'offline (flag? flags 'offline))))

  ;; ── verify ──
  ;; ── build:排单 → bake(designs/07)──
  (define (cmd-build root flags)
    (build root (list (cons 'allow-build (flag flags 'allow-build))
                      (cons 'production (flag? flags 'production)))))

  (define (cmd-verify root flags)
    (if (verify root)
        (begin (printf "verify: lib/ 与 manifest.lock 一致~%") 0)
        (begin (fprintf (current-error-port) "verify: 不一致(见上)~%") 65)))

  ;; ── list / tree ──
  (define (cmd-list root flags)
    (if (flag? flags 'global)
        (cmd-list-global flags)
        (cmd-list-local root flags)))

  (define (cmd-list-global flags)
    (let ([rows (list-global (target-libdir flags))])
      (if (null? rows)
          (printf "(全局库目录无已装包)~%")
          (for-each (lambda (r) (printf "~a  ~a  [~a]~%" (car r) (cadr r) (caddr r))) rows))
      0))

  (define (cmd-list-local root flags)
    (let ([rows (list-deps root)])
      (if (null? rows)
          (printf "(无已锁依赖;先跑 chandler install)~%")
          (for-each
            (lambda (r)
              (printf "~a  ~a  ~a~a~%"
                      (car r) (cadr r) (caddr r)
                      (if (eq? 'dev (cadddr r)) "  [dev]" "")))
            rows))
      0))

  (define (cmd-tree root flags)
    ;; 简树:根 → 依赖(基于 lock deps 图)
    (let ([lpath (project-lock-path root)])
      (if (not (file-exists? lpath))
          (begin (printf "(无 lock)~%") 0)
          (let ([lk (read-lock lpath)])
            (printf "(root)~%")
            (for-each (lambda (d)
                        (printf "  ├─ ~a @~a~%" (locked-dep-name d)
                                (short (locked-dep-rev d)))
                        (for-each (lambda (child)
                                    (printf "  │    └─ ~a~%" child))
                                  (locked-dep-deps d)))
                      (lock-deps lk))
            0))))

  ;; ── add / remove(datum 级改写 manifest;init 生成的规范清单适用)──
  (define (cmd-add root flags positionals)
    (let ([name (and (pair? positionals) (car positionals))]
          [url  (and (pair? positionals) (pair? (cdr positionals)) (cadr positionals))])
      (unless name (error 'add "用法:chandler add <name> <git-url> [--tag/--rev/--branch]"))
      (let* ([mpath (join-paths root "manifest.ss")]
             [datum (read-datum-file mpath)]
             [dep (build-dep-sexpr (string->symbol name) url flags)]
             [datum* (add-dep datum dep)])
        (write-canonical-file mpath datum*)
        (printf "已添加依赖 ~a~%" name)
        0)))

  (define (build-dep-sexpr name url flags)
    (let ([path (flag flags 'path)])
      (if path
          `(,name (path ,path))
          (let ([src `(git ,url)]
                [pin (cond
                       [(flag flags 'tag) => (lambda (v) `(tag ,(as-str v)))]
                       [(flag flags 'rev) => (lambda (v) `(rev ,(as-str v)))]
                       [(flag flags 'branch) => (lambda (v) `(branch ,(as-str v)))]
                       [else #f])])
            (unless url (error 'add "git 依赖需 URL"))
            (if pin `(,name ,src ,pin) `(,name ,src))))))

  (define (as-str v) (if (string? v) v (format "~a" v)))

  ;; 往 manifest datum 的 (deps …) 追加一项;无 deps 则新增
  (define (add-dep datum dep)
    (let ([body (cdr datum)])
      (cons 'manifest (upsert-deps body dep))))

  (define (upsert-deps body dep)
    (let loop ([b body] [seen #f] [acc '()])
      (cond
        [(null? b)
         (reverse (if seen acc (cons `(deps ,dep) acc)))]
        [(tagged-list? (car b) 'deps)
         (loop (cdr b) #t (cons (append (car b) (list dep)) acc))]
        [else (loop (cdr b) seen (cons (car b) acc))])))

  (define (cmd-remove root flags positionals)
    (let ([name (and (pair? positionals) (string->symbol (car positionals)))])
      (unless name (error 'remove "用法:chandler remove <name>"))
      (let* ([mpath (join-paths root "manifest.ss")]
             [datum (read-datum-file mpath)]
             [datum* (cons 'manifest (remove-dep (cdr datum) name))])
        (write-canonical-file mpath datum*)
        (printf "已移除依赖 ~a(下次 install 清理 lib/)~%" name)
        0)))

  (define (remove-dep body name)
    (map (lambda (field)
           (if (or (tagged-list? field 'deps) (tagged-list? field 'dev-deps))
               (cons (car field)
                     (filter (lambda (d) (not (eq? (car d) name))) (cdr field)))
               field))
         body))

  ;; ── run / exec(designs/06 §5)──
  ;; run:组库路径 + 载 native + 跑脚本(用生成的 preamble,自包含,不需子进程有 (chandler))
  (define (cmd-run root flags positionals rest)
    (let ([script (and (pair? positionals) (car positionals))])
      (unless script (error 'run "用法:chandler run <script.ss> [args…]"))
      (let* ([dirs (library-search-dirs root)]
             [natives (native-load-paths root)]
             [preamble (make-preamble root natives (abspath root script))]
             [interp (choose-interp root flags)]
             [args (append (list "-q" "--libdirs" (path-list dirs)
                                 "--script" preamble)
                           (or rest '()) (cdr positionals))])
        (run-foreground interp args))))

  ;; exec:仅设 CHEZSCHEMELIBDIRS 后跑任意命令(给编辑器/CI)
  (define (cmd-exec root flags rest)
    (unless (and rest (pair? rest)) (error 'exec "用法:chandler exec -- <cmd…>"))
    (let ([dirs (library-search-dirs root)])
      (run-foreground (car rest) (cdr rest)
                      (list (cons 'env (list (cons "CHEZSCHEMELIBDIRS" (path-list dirs))))))))

  ;; 选解释器(designs/06 §3):--runtime 旗标 > manifest 声明 > scheme。
  ;;   --runtime skiff|chez 显式指定;否则仅 (skiff …) 无 (chez …) → skiff;其余 → scheme。
  (define (choose-interp root flags)
    (case (interp-kind root flags)
      [(skiff) (or (getenv "CHANDLER_SKIFF") "skiff")]
      [else    (or (getenv "CHANDLER_SCHEME") "scheme")]))

  (define (interp-kind root flags)
    (let ([rt (flag flags 'runtime)])
      (cond
        [(equal? rt "skiff") 'skiff]
        [(equal? rt "chez") 'chez]
        [else                                          ; 依 manifest:仅 skiff → skiff
         (let ([mpath (join-paths root "manifest.ss")])
           (if (file-exists? mpath)
               (let ([mf (read-manifest mpath)])
                 (if (and (manifest-skiff mf) (not (manifest-chez mf))) 'skiff 'chez))
               'chez))])))

  ;; 生成 preamble 临时脚本:先 load 各 native,再 load 目标脚本
  (define (make-preamble root natives script-abs)
    (let ([tmp (string-append root "/.chandler-run.ss")])
      (call-with-output-file tmp
        (lambda (p)
          (for-each (lambda (so)
                      (when (file-exists? so)
                        (fprintf p "(load-shared-object ~s)~%" so)))
                    natives)
          (fprintf p "(load ~s)~%" script-abs))
        'truncate)
      tmp))

  (define (path-list dirs) (string-join dirs ":"))

  (define (abspath root p)
    (if (string-prefix? "/" p) p (join-paths root p)))

  (define (short rev)
    (if (and (string? rev) (>= (string-length rev) 10)) (substring rev 0 10) rev))

  ;; ── .gitignore / scaffold / basename(init 用)──
  (define (ensure-gitignore-lib root)
    (let ([gi (join-paths root ".gitignore")])
      (let ([lines (read-lines gi)])            ; fs.read-lines:文件缺失 → '()
        (unless (member "lib/" (map string-trim lines))
          (call-with-output-file gi
            (lambda (p)
              (for-each (lambda (l) (display l p) (newline p)) lines)
              (display "lib/" p) (newline p))
            'truncate)))))

  (define (scaffold-lib root name)
    (let ([umbrella (join-paths root (string-append name ".ss"))]
          [subdir (join-paths root name)])
      (unless (file-exists? umbrella)
        (call-with-output-file umbrella
          (lambda (p)
            (display "#!chezscheme\n" p)
            (fprintf p ";;; ~a.ss --- umbrella facade\n\n" name)
            (fprintf p "(library (~a)\n  (export)\n  (import (chezscheme)))\n" name))
          'truncate))
      (unless (file-exists? subdir) (mkdir subdir))))

  ;; 目录路径 → 末段名(默认 "app");通用 FS/字符串来自 fs/util
  (define (basename p)
    (let ([parts (filter (lambda (s) (> (string-length s) 0)) (string-split p #\/))])
      (if (null? parts) "app" (list-ref parts (- (length parts) 1))))))
