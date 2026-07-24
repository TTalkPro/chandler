#!chezscheme
;;; chandler/test/install.ss --- (chandler install) 端到端集成:本地 git 仓,不依赖外网

(library (chandler test install)
  (export suite)
  (import (chezscheme)
          (chandler test harness)
          (chandler test fixtures)
          (chandler proc)
          (chandler fs)
          (chandler layout)
          (chandler lock)
          (chandler fetch)
          (chandler install))

  (define (names root) (map car (list-deps root)))

  ;; 假的全局前缀:装了 <version> 的 chandler,含 runtime 子集与 dev-only 两类库
  (define (make-fake-chandler-prefix! version)
    (let* ([prefix (mktmp)]
           [src (join-paths prefix "src" "chandler")]
           [obj (join-paths prefix (current-machine-type) "chandler")])
      (write-text (join-paths prefix ".chandler" "chandler" "manifest.ss")
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
    ;; 造一个假前缀:.chandler/chandler/manifest.ss(版本)+ src/chandler/*.ss +
    ;; <mt>/chandler/*.so,其中混入 dev-only 的库,验证只有 runtime 子集被铺过来。
    (chandler-gate-copies-runtime-subset-from-prefix
      (parameterize ([cache-root (mktmp)])
        (let* ([prefix (make-fake-chandler-prefix! "0.1.4")]
               [app (make-app '() "(chandler \">=0.1.0\")")])
          (with-chandler-prefix prefix
            (lambda ()
              (assert-equal 0 (install app '()))
              ;; runtime 子集:源码进 vendor/ 与 lib/src,对象进 lib/<mt>
              ;; C0:源码就地在 _vendor/chandler/chandler/,对象摆进它自己的 _build/<mt>/
              (assert-true (file-exists? (join-paths app "_vendor" "chandler" "chandler" "runtime-paths.ss")))
              (assert-true (file-exists? (join-paths app "_vendor" "chandler" "chandler" "base.ss")))
              (assert-true (file-exists? (join-paths app "_vendor" "chandler" "_build"
                                                    (current-machine-type) "chandler" "runtime-paths.so")))
              ;; dev-only 的一律不来(工具不该进应用的库搜索路径)
              (assert-false (file-exists? (join-paths app "_vendor" "chandler" "chandler" "pack.ss")))
              (assert-false (file-exists? (join-paths app "_vendor" "chandler" "_build"
                                                    (current-machine-type) "chandler" "pack.so")))
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
      (let* ([root (mktmp)]
             [prefix (mktmp)]
             [pobj (join-paths prefix (current-machine-type))]
             [old (getenv "CHANDLER_HOME")])
        (write-text (join-paths root "_build" (current-machine-type) "b" "native" "b.so") "SO")
        (write-text (join-paths pobj "g" "native" "g.so") "SO")
        (write-text (join-paths pobj "h" "native-loader.so") "LOADER")
        (write-text (join-paths pobj "h" "native" "h.so") "SO")
        (dynamic-wind
          (lambda () (putenv "CHANDLER_HOME" prefix))
          (lambda ()
            (let ([paths (native-load-paths root)])
              (assert-equal 2 (length paths))
              (assert-true  (find (lambda (p) (substr? p "/b/native/b.so")) paths))
              (assert-true  (find (lambda (p) (substr? p "/g/native/g.so")) paths))
              (assert-false (find (lambda (p) (substr? p "/h/native/h.so")) paths))))
          (lambda ()
            (putenv "CHANDLER_HOME" (or old ""))
            (rm-rf root) (rm-rf prefix)))))

    (lock-reused-when-fresh
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b" '())]
               [app (make-app (list (cons 'b b)))])
          (install app '())
          (let ([lock-bytes (read-file (project-lock-path app))])
            ;; manifest 未改 → 二次 install lock 内容不变
            (install app '())
            (assert-string= lock-bytes (read-file (project-lock-path app)))))))))
