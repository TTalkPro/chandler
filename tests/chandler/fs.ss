#!chezscheme
;;; tests/chandler/fs.ss --- (chandler fs) 测试

(library (tests chandler fs)
  (export suite)
  (import (chezscheme)
          (tests chandler harness)
          (chandler proc)
          (chandler fs))

  ;; 登记进 harness,由 run-suites 逐用例清(不用 (tests chandler fixtures) 的 mktmp:
  ;; fs 是最底层,fixtures 依赖它,引入会绕成环。这里直接登记即可)。
  (define (tmp)
    (register-test-tmp! (string-trim* (proc-result-out (run-capture "mktemp" '("-d"))))))
  (define (string-trim* s)
    (let ([n (string-length s)])
      (if (and (> n 0) (char=? #\newline (string-ref s (- n 1)))) (substring s 0 (- n 1)) s)))


  ;; 读原始字节 —— 断言必须落在**字节**上,不能落在读回的字符串上:
  ;; 若读侧也做了同样的换行变换,两个方向的 bug 会互相抵消而测不出来。
  (define (file-bytes path)
    (call-with-port (open-file-input-port path) get-bytevector-all))

  (define-suite suite
    (parent-base
      (assert-string= "/a/b" (parent-dir "/a/b/c"))
      (assert-string= "/" (parent-dir "/a"))
      (assert-string= "" (parent-dir "noslash"))
      (assert-string= "c" (base-name "/a/b/c"))
      (assert-string= "solo" (base-name "solo")))

    (ensure-and-entries
      (let* ([root (tmp)] [nested (string-append root "/x/y/z")])
        (ensure-dir nested)
        (assert-true (file-directory? nested))
        ;; 幂等
        (ensure-dir nested)
        (assert-true (file-directory? nested))
        (write-text (string-append root "/x/a.txt") "hi")
        (assert-true (member "a.txt" (dir-entries (string-append root "/x"))))
        ;; dir-entries 排序
        (write-text (string-append root "/x/b.txt") "b")
        (assert-equal '("a.txt" "b.txt" "y")
                      (dir-entries (string-append root "/x")))))

    (files-under-recursive
      (let ([root (tmp)])
        (write-text (string-append root "/a.ss") "1")
        (write-text (string-append root "/sub/b.ss") "2")
        (write-text (string-append root "/sub/deep/c.ss") "3")
        (assert-equal 3 (length (files-under root)))))

    (read-write
      (let ([p (string-append (tmp) "/f.txt")])
        (write-text p "line1\nline2\n")
        (assert-string= "line1\nline2\n" (read-file-string p))
        (assert-equal '("line1" "line2") (read-lines p))
        ;; 不存在 → 空
        (assert-string= "" (read-file-string "/no/such/file"))
        (assert-equal '() (read-lines "/no/such/file"))))

    (empty-file-not-eof
      ;; 空文件 read-file-string 返回 "" 而非 eof(曾是隐蔽 bug)
      (let ([p (string-append (tmp) "/empty")])
        (write-text p "")
        (assert-string= "" (read-file-string p))))

    (copy-and-move
      (let* ([root (tmp)] [src (string-append root "/src")] [dst (string-append root "/d/dst")])
        (write-text src "payload")
        (copy-file src dst)
        (assert-string= "payload" (read-file-string dst))
        (assert-true (file-exists? src))          ; copy 保留源
        (let ([moved (string-append root "/moved")])
          (move-file dst moved)
          (assert-string= "payload" (read-file-string moved))
          (assert-false (file-exists? dst)))))    ; move 删源

    (rm-rf-recursive
      (let ([root (tmp)])
        (write-text (string-append root "/a/b/c.txt") "x")
        (write-text (string-append root "/a/d.txt") "y")
        (rm-rf (string-append root "/a"))
        (assert-false (file-directory? (string-append root "/a")))
        ;; 幂等:删不存在的路径不报错
        (rm-rf (string-append root "/a"))))

    (sweep-empty
      (let ([root (tmp)])
        (ensure-dir (string-append root "/a/b/c"))
        (let ([f (string-append root "/a/b/c/leaf")])
          (write-text f "x") (delete-file f)
          (sweep-empty-parents f)
          ;; c/b/a 都空 → 被清到 root(root 非空? root 现空 → 也可能被清,但 root>1 且是 tmp)
          (assert-false (file-directory? (string-append root "/a/b/c"))))))

    ;; ══════════════════════════════════════════════════════════════
    ;; 换行 / 字节保真(D38)
    ;;
    ;; chandler 写出的**字节**必须与平台无关 —— lock 的 manifest-sha256 与
    ;; install/pack 的 per-file sha256 都是字节指纹,写侧一旦随平台漂移,
    ;; 跨平台协作时 verify 恒失败而文件「看起来」一模一样。
    ;; ══════════════════════════════════════════════════════════════

    ;; \n 必须原样落成单字节 0x0A,不被 transcoder 悄悄变成 \r\n
    (write-text-preserves-lf-bytes
      (let* ([root (tmp)] [f (string-append root "/lf.txt")])
        (write-text f "a\nb\n")
        (assert-equal '#vu8(97 10 98 10) (file-bytes f))))

    ;; 反向:字符串里**已有**的 \r\n 也原样落盘,不被折叠成 \n
    (write-text-preserves-crlf-bytes
      (let* ([root (tmp)] [f (string-append root "/crlf.txt")])
        (write-text f "a\r\nb\r\n")
        (assert-equal '#vu8(97 13 10 98 13 10) (file-bytes f))))

    ;; 原子写与普通写走同一条 transcoder —— 否则 lock(原子写)与其它文件
    ;; 会有两种字节行为,而 lock 恰恰是被 hash 的那个
    (write-text-atomic-preserves-bytes
      (let* ([root (tmp)] [f (string-append root "/atomic.txt")])
        (write-text-atomic f "a\nb\n")
        (assert-equal '#vu8(97 10 98 10) (file-bytes f))
        ;; 覆盖既有文件同样保真(Windows 上要先删再 rename,别把字节弄丢)
        (write-text-atomic f "c\n")
        (assert-equal '#vu8(99 10) (file-bytes f))))

    ;; write-text-crlf:唯一**有意**产生 CRLF 的入口(.cmd 启动器用)
    (write-text-crlf-converts-lf
      (let* ([root (tmp)] [f (string-append root "/x.cmd")])
        (write-text-crlf f "a\nb\n")
        (assert-equal '#vu8(97 13 10 98 13 10) (file-bytes f))))

    ;; 幂等:已经是 CRLF 的不再加一个 \r(否则重复调用会累积成 \r\r\n)
    (write-text-crlf-is-idempotent
      (let* ([root (tmp)] [f (string-append root "/y.cmd")])
        (write-text-crlf f "a\r\nb\n")
        (assert-equal '#vu8(97 13 10 98 13 10) (file-bytes f))))

    ;; 读写对称:写进去什么字符,读回来就是什么字符(含 \r)。
    ;; write-text-if-changed 的「内容没变就不写」判断依赖这条对称性。
    (text-io-roundtrips-crlf
      (let* ([root (tmp)] [f (string-append root "/rt.txt")])
        (write-text f "a\r\nb\n")
        (assert-string= "a\r\nb\n" (read-file-string f))
        ;; 内容相同 → 不重写(mtime 不变),证明比较也是按原始字符做的。
        ;; time 是记录类型,`equal?` 按标识比 —— 必须用 time=?,否则这条恒失败。
        (let ([m1 (mtime f)])
          (write-text-if-changed f "a\r\nb\n")
          (assert-true (time=? m1 (mtime f))))))))

