#!chezscheme
;;; chandler/test/selfinstall.ss --- install-self / uninstall-self 测试(对齐 bake)

(library (chandler test selfinstall)
  (export suite)
  (import (chezscheme)
          (chandler test harness)
          (chandler proc)
          (chandler cli selfinstall))

  (define repo-root (current-directory))
  (define (mktmp) (let ([r (run-capture "mktemp" '("-d"))]) (trim (proc-result-out r))))
  (define (read-file p) (if (file-exists? p) (call-with-input-file p get-string-all) ""))
  (define (trim s) (let* ([cs (string->list s)] [cs (reverse (lt (reverse (lt cs))))]) (list->string cs)))
  (define (lt cs) (cond [(null? cs) cs] [(memv (car cs) '(#\space #\tab #\return #\newline)) (lt (cdr cs))] [else cs]))
  (define (substr? s sub)
    (let ([ls (string-length s)] [lsub (string-length sub)])
      (let loop ([i 0])
        (cond [(> (+ i lsub) ls) #f]
              [(string=? sub (substring s i (+ i lsub))) #t]
              [else (loop (+ i 1))]))))

  (define-suite suite
    ;; ── prefix 解析(--prefix > --global > $HOME/.local)──
    (prefix-explicit
      (assert-string= "/opt/x" (self-prefix '((prefix . "/opt/x")))))

    (prefix-global
      (assert-string= "/usr/local" (self-prefix '((global . #t)))))

    (prefix-default-home
      ;; 默认 = <HOME>/.local(本机 HOME 存在)
      (let ([p (self-prefix '())])
        (assert-true (substr? p "/.local"))))

    ;; ── 布局:home 在 Chez 库目录、bin 平级 ──
    (layout-posix
      (assert-string= "/p/share/chez/lib" (self-home "/p"))
      (assert-string= "/p/bin" (self-bindir "/p"))
      (assert-string= "/p/bin/chandler" (self-launcher "/p")))

    ;; ── 运行时发现顺序:skiff 优先 ──
    (runtime-order-skiff-first
      (assert-string= "skiff scheme chez chez-scheme chezscheme" self-runtimes)
      ;; skiff 出现在 scheme 之前
      (let ([s self-runtimes])
        (assert-true (< (index s "skiff") (index s "scheme")))))

    ;; ── 端到端:装 → 启动器含运行时发现 → 卸 ──
    (install-uninstall-roundtrip
      (let* ([prefix (string-append (mktmp) "/opt")])
        (assert-equal 0 (cmd-install-self repo-root (list (cons 'prefix prefix))))
        ;; 库树 + 启动器 + 清单落位
        (assert-true (file-exists? (string-append prefix "/share/chez/lib/chandler.ss")))
        (assert-true (file-exists? (string-append prefix "/share/chez/lib/chandler/cli/main.sps")))
        (assert-true (file-exists? (string-append prefix "/bin/chandler")))
        (assert-true (file-exists? (self-manifest (self-home prefix))))
        ;; 启动器做运行时发现(含 skiff + fallback 列表)
        (let ([launcher (read-file (string-append prefix "/bin/chandler"))])
          (assert-true (substr? launcher "for rt in skiff scheme"))
          (assert-true (substr? launcher "command -v"))
          (assert-true (substr? launcher "--program")))
        ;; test/ 不被安装
        (assert-false (file-exists? (string-append prefix "/share/chez/lib/chandler/test/harness.ss")))
        ;; 再装报错(已装 guard)
        (assert-raises (lambda () (cmd-install-self repo-root (list (cons 'prefix prefix)))))
        ;; --force 覆盖
        (assert-equal 0 (cmd-install-self repo-root (list (cons 'prefix prefix) (cons 'force #t))))
        ;; 卸载:文件与清单皆删
        (assert-equal 0 (cmd-uninstall-self prefix (list (cons 'prefix prefix))))
        (assert-false (file-exists? (string-append prefix "/share/chez/lib/chandler.ss")))
        (assert-false (file-exists? (self-manifest (self-home prefix))))
        (assert-false (file-exists? (string-append prefix "/bin/chandler")))))
    )

  (define (index s sub)
    (let ([ls (string-length s)] [lsub (string-length sub)])
      (let loop ([i 0])
        (cond [(> (+ i lsub) ls) -1]
              [(string=? sub (substring s i (+ i lsub))) i]
              [else (loop (+ i 1))])))))
