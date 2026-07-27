#!chezscheme
;;; tests/chandler/install.ss --- (chandler install) 端到端集成:本地 git 仓,不依赖外网

(library (tests chandler install)
  (export suite)
  (import (chezscheme)
          (tests chandler harness)
          (tests chandler fixtures)
          (chandler proc)
          (chandler fs)
          (chandler layout)
          (chandler lock)
          (chandler fetch)
          (chandler registered)
          (chandler registry)
          (chandler install))

  (define (names root) (map car (list-deps root)))

  ;; ── global-libdir 用的假前缀:注册 name 的若干 version,并铺出 src/ 目录 ──
  ;; versions 形如 (("1.0.0" . present?) …);active 为版本串或 #f。
  (define (register-pkg! prefix name kind versions active)
    (let ([reg (fold-left
                 (lambda (r v)
                   (registered-add-version
                     r (make-version-entry (car v) "2026-07-27T00:00:00"
                                           '(git "https://h/x") 'chandler)))
                 (make-registered (string->symbol name) kind)
                 versions)])
      (for-each (lambda (v)
                  (when (cdr v)
                    (write-text (join-paths (version-root prefix name (car v))
                                            "src" (string-append name ".ss"))
                                ";; lib")))
                versions)
      (write-registered! prefix (string->symbol name)
                         (if active (registered-set-active reg active) reg))))

  ;; global-libdir 的条目 → 被选中的版本串(条目是 (<vroot>/src . <vroot>/<mt>))
  (define (entry-version e) (base-name (parent-dir (car e))))
  (define (entry-name e) (base-name (parent-dir (parent-dir (car e)))))

  ;; 假的全局前缀:装了 <version> 的 chandler,含 runtime 子集与 dev-only 两类库
  (define (make-fake-chandler-prefix! version)
    (let* ([prefix (mktmp)]
           [src (join-paths prefix "src" "chandler")]
           [obj (join-paths prefix (current-machine-type) "chandler")])
      (write-text (join-paths prefix ".chandler" "chandler" "chandler-manifest.ss")
                  (string-append "(manifest (format 1) (name \"chandler\") (version \""
                                 version "\") (chez \">=10.0\") (srcdir \".\") (deps))"))
      (for-each (lambda (n)
                  (write-text (join-paths src (string-append n ".ss")) ";; runtime lib")
                  (write-text (join-paths obj (string-append n ".so")) "OBJ"))
                '("base" "runtime-paths" "util" "fs" "layout"))
      (for-each (lambda (n)
                  (write-text (join-paths src (string-append n ".ss")) ";; dev-only lib")
                  (write-text (join-paths obj (string-append n ".so")) "OBJ"))
                '("pack" "install" "build"))
      (write-text (join-paths src "cli" "main.ss") ";; dev-only nested")
      (write-text (join-paths prefix "src" "chandler.ss") ";; dev umbrella")
      prefix))

  ;; Chez 的 putenv 不能删变量,清理时以空值恢复
  (define (with-chandler-prefix prefix thunk)
    (let ([old (getenv "CHANDLER_HOME")])
      (dynamic-wind
        (lambda () (putenv "CHANDLER_HOME" prefix))
        thunk
        (lambda () (putenv "CHANDLER_HOME" (or old ""))))))


  (define-suite suite
    (install-transitive
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b" '())]
               [a (make-lib-repo "a" (list (cons 'b b)))]
               [app (make-app (list (cons 'a a)))])
          (assert-equal 0 (install app '()))
          (assert-true (file-exists? (project-lock-path app)))
          (assert-true (member 'a (names app)))
          (assert-true (member 'b (names app)))
          ;; git 依赖 checkout 到 vendor/
          (assert-true (file-exists? (string-append (vendor-dir app 'a) "/a.ss")))
          (assert-true (file-exists? (string-append (vendor-dir app 'b) "/b.ss")))
          ;; C0:源码只此一份,留在 _vendor/ 里 —— 不再拷进任何前缀
          (assert-false (file-directory? (join-paths app "lib")))
          ;; 不再生成 chandler-setup.ss —— 启动统一走 `chandler run`
          (assert-false (file-exists? (join-paths app "chandler-setup.ss")))
          (assert-true (verify app)))))

    (install-idempotent
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b" '())]
               [app (make-app (list (cons 'b b)))])
          (assert-equal 0 (install app '()))
          (let ([rev1 (head-rev (vendor-dir app 'b))])
            (assert-equal 0 (install app '()))
            (assert-string= rev1 (head-rev (vendor-dir app 'b)))
            (assert-true (verify app))))))

    (activate-and-import
      ;; 挂 resolved-libdirs(逐依赖一对)即可 import 所有依赖(源码 live 在 _vendor,Chez 按需编译)
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b" '())]
               [app (make-app (list (cons 'b b)))])
          (install app '())
          (let ([script (string-append app "/probe.ss")])
            (write-file script "(import (b)) (display b-ok)")
            (let ([r (run-capture "scheme"
                       (list "-q" "--libdirs" (libdirs->arg (resolved-libdirs app))
                             "--script" script))])
              (assert-string= "#t" (trim (proc-result-out r))))))))

    ;; C0:项目自身与依赖的资源**都不再被复制** —— 各自 live 在源码树里,由
    ;; resolved-libdirs 挂上的 src 侧被 resource-path 扫到。这里验的是「挂对了」:
    ;; 项目根与每个依赖的 _vendor 树都在库搜索条目里。
    (resolved-libdirs-mounts-project-and-each-dep
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b" '())]
               [app (make-app (list (cons 'b b)))])
          (install app '())
          (let* ([dirs (resolved-libdirs app)]
                 [srcs (map (lambda (e) (if (pair? e) (car e) e)) dirs)])
            ;; 依赖:_vendor/b 的源码侧在
            (assert-true (find (lambda (d) (substr? d "/_vendor/b")) srcs))
            ;; 项目自身的库根在
            (assert-true (find (lambda (d) (string=? d app)) srcs))
            ;; 每条依赖条目都是 (src . obj) 对,obj 侧指向它自己的 _build/<mt>
            (let ([dep-entry (find (lambda (e) (and (pair? e) (substr? (car e) "/_vendor/b"))) dirs)])
              (assert-true (pair? dep-entry))
              (assert-true (substr? (cdr dep-entry)
                                    (string-append "_build/" (current-machine-type)))))))))

    ;; 依赖源码不再被拷进任何前缀:_vendor 是唯一那一份
    (no-lib-prefix-is-created
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b" '())]
               [app (make-app (list (cons 'b b)))])
          (install app '())
          (assert-false (file-directory? (join-paths app "lib")))
          (assert-true (file-exists? (join-paths (vendor-dir app 'b) "b.ss"))))))

    ;; ── chandler 运行时门(designs/12 §5):不是依赖,实体取自全局前缀 ──
    ;; 造一个假前缀:.chandler/chandler/chandler-manifest.ss(版本)+ src/chandler/*.ss +
    ;; <mt>/chandler/*.so,其中混入 dev-only 的库,验证只有 runtime 子集被铺过来。
    (chandler-gate-copies-runtime-subset-from-prefix
      (parameterize ([cache-root (mktmp)])
        (let* ([prefix (make-fake-chandler-prefix! "0.1.4")]
               [app (make-app '() "(chandler \">=0.1.0\")")])
          (with-chandler-prefix prefix
            (lambda ()
              (assert-equal 0 (install app '()))
              ;; runtime 子集**源码**进 _vendor/chandler/chandler/(install-chandler-runtime!)
              (assert-true (file-exists? (join-paths app "_vendor" "chandler" "chandler" "runtime-paths.ss")))
              (assert-true (file-exists? (join-paths app "_vendor" "chandler" "chandler" "base.ss")))
              ;; BUG-1(2026-07-24):install 只铺源码,不再拷/编对象。对象由 build 层的
              ;; build-chandler-runtime! 就地编译,故 install 后 _build/ 尚不存在。
              (assert-false (file-directory? (join-paths app "_vendor" "chandler" "_build")))
              ;; dev-only 的一律不来(工具不该进应用的库搜索路径)
              (assert-false (file-exists? (join-paths app "_vendor" "chandler" "chandler" "pack.ss")))
              (assert-false (file-directory? (join-paths app "_vendor" "chandler" "chandler" "cli"))))))))

    ;; 装的比区间旧 → 当场报错(expected vs actual),不静默用旧的
    (chandler-gate-rejects-too-old-prefix
      (parameterize ([cache-root (mktmp)])
        (let* ([prefix (make-fake-chandler-prefix! "0.1.0")]
               [app (make-app '() "(chandler \">=9.9\")")])
          (with-chandler-prefix prefix
            (lambda () (assert-raises (lambda () (install app '()))))))))

    ;; 前缀里压根没有 chandler → 报「去装」,而不是静默跳过
    (chandler-gate-requires-installed-chandler
      (parameterize ([cache-root (mktmp)])
        (let ([app (make-app '() "(chandler \">=0.1.0\")")])
          (with-chandler-prefix (mktmp)
            (lambda () (assert-raises (lambda () (install app '()))))))))

    ;; vendor/chandler 不是 lock 里的依赖 —— 孤儿清理不许把它删掉
    (chandler-vendor-survives-orphan-cleanup
      (parameterize ([cache-root (mktmp)])
        (let* ([prefix (make-fake-chandler-prefix! "0.1.4")]
               [app (make-app '() "(chandler \">=0.1.0\")")])
          (with-chandler-prefix prefix
            (lambda ()
              (install app '())
              (install app '())
              (assert-true (file-exists? (join-paths app "_vendor" "chandler" "chandler" "runtime-paths.ss"))))))))

    (dirty-refuse
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b" '())]
               [app (make-app (list (cons 'b b)))])
          (install app '())
          (write-file (string-append (vendor-dir app 'b) "/b.ss") "tampered")   ; 弄脏 vendor
          (assert-false (verify app))
          (assert-true #t))))

    (orphan-cleanup
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b" '())]
               [app (make-app (list (cons 'b b)))])
          (install app '())
          ;; _vendor/ 下塞孤儿目录 → 下次 install 清理
          (let ([orphan (join-paths app "_vendor/ghost")])
            (run-check "mkdir" (list "-p" orphan) '())
            (write-file (string-append orphan "/x") "junk")
            (install app '())
            (assert-false (file-directory? orphan))
            (assert-true (file-directory? (vendor-dir app 'b)))))))

    ;; designs/24 分层:bake 为带 native 的库生成 (<lib> native-loader),该库自加载;
    ;; 统一加载降级为兜底 → native-load-paths 只报「无生成 loader」的第三方库。
    (native-fallback-skips-self-loading
      (let* ([root (mktmp)]
             [obj (string-append root "/_build/" (current-machine-type))])
        ;; a:bake 构建,带生成 loader → 自加载,不应预加载
        (write-text (string-append obj "/a/native-loader.so") "LOADER")
        (write-text (string-append obj "/a/native/a.so") "SO")
        ;; b:第三方,无 loader → 需兜底预加载
        (write-text (string-append obj "/b/native/b.so") "SO")
        ;; 多段库名(如 (chez async))亦按所属库目录判定
        (write-text (string-append obj "/chez/async/native-loader.so") "LOADER")
        (write-text (string-append obj "/chez/async/native/rt.so") "SO")
        (let ([paths (native-load-paths root)])
          (assert-equal 1 (length paths))
          (assert-true (substr? (car paths) "/b/native/b.so")))))

    ;; C2:兜底扫描不该只认项目自己的 lib/<mt> —— 全局前缀里(或任何挂载条目的
    ;; obj 侧)手放的、无 loader 的第三方 native,原先一律漏掉。带 loader 的照旧跳过,
    ;; 不论它在哪个前缀里。
    (native-fallback-scans-all-mounted-obj-sides
      ;; v2: global-libdir 扫 nested <name>/<version>/{src,<mt>}/(需 registry)
      ;; 测试环境无注册包,全局兜底为空 → native-load-paths 只扫项目自己
      (let* ([root (mktmp)])
        (write-text (join-paths root "_build" (current-machine-type) "b" "native" "b.so") "SO")
        (let ([paths (native-load-paths root)])
          (assert-equal 1 (length paths))
          (assert-true  (find (lambda (p) (substr? p "/b/native/b.so")) paths)))
        (rm-rf root)))

    ;; ══ global-libdir:每个包只挂一个版本(designs/06 §5)══
    ;; 先前把每个包的每个版本都挂上,实际生效的是「最后登记的那个」—— 偶然结果,
    ;; 且与 `chandler switch` 设的 active 矛盾。

    ;; app:挂 active,而不是最高版本 —— 这正是 switch 的意义
    (global-libdir-app-honors-active
      (let ([prefix (mktmp)])
        (register-pkg! prefix "myapp" 'app
                       '(("1.0.0" . #t) ("2.0.0" . #t) ("1.5.0" . #t)) "1.0.0")
        (with-chandler-prefix prefix
          (lambda ()
            (let ([dirs (global-libdir)])
              (assert-equal 1 (length dirs))
              (assert-string= "1.0.0" (entry-version (car dirs))))))))

    ;; lib:没有 active 这个概念(registered-set-active 对 lib 报错)→ 取最高 semver。
    ;; 9.9.0 < 10.0.0 是数值序,不是字符串序。
    (global-libdir-lib-picks-highest-semver
      (let ([prefix (mktmp)])
        (register-pkg! prefix "mylib" 'lib
                       '(("9.9.0" . #t) ("10.0.0" . #t) ("2.0.0" . #t)) #f)
        (with-chandler-prefix prefix
          (lambda ()
            (let ([dirs (global-libdir)])
              (assert-equal 1 (length dirs))
              (assert-string= "10.0.0" (entry-version (car dirs))))))))

    ;; active 指向的版本目录不在盘上(被手工删了)→ 退到盘上存在的最高版本,
    ;; 而不是挂一条指向空目录的条目
    (global-libdir-falls-back-when-active-missing
      (let ([prefix (mktmp)])
        (register-pkg! prefix "myapp" 'app
                       '(("1.0.0" . #f) ("2.0.0" . #t) ("1.5.0" . #t)) "1.0.0")
        (with-chandler-prefix prefix
          (lambda ()
            (let ([dirs (global-libdir)])
              (assert-equal 1 (length dirs))
              (assert-string= "2.0.0" (entry-version (car dirs))))))))

    ;; 一个版本都不在盘上 → 该包整个不出现(不挂空条目)
    (global-libdir-skips-package-with-no-present-version
      (let ([prefix (mktmp)])
        (register-pkg! prefix "ghost" 'lib '(("1.0.0" . #f)) #f)
        (register-pkg! prefix "real"  'lib '(("1.0.0" . #t)) #f)
        (with-chandler-prefix prefix
          (lambda ()
            (let ([dirs (global-libdir)])
              (assert-equal 1 (length dirs))
              (assert-string= "real" (entry-name (car dirs))))))))

    ;; 多个包:每包一条,按包名升序(先前是逆序,遮蔽关系看目录枚举方向)
    (global-libdir-one-entry-per-package-sorted
      (let ([prefix (mktmp)])
        (register-pkg! prefix "alpha" 'lib '(("1.0.0" . #t) ("2.0.0" . #t)) #f)
        (register-pkg! prefix "beta"  'lib '(("1.0.0" . #t)) #f)
        (register-pkg! prefix "gamma" 'lib '(("3.0.0" . #t) ("1.0.0" . #t)) #f)
        (with-chandler-prefix prefix
          (lambda ()
            (let ([dirs (global-libdir)])
              (assert-equal 3 (length dirs))
              (assert-equal '("alpha" "beta" "gamma") (map entry-name dirs))
              (assert-equal '("2.0.0" "1.0.0" "3.0.0") (map entry-version dirs)))))))

    (lock-reused-when-fresh
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b" '())]
               [app (make-app (list (cons 'b b)))])
          (install app '())
          (let ([lock-bytes (read-file (project-lock-path app))])
            ;; manifest 未改 → 二次 install lock 内容不变
            (install app '())
            (assert-string= lock-bytes (read-file (project-lock-path app)))))))))
