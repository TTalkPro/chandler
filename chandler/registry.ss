#!chezscheme
;;; chandler/registry.ss --- 全局安装文件清单事务(designs/06 §5) — v3 facade

(library (chandler registry)
  (export
    default-user-libdir default-system-libdir
    default-user-bindir default-system-bindir
    chandler-home
    install-global uninstall-global switch-active
    doctor-global list-global
    make-registered registered? registered-name registered-kind
    registered-versions registered-active registered-has-version?
    registered-add-version registered-remove-version registered-set-active
    registered-clear-active registered->datum datum->registered
    make-version-entry version-entry? version-entry-version
    version-entry-installed-at version-entry-source version-entry-installer
    registry-dir registry-file
    read-registered write-registered! remove-registered! registered-exists?
    list-registered-names
    staging-dir staging-path with-staging! clear-staging!
    clear-stale-staging stale-staging-list)
  (import (chezscheme)
          (chandler util)
          (chandler fs)
          (chandler layout)
          (chandler sexp)
          (chandler hash)
          (chandler registered)
          (chandler registry data)
          (chandler registry io)
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

  (define (filter-map f xs)
    (fold-right (lambda (x acc) (let ([r (f x)]) (if r (cons r acc) acc))) '() xs))

  (define (deliverable? rel)
    (not (or (string=? (base-name rel) ".bake-manifest")
             (string-suffix? ".wpo" rel))))

  (define (rel-files-under src sub)
    (map (lambda (abs) (strip-prefix abs (string-append src "/")))
         (files-under (join-paths src sub))))

  ;; ── install-global ──
  (define install-global
    (case-lambda
      [(src libdir meta version opts)
       (install-global src libdir meta version opts #f)]
      [(src libdir meta version opts entry)
       (let* ([name (car meta)]
              [name-sym (if (symbol? name) name (string->symbol name))]
              [src-name (and (pair? entry) (car entry))]
              [src-name-str (if src-name (symbol->string src-name)
                                (symbol->string name-sym))]
              [vroot (version-root libdir name-sym version)]
              [entries (enumerate-lib src src-name-str)]
              [files (map car entries)])
         (when (null? entries)
           (error 'install-global
                  "source directory has no installable library files" src name))
         (with-staging! libdir name-sym version
           (lambda ()
             (let ([sp (staging-path libdir name-sym version)])
               (for-each (lambda (e)
                           (let ([s (cdr e)] [d (join-paths sp (car e))])
                             (ensure-parent d) (copy-file s d)))
                         entries)
               (for-each (lambda (rel)
                           (let ([s (join-paths sp rel)] [d (join-paths vroot rel)])
                             (ensure-parent d)
                             (when (file-exists? d) (delete-file d))
                             (move-file s d)))
                         files))))
         (let* ([source-datum (list-ref meta 2)]
                [installed-at (list-ref meta 3)]
                [installer (list-ref meta 4)]
                [entry-ve (make-version-entry version installed-at source-datum installer)]
                [existing (or (read-registered libdir name-sym)
                              (make-registered name-sym (if entry 'app 'lib)))]
                [first-install? (not (registered-has-version? existing version))]
                [with-new (registered-add-version existing entry-ve)]
                [final-reg (if (and first-install?
                                    (eq? 'app (registered-kind with-new))
                                    (not (registered-active with-new))
                                    (alist-ref opts 'set-active #t))
                               (registered-set-active with-new version)
                               with-new)])
           (write-registered! libdir name-sym final-reg)))]))

  ;; ── uninstall-global ──
  (define uninstall-global
    (case-lambda
      [(name libdir opts)
       (error 'uninstall-global "v3 requires --version" name)]
      [(name libdir opts version)
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
         (symbol->string name-sym))]))

  ;; ── switch-active ──
  (define (switch-active libdir name version)
    (let ([name-sym (if (symbol? name) name (string->symbol name))])
      (let ([reg (or (read-registered libdir name-sym)
                     (error 'switch-active "name not registered" name))])
        (let ([new-reg (registered-set-active reg version)])
          (write-registered! libdir name-sym new-reg)))
      (symbol->string name-sym)))

  ;; ── doctor-global ──
  (define (doctor-global libdir)
    (let ([issues '()])
      (define (add! x) (set! issues (cons x issues)))
      (for-each
        (lambda (name-sym)
          (let ([reg (read-registered libdir name-sym)])
            (when reg
              (for-each
                (lambda (p)
                  (let* ([ver (car p)]
                         [vroot (version-root libdir name-sym ver)])
                    (unless (file-directory? vroot)
                      (add! (list 'missing-vroot name-sym ver)))))
                (registered-versions reg))
              (let ([active (registered-active reg)])
                (when active
                  (let ([vroot (version-root libdir name-sym active)])
                    (unless (file-directory? vroot)
                      (add! (list 'missing-active name-sym active)))))))))
        (map car (list-registered-names libdir)))
      (for-each
        (lambda (p) (add! (list 'stale-staging p)))
        (stale-staging-list libdir))
      (reverse issues)))

  ;; ── list-global ──
  ;; 返回 list of (name-str version-str tag installer-symbol)
  ;; tag = "active" 或 ""
  (define (list-global libdir)
    (apply append
           (map (lambda (name-sym)
                  (let ([reg (read-registered libdir name-sym)])
                    (if reg
                        (let ([active (registered-active reg)]
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
                                     (cons (make-row name-sym (cdar vs) "") rest))])))
                        '())))
                (map car (list-registered-names libdir)))))

  (define (make-row name-sym ve tag)
    (list (symbol->string name-sym)
          (version-entry-version ve)
          tag
          (version-entry-installer ve)))

  )
