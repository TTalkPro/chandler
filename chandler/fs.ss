#!chezscheme
;;; chandler/fs.ss --- 文件系统操作(优先 Chez 原生,替代 shell-out)
;;;
;;; 消除 fetch/install/registry 各写一份 ensure-dir/rm-rf/dir-entries 的冗余。
;;; 用 Chez 原生 directory-list/rename-file/delete-directory/bytevector I/O,不 shell-out
;;; (更快、可移植、无引用注入面)。

(library (chandler fs)
  (export parent-dir base-name path-join*
           ensure-dir ensure-parent
           dir-entries files-under dir-empty?
           rm-rf copy-file move-file
           read-file-string read-lines write-text
           sweep-empty-parents home-dir
           write-text-if-changed file-byte-size mtime
           path-swap-ext
           parent-dir-or-dot system-temp-dir)
  (import (chezscheme)
          (chandler util))

  ;; ── 路径拆分(纯字符串;拼接见 (chandler layout))──
  (define (parent-dir path)
    (let ([i (last-slash path)])
      (cond [(< i 0) ""] [(= i 0) "/"] [else (substring path 0 i)])))

  (define (base-name path)
    (let ([i (last-slash path)])
      (if (< i 0) path (substring path (+ i 1) (string-length path)))))

  (define (last-slash path)
    (let loop ([i (- (string-length path) 1)])
      (cond [(< i 0) -1] [(char=? #\/ (string-ref path i)) i] [else (loop (- i 1))])))

  (define (path-join* a b)
    (cond [(string=? a "") b]
          [(char=? #\/ (string-ref a (- (string-length a) 1))) (string-append a b)]
          [else (string-append a "/" b)]))

  ;; ── 目录创建(递归,幂等)──
  (define (ensure-dir dir)
    (unless (or (string=? dir "") (string=? dir "/") (file-directory? dir))
      (ensure-dir (parent-dir dir))
      (ignore-errors (mkdir dir))))            ; 并发/竞态下已存在即忽略

  (define (ensure-parent path) (ensure-dir (parent-dir path)))

  ;; ── 目录枚举(原生 directory-list;不含 . ..)──
  ;; 读不动(权限等)→ '():ignore-errors 给回 #f,直接喂 sort 会当场抛,
  ;; 于是一个不可读的子目录能让整趟 files-under 崩掉。
  (define (dir-entries dir)
    (if (file-directory? dir)
        (sort string<? (or (ignore-errors (directory-list dir)) '()))
        '()))

  (define (dir-empty? dir) (null? (dir-entries dir)))

  ;; 递归列出目录下所有普通文件(绝对路径),深度优先、字典序。
  ;;
  ;; **单向累积,不用 append**:原实现是 (append acc (files-under full)),每遇到一个
  ;; 子目录就把已累积的表整份复制一遍 —— 对文件数是平方级。而本函数是全仓最热的 FS
  ;; 原语(pack 清单、verify、enumerate-lib、copy-tree!、native 扫描全走它),前缀一大
  ;; 就很痛。改成把结果 cons 进同一个累积器、最后一次 reverse:线性,且顺序变得确定
  ;; (先前是「同级文件逆序、子目录结果追加在后」的混合序,调用方普遍还得再 list-sort)。
  (define (files-under dir)
    (reverse (files-under/acc dir '())))

  (define (files-under/acc dir acc)
    (fold-left
      (lambda (acc name)
        (let ([full (path-join* dir name)])
          (if (file-directory? full)
              (files-under/acc full acc)
              (cons full acc))))
      acc (dir-entries dir)))

  ;; ── 删除(原生递归)──
  (define (rm-rf path)
    (cond
      [(not (or (file-exists? path) (file-directory? path))) (void)]
      [(file-directory? path)
       (for-each (lambda (e) (rm-rf (path-join* path e))) (dir-entries path))
       (ignore-errors (delete-directory path))]
      [else (ignore-errors (delete-file path))]))

  ;; 删除因某文件消失而变空的祖先目录链
  (define (sweep-empty-parents path)
    (let loop ([d (parent-dir path)])
      (when (and (> (string-length d) 1) (file-directory? d) (dir-empty? d))
        (ignore-errors (delete-directory d))
        (loop (parent-dir d)))))

  ;; ── 拷贝/移动(原生 bytevector / rename-file)──
  (define (copy-file src dst)
    (ensure-parent dst)
    (let ([bytes (call-with-port (open-file-input-port src) get-bytevector-all)])
      (call-with-port (open-file-output-port dst (file-options no-fail))
        (lambda (p) (unless (eof-object? bytes) (put-bytevector p bytes))))))

  (define (move-file src dst)
    (ensure-parent dst)
    (rename-file src dst))

  ;; ── 文本 I/O ──
  (define (read-file-string path)
    (if (file-exists? path)
        (let ([s (call-with-input-file path get-string-all)])
          (if (eof-object? s) "" s))
        ""))

  (define (read-lines path)
    (if (file-exists? path)
        (call-with-input-file path
          (lambda (p)
            (let loop ([acc '()])
              (let ([l (get-line p)])
                (if (eof-object? l) (reverse acc) (loop (cons l acc)))))))
        '()))

  (define (write-text path s)
    (ensure-parent path)
    (call-with-output-file path (lambda (p) (display s p)) 'truncate))

  (define (home-dir) (or (getenv "HOME") (getenv "USERPROFILE") "."))

  ;; ── 写文本(内容不变则跳过,避免 bump mtime)──
  (define (write-text-if-changed path s)
    (unless (and (file-exists? path)
                 (string=? s (read-file-string path)))
      (write-text path s)))

  ;; 文件字节数(Chez 无直接 file-length port 方法,用 open-file-input-port)
  (define (file-byte-size f)
    (call-with-port (open-file-input-port f) (lambda (p) (file-length p))))

  ;; 文件修改时间(返回数值,与 bake 的 mtime 兼容)
  (define (mtime path)
    (and (file-exists? path) (file-modification-time path)))

  ;; 替换扩展名:无扩展名时追加 new-ext
  (define (path-swap-ext p new-ext)
    (let ([root (path-root p)])
      (if (string=? root p)
          (string-append p new-ext)
          (string-append root new-ext))))

  ;; parent-dir 但空串返回 "."(compile/import-graph 各写一份的统一出处)
  (define (parent-dir-or-dot path)
    (let ([d (parent-dir path)]) (if (string=? d "") "." d)))

  ;; 系统临时目录(尊重 TMPDIR;修 compile/recipe 硬编码 /tmp 的可移植性 bug)
  (define (system-temp-dir)
    (or (getenv "TMPDIR") "/tmp")))
