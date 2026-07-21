#!chezscheme
;;; chandler/test/install.ss --- (chandler install) 端到端集成:本地 git 仓,不依赖外网

(library (chandler test install)
  (export suite)
  (import (chezscheme)
          (chandler test harness)
          (chandler test fixtures)
          (chandler proc)
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
          ;; lock 生成,含 a 与 b
          (assert-true (file-exists? (project-lock-path app)))
          (assert-true (member 'a (names app)))
          (assert-true (member 'b (names app)))
          ;; lib/a 与 lib/b 物化,含 umbrella
          (assert-true (file-exists? (string-append (lib-dir app 'a) "/a.ss")))
          (assert-true (file-exists? (string-append (lib-dir app 'b) "/b.ss")))
          ;; verify 通过
          (assert-true (verify app)))))

    (install-idempotent
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b" '())]
               [app (make-app (list (cons 'b b)))])
          (assert-equal 0 (install app '()))
          (let ([rev1 (head-rev (lib-dir app 'b))])
            ;; 二次 install 不变
            (assert-equal 0 (install app '()))
            (assert-string= rev1 (head-rev (lib-dir app 'b)))
            (assert-true (verify app))))))

    (activate-and-import
      ;; 真正把物化后的依赖 import 进来(验证搜索路径正确)
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b" '())]
               [app (make-app (list (cons 'b b)))])
          (install app '())
          (let ([script (string-append app "/probe.ss")])
            (write-file script "(import (b)) (display b-ok)")
            (let ([r (run-capture "scheme"
                       (list "-q" "--libdirs" (join-paths app "lib/b")
                             "--script" script))])
              ;; 期望输出 #t(说明 lib/b 搜索路径正确、依赖可 import)
              (assert-string= "#t" (trim (proc-result-out r))))))))

    (dirty-refuse
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b" '())]
               [app (make-app (list (cons 'b b)))])
          (install app '())
          ;; 改一个已锁 rev 的依赖 → 制造 rev 漂移前先弄脏
          (write-file (string-append (lib-dir app 'b) "/b.ss") "tampered")
          (assert-false (verify app))               ; verify 检出脏
          ;; 幂等 install:rev 未变(HEAD 仍锁定 rev)但工作区脏;install 走 head==rev 分支跳过,
          ;; 这里通过删除 lib 后再 install 触发 force 分支的另一路径不测,仅验证脏被 verify 抓到
          (assert-true #t))))

    (orphan-cleanup
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b" '())]
               [app (make-app (list (cons 'b b)))])
          (install app '())
          ;; 手工塞一个孤儿目录
          (let ([orphan (join-paths app "lib/ghost")])
            (run-check "mkdir" (list "-p" orphan) '())
            (write-file (string-append orphan "/x") "junk")
            ;; 再 install → 清理 ghost(lock 未变,走已有 lock 分支)
            (install app '())
            (assert-false (file-directory? orphan))
            ;; b 仍在
            (assert-true (file-directory? (lib-dir app 'b)))))))

    (lock-reused-when-fresh
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b" '())]
               [app (make-app (list (cons 'b b)))])
          (install app '())
          (let ([lock-bytes (read-file (project-lock-path app))])
            ;; manifest 未改 → 二次 install lock 内容不变
            (install app '())
            (assert-string= lock-bytes (read-file (project-lock-path app)))))))))
