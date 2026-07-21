#!chezscheme
;;; chandler/test/selfinstall.ss --- install-self / uninstall-self(库经 bake install)

(library (chandler test selfinstall)
  (export suite)
  (import (chezscheme)
          (chandler test harness)
          (chandler test fixtures)
          (chandler proc)
          (chandler fs)
          (chandler cli selfinstall))

  (define repo-root (current-directory))

  ;; bake 是否可用(自安装委托它;不可用则跳过 roundtrip)
  (define (bake-ok?) (= 0 (run-status (bake-command) '("-V"))))

  (define (with-home dir thunk)               ; 临时改 HOME(bake user target 与 self-libdir 都据它)
    (let ([old (getenv "HOME")])
      (putenv "HOME" dir)
      (guard (e [#t (putenv "HOME" old) (raise e)])
        (let ([r (thunk)]) (putenv "HOME" old) r))))

  (define-suite suite
    ;; ── 落点解析(user 默认 / --global)──
    (libdir-user
      (with-home "/tmp/fake-home"
        (lambda ()
          (assert-string= "/tmp/fake-home/.local/share/chez/lib" (self-libdir '()))
          (assert-string= "/tmp/fake-home/.local/bin/chandler" (self-launcher '())))))

    (libdir-global
      (assert-string= "/usr/local/share/chez/lib" (self-libdir '((global . #t))))
      (assert-string= "/usr/local/bin/chandler" (self-launcher '((global . #t)))))

    ;; ── 运行时发现顺序:skiff 优先 ──
    (runtime-order-skiff-first
      (assert-string= "skiff scheme chez chez-scheme chezscheme" self-runtimes)
      (assert-true (< (idx self-runtimes "skiff") (idx self-runtimes "scheme"))))

    ;; ── 端到端:bake 装库 → 启动器 → 卸载(需 bake)──
    (install-via-bake-roundtrip
      (if (not (bake-ok?))
          (assert-true #t)                     ; bake 不可用:跳过(生态外环境)
          (let ([home (mktmp)])
            (with-home home
              (lambda ()
                (assert-equal 0 (cmd-install-self repo-root '()))
                (let ([libdir (string-append home "/.local/share/chez/lib")]
                      [launcher (string-append home "/.local/bin/chandler")])
                  ;; 库树经 bake install 落位(umbrella + cli 程序 + bake 清单)
                  (assert-true (file-exists? (string-append libdir "/chandler.ss")))
                  (assert-true (file-exists? (string-append libdir "/chandler/cli/main.sps")))
                  (assert-true (file-exists? (string-append libdir "/.bake-install/chandler.files")))
                  ;; 启动器:运行时发现(skiff + fallback + --program)
                  (let ([l (read-file launcher)])
                    (assert-true (substr? l "for rt in skiff scheme"))
                    (assert-true (substr? l "command -v"))
                    (assert-true (substr? l "--program")))
                  ;; 卸载:库文件 + 启动器 + bake 清单皆删
                  (assert-equal 0 (cmd-uninstall-self repo-root '()))
                  (assert-false (file-exists? (string-append libdir "/chandler.ss")))
                  (assert-false (file-exists? (string-append libdir "/.bake-install/chandler.files")))
                  (assert-false (file-exists? launcher)))))))))

  (define (idx s sub)
    (let ([ls (string-length s)] [lsub (string-length sub)])
      (let loop ([i 0])
        (cond [(> (+ i lsub) ls) -1]
              [(string=? sub (substring s i (+ i lsub))) i]
              [else (loop (+ i 1))])))))
