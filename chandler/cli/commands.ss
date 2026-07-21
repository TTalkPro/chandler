#!chezscheme
;;; chandler/cli/commands.ss --- 各子命令实现(逐阶段填充)
;;;
;;; 当前:init(阶段 2.3)。install/update/build/run 等在后续阶段接入。
;;; 命令函数取「已解析的选项 alist」+ 工作目录,返回退出码(见 designs/01 §退出码)。

(library (chandler cli commands)
  (export cmd-init ensure-gitignore-lib skeleton-manifest-datum)
  (import (chezscheme)
          (chandler sexp)
          (chandler layout)
          (chandler manifest))

  ;; init:生成骨架 manifest.ss + .gitignore 追加 lib/;--lib 出目录骨架
  ;; opts:alist,支持 (name . str) (lib . #t) (force . #t)
  (define (cmd-init root opts)
    (let* ([name (or (assq-val 'name opts) (basename root))]
           [mpath (join-paths root "manifest.ss")])
      (when (and (file-exists? mpath) (not (assq-val 'force opts)))
        (error 'init "manifest.ss 已存在;--force 覆盖" mpath))
      (write-canonical-file mpath (skeleton-manifest-datum name))
      (ensure-gitignore-lib root)
      (when (assq-val 'lib opts)
        (scaffold-lib root name))
      (printf "已生成 ~a~%" mpath)
      0))

  (define (skeleton-manifest-datum name)
    `(manifest
       (format 1)
       (name ,name)
       (version "0.1.0")
       (chez ">=10.0")
       (srcdir ".")
       (deps)))

  ;; .gitignore 追加 lib/(幂等:已含则不动;文件不存在则新建)
  (define (ensure-gitignore-lib root)
    (let ([gi (join-paths root ".gitignore")])
      (let ([lines (if (file-exists? gi) (read-lines gi) '())])
        (unless (member "lib/" (map string-trim lines))
          (call-with-output-file gi
            (lambda (p)
              (for-each (lambda (l) (display l p) (newline p)) lines)
              (when (and (pair? lines)
                         (let ([last (list-ref lines (- (length lines) 1))])
                           (> (string-length (string-trim last)) 0)))
                (void))
              (display "lib/" p) (newline p))
            'truncate)))))

  ;; --lib:按库布局规范出最小骨架(umbrella + 同名子目录)
  (define (scaffold-lib root name)
    (let ([umbrella (join-paths root (string-append name ".ss"))]
          [subdir (join-paths root name)])
      (unless (file-exists? umbrella)
        (call-with-output-file umbrella
          (lambda (p)
            (display "#!chezscheme\n" p)
            (fprintf p ";;; ~a.ss --- umbrella facade\n\n" name)
            (fprintf p "(library (~a)\n  (export)\n  (import (chezscheme)))\n" name))
          'truncate))
      (unless (file-exists? subdir) (mkdir subdir))))

  ;; ── 小工具 ──
  (define (assq-val k alist)
    (let ([p (assq k alist)]) (and p (cdr p))))

  (define (basename p)
    (let ([parts (filter (lambda (s) (> (string-length s) 0))
                         (split-slash p))])
      (if (null? parts) "app" (list-ref parts (- (length parts) 1)))))

  (define (split-slash s)
    (let loop ([chars (string->list s)] [cur '()] [acc '()])
      (cond
        [(null? chars) (reverse (cons (list->string (reverse cur)) acc))]
        [(char=? #\/ (car chars))
         (loop (cdr chars) '() (cons (list->string (reverse cur)) acc))]
        [else (loop (cdr chars) (cons (car chars) cur) acc)])))

  (define (read-lines path)
    (call-with-input-file path
      (lambda (p)
        (let loop ([acc '()])
          (let ([l (get-line p)])
            (if (eof-object? l) (reverse acc) (loop (cons l acc))))))))

  (define (string-trim s)
    (list->string
      (let drop-trailing ([cs (reverse (drop-leading (string->list s)))])
        (reverse (drop-leading cs)))))
  (define (drop-leading cs)
    (cond [(null? cs) cs]
          [(memv (car cs) '(#\space #\tab #\return #\newline)) (drop-leading (cdr cs))]
          [else cs])))
