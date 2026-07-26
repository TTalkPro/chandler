#!chezscheme
;;; tests/chandler/registry.ss --- (chandler registry) v3 测试

(library (tests chandler registry)
  (export suite)
  (import (chezscheme)
          (tests chandler harness)
          (tests chandler fixtures)
          (chandler fs)
          (chandler layout)
          (chandler registry))

  ;; 造一个布局规范库源目录 + 假编译产物:
  ;;   name.ss + name/core.ss(源)+ _build/<mt>/name/core.so
  (define (make-lib-src name)
    (let ([dir (mktmp)])
      (write-text (string-append dir "/" name ".ss")
        (format "#!chezscheme~%(library (~a) (export ok) (import (chezscheme)) (define ok #t))~%" name))
      (write-text (string-append dir "/" name "/core.ss")
        (format "#!chezscheme~%(library (~a core) (export c) (import (chezscheme)) (define c 1))~%" name))
      (write-text (string-append dir "/_build/" (current-machine-type) "/" name "/core.so") "FAKESO")
      dir))

  (define (mk-meta name version)
    (list (string->symbol name) version `(git ,(string-append "https://h/" name))
          "2026-07-21T00:00:00Z" 'chandler))

  ;; app 的 runner 由 CLI 层(write-app-launcher!)在 install 后写;
  ;; 测试直调 install-global,需补这个文件满足 switch/doctor 的 runner 验证。
  (define (add-runner! libdir name version)
    (write-text (join-paths libdir name version ".chandler" "run.sps")
                "#!chezscheme\n"))

  (define-suite suite

    ;; ── install-global:文件落位 + .registry/<name>.ss 登记 ──

    (install-writes-files-and-registry
      (let* ([libdir (mktmp)]
             [src (make-lib-src "greet")]
             [version "1.0.0"])
        (install-global src libdir (mk-meta "greet" version) version '())
        ;; v3 nested:源 → <name>/<version>/src/, 编译产物 → <name>/<version>/<mt>/
        (assert-true (file-exists? (join-paths libdir "greet" version "src" "greet.ss")))
        (assert-true (file-exists? (join-paths libdir "greet" version "src" "greet" "core.ss")))
        (assert-true (file-exists? (join-paths libdir "greet" version (current-machine-type) "greet" "core.so")))
        ;; v3:中心 .registry/<name>.ss(D16,不在 version root)
        (assert-true (file-exists? (registry-file libdir "greet")))))

    (install-registers-in-registry
      (let* ([libdir (mktmp)]
             [src (make-lib-src "greet")]
             [version "1.0.0"])
        (install-global src libdir (mk-meta "greet" version) version '())
        (let ([reg (read-registered libdir "greet")])
          (assert-true (registered? reg))
          (assert-equal 'greet (registered-name reg))
          (assert-true (registered-has-version? reg version))
          (assert-false (registered-active reg)))))   ; lib 不带 active

    (install-app-sets-active-on-first
      (let* ([libdir (mktmp)]
             [src (make-lib-src "myapp")]
             [version "1.0.0"]
             ;; entry = (myapp) → kind = app
             [meta (list 'myapp version '(path "/x") "t" 'chandler)])
        (install-global src libdir meta version '() '(myapp))
        (let ([reg (read-registered libdir "myapp")])
          (assert-equal 'app (registered-kind reg))
          (assert-string= version (registered-active reg)))))

    (install-same-version-reinstall-keeps-active
      (let* ([libdir (mktmp)]
             [src (make-lib-src "myapp")]
             [v1 "1.0.0"]
             [meta (list 'myapp v1 '(path "/x") "t" 'chandler)])
        (install-global src libdir meta v1 '() '(myapp))
        ;; 装第二个版本并设 active
        (let ([v2 "2.0.0"])
          (install-global src libdir (list 'myapp v2 '(path "/x") "t" 'chandler) v2 '() '(myapp))
          (add-runner! libdir "myapp" v2)
          ;; 手动切到 v2
          (switch-active libdir "myapp" v2)
          ;; 重装 v1 → active 不变(v2)
          (install-global src libdir meta v1 '() '(myapp))
          (let ([reg (read-registered libdir "myapp")])
            (assert-string= v2 (registered-active reg))))))

    ;; ── uninstall-global:I1 + 更新 .registry/ ──

    (uninstall-removes-vroot-and-registry-entry
      (let* ([libdir (mktmp)]
             [src (make-lib-src "gone")]
             [version "1.0.0"])
        (install-global src libdir (mk-meta "gone" version) version '())
        (assert-true (file-exists? (join-paths libdir "gone" version "src" "gone.ss")))
        (uninstall-global "gone" libdir '() version)
        ;; I1:rm -rf <vroot> 干净
        (assert-false (file-exists? (join-paths libdir "gone" version "src" "gone.ss")))
        (assert-false (file-directory? (join-paths libdir "gone" version)))
        ;; 删完最后一个 version → 整个 .registry/<name>.ss 删
        (assert-false (file-exists? (registry-file libdir "gone")))))

    (uninstall-active-clears-active
      (let* ([libdir (mktmp)]
             [src (make-lib-src "myapp")]
             [v1 "1.0.0"]
             [v2 "2.0.0"]
             [meta1 (list 'myapp v1 '(path "/x") "t" 'chandler)]
             [meta2 (list 'myapp v2 '(path "/x") "t" 'chandler)])
        (install-global src libdir meta1 v1 '() '(myapp))
        (install-global src libdir meta2 v2 '() '(myapp))
        (add-runner! libdir "myapp" v1)
        (switch-active libdir "myapp" v1)
        ;; 删 v1(active)→ active 清空
        (uninstall-global "myapp" libdir '() v1)
        (let ([reg (read-registered libdir "myapp")])
          (assert-false (registered-active reg))
          (assert-true (registered-has-version? reg v2)))))

    ;; ── switch-active:D19 ──

    (switch-changes-active
      (let* ([libdir (mktmp)]
             [src (make-lib-src "myapp")]
             [v1 "1.0.0"]
             [v2 "2.0.0"]
             [meta1 (list 'myapp v1 '(path "/x") "t" 'chandler)]
             [meta2 (list 'myapp v2 '(path "/x") "t" 'chandler)])
        (install-global src libdir meta1 v1 '() '(myapp))
        (install-global src libdir meta2 v2 '() '(myapp))
        (add-runner! libdir "myapp" v1)
        (add-runner! libdir "myapp" v2)
        ;; 初始 active = v1(首次安装设的)
        (assert-string= v1 (registered-active (read-registered libdir "myapp")))
        ;; 切到 v2
        (switch-active libdir "myapp" v2)
        (assert-string= v2 (registered-active (read-registered libdir "myapp")))
        ;; 切回 v1
        (switch-active libdir "myapp" v1)
        (assert-string= v1 (registered-active (read-registered libdir "myapp")))))

    (switch-unknown-name-errors
      (let ([libdir (mktmp)])
        (assert-raises (lambda () (switch-active libdir "nonexistent" "1.0.0")))))

    (switch-unknown-version-errors
      (let* ([libdir (mktmp)]
             [src (make-lib-src "myapp")]
             [v1 "1.0.0"]
             [meta (list 'myapp v1 '(path "/x") "t" 'chandler)])
        (install-global src libdir meta v1 '() '(myapp))
        (assert-raises (lambda () (switch-active libdir "myapp" "9.9.9")))))

    (switch-on-lib-errors
      ;; lib 没有 active 概念
      (let* ([libdir (mktmp)]
             [src (make-lib-src "mylib")]
             [v1 "1.0.0"]
             [meta (list 'mylib v1 '(path "/x") "t" 'chandler)])
        (install-global src libdir meta v1 '())   ; lib,无 entry
        (assert-raises (lambda () (switch-active libdir "mylib" v1)))))

    ;; ── list-global ──

    (list-global-empty
      (let ([libdir (mktmp)])
        (assert-equal '() (list-global libdir))))

    (list-global-single
      (let* ([libdir (mktmp)]
             [src (make-lib-src "greet")]
             [version "1.0.0"])
        (install-global src libdir (mk-meta "greet" version) version '())
        (let ([rows (list-global libdir)])
          (assert-equal 1 (length rows))
          ;; 每个 row = (name-str version-str tag installer)
          (assert-string= "greet" (car (car rows)))
          (assert-string= version (cadr (car rows))))))

    (list-global-multi-version
      (let* ([libdir (mktmp)]
             [src (make-lib-src "myapp")]
             [v1 "1.0.0"]
             [v2 "2.0.0"])
        (install-global src libdir (list 'myapp v1 '(path "/x") "t" 'chandler) v1 '() '(myapp))
        (install-global src libdir (list 'myapp v2 '(path "/x") "t" 'chandler) v2 '() '(myapp))
        (add-runner! libdir "myapp" v2)
        (switch-active libdir "myapp" v2)
        (let ([rows (list-global libdir)])
          (assert-equal 2 (length rows))
          ;; active 在前
          (assert-true (member "active" (car rows))))))

    ;; ── doctor-global ──

    (doctor-clean-on-fresh-install
      (let* ([libdir (mktmp)]
             [src (make-lib-src "doc")]
             [version "1.0.0"])
        (install-global src libdir (mk-meta "doc" version) version '())
        (assert-equal '() (doctor-global libdir))))

    (doctor-detects-missing-vroot
      (let* ([libdir (mktmp)]
             [src (make-lib-src "doc")]
             [version "1.0.0"])
        (install-global src libdir (mk-meta "doc" version) version '())
        ;; 手动删 vroot → doctor 报 missing-vroot
        (rm-rf (join-paths libdir "doc" version))
        (let ([issues (doctor-global libdir)])
          (assert-true (> (length issues) 0))
          (assert-true (member 'missing-vroot (map car issues))))))

    (doctor-detects-missing-active
      (let* ([libdir (mktmp)]
             [src (make-lib-src "myapp")]
             [version "1.0.0"])
        (install-global src libdir (list 'myapp version '(path "/x") "t" 'chandler) version '() '(myapp))
        ;; 删 vroot 但保留 .registry → active 指向不存在的 version
        (rm-rf (join-paths libdir "myapp" version))
        (let ([issues (doctor-global libdir)])
          (assert-true (member 'missing-active (map car issues))))))

    ;; ── .registry/ I/O ──

    (read-registered-missing-returns-false
      (let ([libdir (mktmp)])
        (assert-false (read-registered libdir "never-installed"))))

    (write-then-read-roundtrip
      (let* ([libdir (mktmp)]
             [reg (make-registered 'myapp 'app)]
             [ve (make-version-entry "1.0.0" "2026" '(path "/x") 'chandler)]
             [reg2 (registered-add-version reg ve)])
        (write-registered! libdir "myapp" reg2)
        (let ([back (read-registered libdir "myapp")])
          (assert-true (registered? back))
          (assert-true (registered-has-version? back "1.0.0")))))

    (remove-registered-deletes-file
      (let* ([libdir (mktmp)]
             [reg (make-registered 'myapp 'app)]
             [ve (make-version-entry "1.0.0" "2026" '(path "/x") 'chandler)]
             [reg2 (registered-add-version reg ve)])
        (write-registered! libdir "myapp" reg2)
        (assert-true (file-exists? (registry-file libdir "myapp")))
        (remove-registered! libdir "myapp")
        (assert-false (file-exists? (registry-file libdir "myapp")))))

    ;; ── staging ──

    (staging-cleaned-after-install
      (let* ([libdir (mktmp)]
             [src (make-lib-src "greet")]
             [version "1.0.0"])
        (install-global src libdir (mk-meta "greet" version) version '())
        ;; staging 应该清干净
        (assert-equal '() (stale-staging-list libdir))))

    ;; ── registry lock(per-prefix 进程锁)──

    (lock-acquire-release
      (let ([libdir (mktmp)])
        (let ([r (with-registry-lock! libdir
                   (lambda ()
                     ;; 持锁期间锁目录在
                     (assert-true (file-directory? (join-paths libdir ".registry" ".lock")))
                     42))])
          (assert-equal 42 r)
          ;; 释放后锁目录清掉
          (assert-false (file-exists? (join-paths libdir ".registry" ".lock"))))))

    (lock-released-on-error
      (let ([libdir (mktmp)])
        (assert-raises
          (lambda () (with-registry-lock! libdir (lambda () (error 'x "boom")))))
        ;; thunk 抛错,锁也释放(dynamic-wind)
        (assert-false (file-exists? (join-paths libdir ".registry" ".lock")))))

    (lock-stale-force-acquire
      (let ([libdir (mktmp)])
        (let ([ld (join-paths libdir ".registry" ".lock")])
          (ensure-dir ld)
          ;; 死 pid(超出 /proc pid 范围)+ 20 分钟前的时间戳 → 残锁,应被强抢
          (write-text (join-paths ld ".pid") "2000000000")
          (write-text (join-paths ld ".started")
                      (number->string (- (time-second (current-time)) 1200)))
          (assert-equal 'acquired (with-registry-lock! libdir (lambda () 'acquired)))
          (assert-false (file-exists? ld)))))

    ;; ── staging:两段式路径 + 整目录 promote ──

    (staging-path-dashes-no-collision
      ;; name/version 含 "-" 时,旧 "<name>-<version>" 拼接会撞;两段式不撞
      (let ([libdir "/tmp/x"])
        (assert-false
          (string=? (staging-path libdir "a-b" "c-d")
                    (staging-path libdir "a" "b-c-d")))))

    (promote-staging-basic
      (let* ([libdir (mktmp)]
             [vroot (version-root libdir "pkg" "1.0")]
             [sp (staging-path libdir "pkg" "1.0")])
        (write-text (join-paths sp "src" "pkg.ss") "CONTENT")
        (promote-staging! libdir "pkg" "1.0" vroot)
        (assert-true (file-exists? (join-paths vroot "src" "pkg.ss")))
        (assert-string= "CONTENT" (read-file (join-paths vroot "src" "pkg.ss")))
        (assert-false (file-exists? sp))))

    (promote-staging-overwrites-existing-vroot
      (let* ([libdir (mktmp)]
             [vroot (version-root libdir "pkg" "1.0")]
             [sp (staging-path libdir "pkg" "1.0")])
        ;; 旧 vroot 已在(覆盖装)
        (write-text (join-paths vroot "old.txt") "OLD")
        (write-text (join-paths sp "new.txt") "NEW")
        (promote-staging! libdir "pkg" "1.0" vroot)
        (assert-true (file-exists? (join-paths vroot "new.txt")))
        (assert-false (file-exists? (join-paths vroot "old.txt")))
        (assert-false (file-exists? sp))
        ;; backup 清干净(.old.<pid> 不残留)
        (assert-false (file-exists? (string-append vroot ".old." (number->string (get-process-id)))))))

    (promote-staging-failure-cleans-staging
      (let* ([libdir (mktmp)]
             [vroot (version-root libdir "blocker" "1.0")]
             [sp (staging-path libdir "blocker" "1.0")])
        ;; vroot 的父路径是普通文件 → rename staging → vroot 必失败(ENOTDIR)
        (write-text (join-paths libdir "blocker") "I AM A FILE")
        (write-text (join-paths sp "x.txt") "X")
        (assert-raises (lambda () (promote-staging! libdir "blocker" "1.0" vroot)))
        ;; staging 残留清掉
        (assert-false (file-exists? sp))))

    ;; ── install-global:kind 校验 + 锁下回归 ──

    (install-kind-mismatch-errors
      (let* ([libdir (mktmp)]
             [src (make-lib-src "foo")]
             [v1 "1.0.0"])
        ;; 先装 lib foo(无 entry)
        (install-global src libdir (mk-meta "foo" v1) v1 '())
        ;; 再装 app foo(带 entry)→ kind 不一致,报错
        (assert-raises
          (lambda ()
            (install-global src libdir
                            (list 'foo "2.0.0" '(path "/x") "t" 'chandler)
                            "2.0.0" '() '(foo))))
        ;; registry 仍是 lib,未被破坏
        (assert-equal 'lib (registered-kind (read-registered libdir "foo")))))

    ;; ── switch-active:vroot / runner 验证 ──

    (switch-missing-vroot-errors
      (let* ([libdir (mktmp)]
             [src (make-lib-src "myapp")]
             [v1 "1.0.0"]
             [v2 "2.0.0"])
        (install-global src libdir (list 'myapp v1 '(path "/x") "t" 'chandler) v1 '() '(myapp))
        (install-global src libdir (list 'myapp v2 '(path "/x") "t" 'chandler) v2 '() '(myapp))
        (add-runner! libdir "myapp" v1)
        (add-runner! libdir "myapp" v2)
        ;; 盘上删掉 v2 的 vroot,registry 还登记着 → 切过去报错
        (rm-rf (join-paths libdir "myapp" v2))
        (assert-raises (lambda () (switch-active libdir "myapp" v2)))))

    (switch-missing-runner-errors
      (let* ([libdir (mktmp)]
             [src (make-lib-src "myapp")]
             [v1 "1.0.0"]
             [v2 "2.0.0"])
        (install-global src libdir (list 'myapp v1 '(path "/x") "t" 'chandler) v1 '() '(myapp))
        (install-global src libdir (list 'myapp v2 '(path "/x") "t" 'chandler) v2 '() '(myapp))
        (add-runner! libdir "myapp" v1)
        ;; v2 有 vroot 但无 run.sps → 切过去报错
        (assert-raises (lambda () (switch-active libdir "myapp" v2)))))

    ;; ── doctor-global:新检测项 ──

    (doctor-detects-malformed-registry
      (let ([libdir (mktmp)])
        ;; 坏 registry:不是单个 registered datum
        (write-text (registry-file libdir "bad") "this is not a registry datum")
        (let ([issues (doctor-global libdir)])
          (assert-true (member 'malformed-registry (map car issues))))))

    (doctor-detects-orphan-vroot
      (let ([libdir (mktmp)])
        ;; 盘上有 <name>/<version>/ 但 .registry/ 没登记
        (ensure-dir (join-paths libdir "orphan" "1.0"))
        (let ([issues (doctor-global libdir)])
          (assert-true (member 'orphan-vroot (map car issues))))))

    (doctor-detects-name-filename-mismatch
      (let ([libdir (mktmp)])
        ;; .registry/foo.ss 里写 (name bar)
        (write-text (registry-file libdir "foo")
                    "(registered (format 1) (name bar) (kind lib) (versions))")
        (let ([issues (doctor-global libdir)])
          (assert-true (member 'name-filename-mismatch (map car issues))))))

    (doctor-detects-duplicate-version
      (let ([libdir (mktmp)])
        ;; 手写含重复 version 字符串的 registry
        (write-text (registry-file libdir "dup")
          "(registered (format 1) (name dup) (kind lib) (versions (\"1.0\" (installed-at \"t\") (source (path \"/x\")) (installer chandler)) (\"1.0\" (installed-at \"t\") (source (path \"/x\")) (installer chandler))))")
        (let ([issues (doctor-global libdir)])
          (assert-true (member 'duplicate-version (map car issues))))))

    (doctor-detects-missing-runner
      (let* ([libdir (mktmp)]
             [src (make-lib-src "myapp")]
             [version "1.0.0"])
        ;; app 有 vroot 但缺 .chandler/run.sps
        (install-global src libdir (list 'myapp version '(path "/x") "t" 'chandler) version '() '(myapp))
        (let ([issues (doctor-global libdir)])
          (assert-true (member 'missing-runner (map car issues))))))

    ))
