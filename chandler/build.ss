#!chezscheme
;;; chandler/build.ss --- 排单 → bake(designs/07 §2-3, 08 §3)
;;;
;;; 职责分工:chandler 排单(读 lock、定拓扑序、授权),bake 执行(compile-tree / native)。
;;; chandler 不编译、不 import bake;只子进程调 `bake`(命令由 CHANDLER_BAKE 覆盖,便于 mock)。
;;; 安全:依赖的 native 构建 = 别人的代码 = RCE,须 --allow-build 授权,且授权绑「构建描述哈希」
;;; 写入 .chandler-approvals —— 描述变了(脚本掉包)则授权失效重提示。

(library (chandler build)
  (export build bake-command
          read-approvals write-approvals approval-hash
          dep-native-spec)
  (import (chezscheme)
          (chandler util)
          (chandler proc)
          (chandler layout)
          (chandler sexp)
          (chandler manifest)
          (chandler lock)
          (chandler install)
          (chandler hash))

  (define (bake-command) (or (getenv* "CHANDLER_BAKE") "bake"))

  ;; ── 主入口:build root opts ──
  ;; opts: (allow-build . (#t | "a,b,..")) (production . bool)
  (define (build root opts)
    (let* ([lpath (project-lock-path root)])
      (unless (file-exists? lpath)
        (error 'build "无 manifest.lock,先跑 chandler install" root))
      (let* ([lk (read-lock lpath)]
             [order (topo-order lk)]
             [allow (alist-ref opts 'allow-build)]
             [approvals-path (join-paths root ".chandler-approvals")]
             [approvals (read-approvals approvals-path)])
        ;; 1) 收集需授权的 native 构建 + 校验授权
        (let ([pending '()] [to-record '()])
          (for-each
            (lambda (d)
              (let ([name (symbol->string (locked-dep-name d))])
                (unless (null? (locked-dep-natives d))
                  (let* ([spec (dep-native-spec root name)]
                         [h (approval-hash spec)])
                    (cond
                      [(approved? approvals name h) (void)]         ; 旧授权且描述未变
                      [(allowed? allow name)                        ; 本次授权 → 记录
                       (set! to-record (cons (cons name h) to-record))]
                      [else (set! pending (cons name pending))])))))
            order)
          (unless (null? pending)
            (error 'build
                   (format "以下依赖需构建原生库(= 执行其构建脚本 = 信任其代码),请授权:~%  --allow-build~a~%  涉及:~a"
                           "" (reverse pending))))
          ;; 2) 排单执行:被依赖先
          (for-each
            (lambda (d)
              (let ([name (symbol->string (locked-dep-name d))])
                (unless (null? (locked-dep-natives d))
                  (bake-native root name (dep-native-spec root name)))
                (bake-compile-tree root name (locked-dep-srcdir d))))
            order)
          ;; 3) 落授权(描述哈希绑定)
          (unless (null? to-record)
            (write-approvals approvals-path
                             (merge-approvals approvals (reverse to-record))))
          (printf "build 完成:~a 个依赖已编译~%" (length order))
          0))))

  ;; ── bake 子进程调用(porcelain)──
  (define (bake-native root name spec)
    (let ([pkg (lib-dir root (string->symbol name))])
      (run-check (bake-command)
                 (list "native" "--pkg" pkg "--spec" (canonical-inline spec) "--porcelain")
                 '())))

  (define (bake-compile-tree root name srcdir)
    (let* ([pkg (lib-dir root (string->symbol name))]
           [dir (srcdir-join pkg srcdir)]
           [dest (join-paths root (join-paths "build" (join-paths (current-machine-type)
                                                                  (join-paths "lib" name))))])
      (run-check (bake-command)
                 (list "compile-tree" "--dir" dir "--dest" dest "--porcelain")
                 '())))

  ;; ── native 构建描述:读依赖 lib/<name>/manifest.ss 的 native 项 ──
  (define (dep-native-spec root name)
    (let ([mpath (join-paths (lib-dir root (string->symbol name)) "manifest.ss")])
      (if (file-exists? mpath)
          (let ([mf (read-manifest mpath)])
            ;; 用原始 native sexpr(而非 record)哈希更稳:重读 datum 取 native 字段
            (let ([datum (read-datum-file mpath)])
              (or (assq 'native (cdr datum)) '(native))))
          '(native))))

  ;; ── 授权文件:((name . hash) …)──
  (define (read-approvals path)
    (if (file-exists? path)
        (let ([datum (read-datum-file path)])
          (if (and (pair? datum) (eq? (car datum) 'approvals))
              (map (lambda (e) (cons (car e) (cadr e))) (cdr datum))
              '()))
        '()))

  (define (write-approvals path approvals)
    (write-canonical-file path
      `(approvals ,@(map (lambda (p) (list (car p) (cdr p)))
                         (list-sort (lambda (a b) (string<? (car a) (car b))) approvals)))))

  (define (approval-hash spec) (sha256-string (canonical-inline spec)))

  (define (approved? approvals name h)
    (let ([p (assoc name approvals)]) (and p (string=? (cdr p) h))))

  (define (merge-approvals old new)
    (append new (filter (lambda (p) (not (assoc (car p) new))) old)))

  ;; ── 授权判定 ──
  (define (allowed? allow name)
    (cond
      [(eq? allow #t) #t]
      [(string? allow) (and (member name (string-split allow #\,)) #t)]
      [else #f]))

  ;; ── 工具 ──
  (define (canonical-inline datum)
    ;; 单行 canonical 串(哈希/透传给 bake --spec 用);复用 write 到 string
    (let ([op (open-output-string)]) (write datum op) (get-output-string op))))
