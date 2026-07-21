#!chezscheme
;;; chandler/test/fs.ss --- (chandler fs) 测试

(library (chandler test fs)
  (export suite)
  (import (chezscheme)
          (chandler test harness)
          (chandler proc)
          (chandler fs))

  (define (tmp) (string-trim* (proc-result-out (run-capture "mktemp" '("-d")))))
  (define (string-trim* s)
    (let ([n (string-length s)])
      (if (and (> n 0) (char=? #\newline (string-ref s (- n 1)))) (substring s 0 (- n 1)) s)))

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
          (assert-false (file-directory? (string-append root "/a/b/c"))))))))
