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

    ;; 项目自身的 resources/ 也进前缀:lib/share/<name>/resources/ —— 部署态与
    ;; pack 里的 share/<app>/resources/ 同一形状,故应用代码只有一种拼法。
    (app-resources-land-in-project-prefix
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b" '())]
               [app (make-app (list (cons 'b b)))])
          (write-text (join-paths app "resources" "greeting.txt") "hello")
          (install app '())
          (assert-string= "hello"
            (read-file (join-paths (project-libdir app) "share" "app" "resources" "greeting.txt"))))))

    ;; resources/ 是开发期高频改动的东西:再次 sync 必须把新内容带过去
    (app-resources-resync-picks-up-edits
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b" '())]
               [app (make-app (list (cons 'b b)))]
               [src (join-paths app "resources" "greeting.txt")]
               [dst (join-paths (project-libdir app) "share" "app" "resources" "greeting.txt")])
          (write-text src "old")
          (install app '())
          (assert-string= "old" (read-file dst))
          ;; mtime 粒度:显式推进一秒,免得同秒改动被判为未变
          (run-check "sleep" '("1") '())
          (write-text src "new")
          (sync-app-prefix! app)
          (assert-string= "new" (read-file dst)))))

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
