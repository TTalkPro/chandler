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

    ;; ══════════════════════════════════════════════════════════════
    ;; 反斜杠路径(D36)
    ;;
    ;; Chez 在 Windows 上返回反斜杠形路径(current-directory /
    ;; library-object-filename / directory-list)。只认 `/` 的原语不会崩,
    ;; 只会**悄悄给出错误答案** —— 下面每条都是那类静默错误的定位点。
    ;; ══════════════════════════════════════════════════════════════

    (parent-base-backslash
      (assert-string= "C:\\a\\b" (parent-dir "C:\\a\\b\\c"))
      (assert-string= "foo.ss" (base-name "C:\\proj\\foo.ss"))
      ;; 混合分隔符(我们自己拼的 `/` 接上 Chez 给的 `\`)
      (assert-string= "x" (base-name "C:/proj\\x"))
      (assert-string= "C:/proj" (parent-dir "C:/proj\\x")))

    ;; "C:/foo" 的父目录是 C 盘的**根**("C:/"),不是 "C:" ——
    ;; 后者是 drive-relative 的「当前目录」,含义完全不同,ensure-dir 会往那上面递归
    (parent-dir-of-drive-root
      (assert-string= "C:/" (parent-dir "C:/foo"))
      (assert-string= "C:\\" (parent-dir "C:\\foo")))

    (path-join-respects-backslash-tail
      ;; a 已以分隔符收尾(两种都算)就不再补
      (assert-string= "C:\\a\\b" (path-join* "C:\\a\\" "b"))
      (assert-string= "C:/a/b" (path-join* "C:/a/" "b"))
      (assert-string= "C:\\a/b" (path-join* "C:\\a" "b")))

    ;; **本次 Windows 工作里危害最大的一处**:认不出 `_build` / `.git` 段时
    ;; unmanaged-path? 恒假,install 清单与 chandler verify 会把生成物和
    ;; 仓库元数据当成受管文件收进去 —— 全程不报错。
    (path-segments-and-unmanaged-with-backslash
      (assert-true (path-has-segment? "a\\_build\\x.so" '("_build")))
      (assert-true (path-has-segment? "C:\\proj\\.git\\config" '(".git")))
      (assert-true (path-has-segment? "a/_build\\x" '("_build")))     ; 混合
      (assert-false (path-has-segment? "a\\_buildx\\y" '("_build"))) ; 整段才算
      (assert-true (unmanaged-path? "_vendor\\g\\_build\\o.so"))
      (assert-true (unmanaged-path? "_vendor\\g\\.git\\HEAD"))
      (assert-false (unmanaged-path? "_vendor\\g\\src\\g.ss")))

    ;; relativize 不能做裸前缀匹配:root 是我们拼的(`/`)、abs 来自 Chez(`\`),
    ;; 前缀对不上就会把绝对路径当成相对路径写进 lock
    (relativize-across-separator-styles
      (assert-string= "b/c.ss" (relativize "/a" "/a/b/c.ss"))
      (assert-string= "b/c.ss" (relativize "C:\\a" "C:\\a\\b\\c.ss"))
      (assert-string= "b/c.ss" (relativize "C:/a" "C:\\a\\b\\c.ss"))   ; 混合
      (assert-string= "b/c.ss" (relativize "C:\\a\\" "C:\\a\\b\\c.ss")) ; root 带尾分隔符
      ;; 结果的分隔符归一到 `/` —— 这些相对路径要写进 lock 并跨平台比对
      (assert-false (has-path-sep? "nosep"))
      (assert-string= "b/c" (relativize "C:\\a" "C:\\a\\b\\c")))

    ;; 不在 root 之下 → 原样归还(只归一分隔符),不能悄悄剪出一个错的相对路径
    (relativize-outside-root
      (assert-string= "/other/x" (relativize "/a" "/other/x"))
      (assert-string= "C:/other/x" (relativize "C:\\a" "C:\\other\\x"))
      (assert-string= "/a" (relativize "/a/b" "/a")))          ; abs 比 root 短

    ;; absolute-path? 收紧到「字母 + `:` + 分隔符」
    (absolute-path-drive-forms
      (assert-true (absolute-path? "/x"))
      (assert-true (absolute-path? "\\x"))                    ; Windows 根相对
      (assert-true (absolute-path? "C:\\x"))
      (assert-true (absolute-path? "C:/x"))
      ;; drive-relative:**不是**绝对路径(「C 盘当前目录下的 foo」)
      (assert-false (absolute-path? "C:foo"))
      ;; POSIX 上一个真的叫 a:b 的相对路径,先前会被误判成绝对
      (assert-false (absolute-path? "a:b"))
      (assert-false (absolute-path? "rel/x"))
      (assert-false (absolute-path? "")))

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

    ;; ══════════════════════════════════════════════════════════════
    ;; rm-rf 的失败语义(C7)
    ;;
    ;; 先前每步都套 ignore-errors,于是 Windows 上「只读文件」与「被占用的
    ;; DLL/exe」两类失败被完全吞掉,调用方以为清干净了 —— 残件要到下一次操作
    ;; 才炸,报的错离现场很远。
    ;; ══════════════════════════════════════════════════════════════

    ;; 只读文件:清掉只读位后重试一次(Windows 上这是 git 的 .git/objects/**
    ;; 删不掉的唯一原因)。POSIX 上本来就删得掉,这里验证重试路径不添乱。
    (rm-rf-handles-read-only-files
      (let ([root (tmp)])
        (write-text (string-append root "/ro/a.txt") "x")
        (chmod (string-append root "/ro/a.txt") #o444)
        (rm-rf (string-append root "/ro"))
        (assert-false (file-directory? (string-append root "/ro")))))

    ;; 删不掉时**抛**,不再静默成功。用一个不可写的父目录制造真删不掉的情形。
    (rm-rf-raises-when-it-cannot-delete
      (let ([root (tmp)])
        (write-text (string-append root "/locked/a.txt") "x")
        (chmod (string-append root "/locked") #o500)          ; r-x:不能删其中的项
        (let ([raised (guard (e (#t #t)) (rm-rf (string-append root "/locked/a.txt")) #f)])
          (chmod (string-append root "/locked") #o700)        ; 先还原,好让 harness 清得掉
          (assert-true raised))))

    ;; 幂等语义不变:目标不存在 = 成功,不抛
    (rm-rf-missing-is-still-silent
      (rm-rf "/no/such/path/at/all"))

    ;; move-file:目标已存在时也要成功。
    ;;
    ;; **这条在 POSIX 上验证不了它真正要防的东西** —— POSIX 的 rename 本来就
    ;; 原子覆盖,把「先删目标」那行去掉,本测试照样绿。它守的是**契约**
    ;; (目标存在时 move 必须成功),而「Windows 上 rename 不覆盖」这条只能等
    ;; C9 的 Windows CI 才真正被跑到。不写成好像已经验证过了。
    (move-file-overwrites-existing
      (let* ([root (tmp)]
             [a (string-append root "/a")] [b (string-append root "/b")])
        (write-text a "new") (write-text b "old")
        (move-file a b)
        (assert-string= "new" (read-file-string b))
        (assert-false (file-exists? a))))

    ;; system-temp-dir 认三个变量,优先级 TMPDIR > TEMP > TMP
    (system-temp-dir-honors-windows-vars
      (let ([saved-tmpdir (getenv "TMPDIR")]
            [saved-temp (getenv "TEMP")]
            [saved-tmp (getenv "TMP")])
        (dynamic-wind
          (lambda () (void))
          (lambda ()
            (putenv "TMPDIR" "") (putenv "TEMP" "") (putenv "TMP" "")
            (putenv "TMP" "/tmpvar-tmp")
            (assert-string= "/tmpvar-tmp" (system-temp-dir))
            (putenv "TEMP" "/tmpvar-temp")
            (assert-string= "/tmpvar-temp" (system-temp-dir))   ; TEMP 压过 TMP
            (putenv "TMPDIR" "/tmpvar-tmpdir")
            (assert-string= "/tmpvar-tmpdir" (system-temp-dir)) ; TMPDIR 最优先
            ;; 空串视为未设(Chez 的 putenv 删不掉变量,还原只能置 "")
            (putenv "TMPDIR" "")
            (assert-string= "/tmpvar-temp" (system-temp-dir)))
          (lambda ()
            (putenv "TMPDIR" (or saved-tmpdir ""))
            (putenv "TEMP" (or saved-temp ""))
            (putenv "TMP" (or saved-tmp ""))))))

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

