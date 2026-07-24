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
    (let ([old (getenv "CHANDLER_PREFIX")])
      (dynamic-wind
        (lambda () (putenv "CHANDLER_PREFIX" prefix))
        thunk
        (lambda () (putenv "CHANDLER_PREFIX" (or old ""))))))


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
          ;; bake install 到 lib/{src,<mt>}:源码落 lib/src/(结构同全局前缀 <prefix>/src)
          (assert-true (file-exists? (string-append (car (project-lib-pair app)) "/a.ss")))
          (assert-true (file-exists? (string-append (car (project-lib-pair app)) "/b.ss")))
          ;; lib/ 是个完整前缀:清单快照进 .chandler/<name>/(应用名由此可辨)
          (assert-true (file-exists? (join-paths (project-libdir app) ".chandler" "app" "manifest.ss")))
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
      ;; 挂 lib/ 一对 (src::obj) 即可 import 所有依赖(源码在 lib/src,Chez 按需编译)
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b" '())]
               [app (make-app (list (cons 'b b)))])
          (install app '())
          (let ([script (string-append app "/probe.ss")])
            (write-file script "(import (b)) (display b-ok)")
            (let ([r (run-capture "scheme"
                       (list "-q" "--libdirs" (libdirs->arg (list (project-lib-pair app)))
                             "--script" script))])
              (assert-string= "#t" (trim (proc-result-out r))))))))

    ;; 项目自身的 resources/ 也进前缀:lib/src/resources/<name>/ —— 部署态与
    ;; pack 里的 share/<app>/resources/ 同一形状,故应用代码只有一种拼法。
    (app-resources-land-in-project-prefix
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b" '())]
               [app (make-app (list (cons 'b b)))])
          (write-text (join-paths app "resources" "greeting.txt") "hello")
          (install app '())
          (assert-string= "hello"
            (read-file (join-paths (project-libdir app) "src" "resources" "app" "greeting.txt"))))))

    ;; resources/ 是开发期高频改动的东西:再次 sync 必须把新内容带过去
    (app-resources-resync-picks-up-edits
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b" '())]
               [app (make-app (list (cons 'b b)))]
               [src (join-paths app "resources" "greeting.txt")]
               [dst (join-paths (project-libdir app) "src" "resources" "app" "greeting.txt")])
          (write-text src "old")
          (install app '())
          (assert-string= "old" (read-file dst))
          ;; mtime 粒度:显式推进一秒,免得同秒改动被判为未变
          (run-check "sleep" '("1") '())
          (write-text src "new")
          (sync-app-prefix! app)
          (assert-string= "new" (read-file dst)))))

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
              (assert-true (file-exists? (join-paths app "vendor" "chandler" "chandler" "runtime-paths.ss")))
              (assert-true (file-exists? (join-paths app "lib" "src" "chandler" "runtime-paths.ss")))
              (assert-true (file-exists? (join-paths app "lib" (current-machine-type) "chandler" "runtime-paths.so")))
              (assert-true (file-exists? (join-paths app "lib" "src" "chandler" "base.ss")))
              ;; dev-only 的一律不来(工具不该进应用的库搜索路径)
              (assert-false (file-exists? (join-paths app "lib" "src" "chandler" "pack.ss")))
              (assert-false (file-exists? (join-paths app "lib" (current-machine-type) "chandler" "pack.so")))
              (assert-false (file-directory? (join-paths app "lib" "src" "chandler" "cli"))))))))

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
              (assert-true (file-exists? (join-paths app "vendor" "chandler" "chandler" "runtime-paths.ss"))))))))

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
          ;; vendor/ 下塞孤儿目录 → 下次 install 清理
          (let ([orphan (join-paths app "vendor/ghost")])
            (run-check "mkdir" (list "-p" orphan) '())
            (write-file (string-append orphan "/x") "junk")
            (install app '())
            (assert-false (file-directory? orphan))
            (assert-true (file-directory? (vendor-dir app 'b)))))))

    ;; designs/24 分层:bake 为带 native 的库生成 (<lib> native-loader),该库自加载;
    ;; 统一加载降级为兜底 → native-load-paths 只报「无生成 loader」的第三方库。
    (native-fallback-skips-self-loading
      (let* ([root (mktmp)]
             [obj (string-append root "/lib/" (current-machine-type))])
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

    (lock-reused-when-fresh
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b" '())]
               [app (make-app (list (cons 'b b)))])
          (install app '())
          (let ([lock-bytes (read-file (project-lock-path app))])
            ;; manifest 未改 → 二次 install lock 内容不变
            (install app '())
            (assert-string= lock-bytes (read-file (project-lock-path app)))))))))
