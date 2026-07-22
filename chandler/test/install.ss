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
          (assert-true (file-exists? (project-lock-path app)))
          (assert-true (member 'a (names app)))
          (assert-true (member 'b (names app)))
          ;; git 依赖 checkout 到 vendor/
          (assert-true (file-exists? (string-append (vendor-dir app 'a) "/a.ss")))
          (assert-true (file-exists? (string-append (vendor-dir app 'b) "/b.ss")))
          ;; bake install 到 lib/{src,<mt>}:源码落 lib/src/(结构同全局前缀 <prefix>/src)
          (assert-true (file-exists? (string-append (car (project-lib-pair app)) "/a.ss")))
          (assert-true (file-exists? (string-append (car (project-lib-pair app)) "/b.ss")))
          ;; 生成 setup + verify 通过
          (assert-true (file-exists? (join-paths app "chandler-setup.ss")))
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

    (activate-and-import-via-setup
      ;; Bundler 式:app (load chandler-setup.ss) 后 import,纯 scheme 即可
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b" '())]
               [app (make-app (list (cons 'b b)))])
          (install app '())
          (write-file (string-append app "/main.ss")
            "(load \"chandler-setup.ss\") (import (b)) (display b-ok)")
          (let ([r (run-capture "scheme" (list "-q" "--script" "main.ss")
                                (list (cons 'cwd app)))])
            (assert-string= "#t" (trim (proc-result-out r)))))))

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

    (lock-reused-when-fresh
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b" '())]
               [app (make-app (list (cons 'b b)))])
          (install app '())
          (let ([lock-bytes (read-file (project-lock-path app))])
            ;; manifest 未改 → 二次 install lock 内容不变
            (install app '())
            (assert-string= lock-bytes (read-file (project-lock-path app)))))))))
