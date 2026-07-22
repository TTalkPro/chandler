#!chezscheme
;;; chandler/build.ss --- 排单 → 真实 bake(designs/07 §2-3, 08 §3;2026-07-22 对齐 bake 能力)
;;;
;;; 职责分工:chandler 排单(读 lock、授权、生成 recipe),bake 执行(library-task / native-task)。
;;; chandler 不编译、不 import bake;只子进程调 `bake`(命令由 CHANDLER_BAKE 覆盖,便于 mock)。
;;;
;;; **协作面对齐真实 bake**(bake 无 compile-tree/native 子命令,只有 recipe 任务):
;;;   install 已把各依赖源码摊平进 lib/src/;build 于**项目根**生成一份 .chandler-build.ss:
;;;     (define-lib-roots "lib/src")            ← 单根即含全部依赖源,跨依赖 import 自然解析
;;;     (library-task 'c-<dep> '(<dep>)) …      ← 逐依赖编译(bake DAG 自排依赖序)
;;;     (native-task '<soname> (lib <dep>) (dir "vendor/<dep>/native/<soname>") (build <后端>)) …
;;;   跑 `bake -f .chandler-build.ss build-all`(cwd=根)→ 产物落 _build/<mt>/;
;;;   chandler 再把 _build/<mt>/ 整棵拷进 lib/<mt>/(排除 .bake-manifest/*.wpo),补齐 src/mt 对。
;;; 安全:依赖的 native 构建 = 别人的代码 = RCE,须 --allow-build 授权,且授权绑「构建描述哈希」
;;; 写入 .chandler-approvals —— 描述变了(脚本掉包)则授权失效重提示。

(library (chandler build)
  (export build bake-command tree-library-files
          read-approvals write-approvals approval-hash
          dep-native-spec)
  (import (chezscheme)
          (chandler util)
          (chandler fs)
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
        (error 'build "manifest.lock not found; run `chandler install` first" root))
      (unless (file-directory? (car (project-lib-pair root)))   ; lib/src 需在(install 已摊平各依赖源)
        (error 'build "lib/src missing; run `chandler install` first" root))
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
            (let ([names (reverse pending)])
              (error 'build
                     (format "these dependencies need native library builds (running their build scripts means trusting their code): ~a~%  authorize with: --allow-build (all) or --allow-build=~a (these only)"
                             (string-join names ", ") (string-join names ",")))))
          ;; 2) 按拓扑序逐个依赖:在它自己的 vendor/ 树里 bake build + install → lib/
          (bake-build-deps root order)
          ;; 4) 落授权(描述哈希绑定)
          (unless (null? to-record)
            (write-approvals approvals-path
                             (merge-approvals approvals (reverse to-record))))
          (printf "build: ~a ~a compiled to lib/~a/~%"
                  (length order) (plural (length order) "dependency" "dependencies")
                  (current-machine-type))
          0))))

  ;; ── 逐个依赖:在**它自己的 vendor/ 树里**跑 bake build + install ──
  ;;
  ;; 分工:**bake 只负责编译,以及安装到指定位置**;chandler 老实遍历 vendor/,
  ;; 一个一个把它们交给 bake,装进项目的 lib/ 前缀。于是:
  ;;
  ;;   vendor/<dep>/          ← 依赖自己的仓库根 = 它的搜索根(布局规范)
  ;;     _build/<mt>/         ← 它自己的构建树,与别的依赖、与应用互不干扰
  ;;   lib/{src,<mt>}/        ← bake install 的落点(src/mt 拆分,bake designs/21)
  ;;
  ;; 之前的做法是在**项目根**生成一份大 recipe、单根 lib/src 一次编完所有依赖,
  ;; 再由 chandler 手工把 _build/<mt>/ 拷进 lib/<mt>/。那样 chandler 既做了编译
  ;; 排单又做了安装搬运,而搬运本来就是 `bake install` 的事;各依赖还共用一棵
  ;; _build/,彼此的中间物混在一起。
  ;;
  ;; **拓扑序**要紧:A 依赖 B 时,编 A 需要 B 已经在 lib/ 里。故按 lock 的
  ;; topo-order 逐个装,并把已装好的部分作为**预构建对象根**挂进去
  ;; (`(prebuilt "<project>/lib")`,bake designs/25)—— 对象式消费,不重编。
  (define (bake-build-deps root order)
    (for-each (lambda (d) (bake-one-dep root d)) order))

  (define (bake-one-dep root d)
    (let* ([name   (symbol->string (locked-dep-name d))]
           [vdir   (vendor-dir root (locked-dep-name d))]
           [srcdir (srcdir-join vdir (or (locked-dep-srcdir d) "."))]
           [recipe (join-paths srcdir ".chandler-build.ss")])
      (unless (file-directory? srcdir)
        (error 'build (format "~a not vendored; run `chandler install` first" srcdir)))
      (call-with-output-file recipe
        (lambda (p) (emit-dep-recipe p root name srcdir d))
        'truncate)
      (guard (e [#t (delete-if-exists recipe) (raise e)])
        ;; 先按 bake 自己的安装清单精确卸载再重装。`chandler install` 已经用
        ;; bake install 装过一次(那次只发源码,vendor 是干净 checkout 无 _build),
        ;; 而 bake install 见到已装会 bail —— 重装必须先卸。清单删得精确,不会碰
        ;; 同前缀下别的依赖。首次构建时无清单可卸,失败即忽略。
        (run-status (bake-command) (list "-f" ".chandler-build.ss" "uninstall")
                    (list (cons 'cwd srcdir)))
        (run-check (bake-command) (list "-f" ".chandler-build.ss" "install")
                   (list (cons 'cwd srcdir)))
        (delete-if-exists recipe))))

  ;; 生成的 recipe 住在依赖自己的树里,故 cwd = 该树,搜索根 = "."(布局规范:
  ;; 仓库根 = 搜索根)。项目 lib/ 作为预构建根供跨依赖 import 解析。
  (define (emit-dep-recipe p root name srcdir d)
    (put-string p ";;; .chandler-build.ss --- generated by `chandler build`; do not edit.\n")
    (put-string p ";;; Builds THIS dependency in its own tree, then installs it into the\n")
    (put-string p ";;; project's lib/ prefix (src/mt split). Deleted when bake returns.\n")
    (fprintf p "(define-lib-roots \".\" (prebuilt ~s))~%" (join-paths root "lib"))
    (let ([tasks '()])
      ;; native-task:已授权。源在依赖树内的 <path>,产物收进所属库 <name>
      (unless (null? (locked-dep-natives d))
        (for-each
          (lambda (item)
            (let ([soname (symbol->string (native-item-soname item))])
              (fprintf p "(native-task '~a (lib ~a) (dir ~s) (build ~a))~%"
                       soname name (native-item-path item)
                       (canonical-inline (native-item-backend item)))
              (set! tasks (cons soname tasks))))
          (native-items (dep-native-spec root name))))
      ;; library-task:该依赖树里的**每一个库**,不只 umbrella 闭包。
      ;;
      ;; 一个库包的整棵源码树就是它的公开面 —— 消费方会 import umbrella 从不引用
      ;; 的子库(chez-markding 的 extensions/ 全是选择性启用的,umbrella 一个都不
      ;; import)。只编 umbrella 闭包,装出来的 lib/<mt>/ 就残缺:实测 chez-markding
      ;; 107 个库只出 49 个对象。
      ;;
      ;; 残缺还会被悄悄掩盖:消费方的 bake 遇到没有对象的库会退回从 lib/src/ 现编进
      ;; **应用自己的** _build/<mt>/(bake designs/25 分类第 4 档),于是同一个依赖被
      ;; 劈成两棵对象树,看着能跑而已。
      (for-each
        (lambda (rel)
          (let ([t (string-append "c-" (task-suffix rel))])
            (fprintf p "(library-task '~a ~s)~%" t rel)
            (set! tasks (cons t tasks))))
        (tree-library-files srcdir name))
      (fprintf p "(task 'build-all '(~a) (lambda () (void)))~%"
               (string-join (reverse tasks) " "))
      ;; bake install:源码 → <lib>/src/、整棵 _build/<mt>/ → <lib>/<mt>/。
      ;; (needs build-all) 保证装的是刚编好的内容。
      (fprintf p "(install-task 'install (lib ~a) (from \".\") (needs build-all) (target (prefix ~s)))~%"
               name (join-paths root "lib"))
      (fprintf p "(uninstall-task 'uninstall (lib ~a) (target (prefix ~s)))~%"
               name (join-paths root "lib"))
      (put-string p "(default-task 'install)\n")))

  ;; ── 一棵库树里的全部库文件(相对该树根的路径,给 library-task 当 entry)──
  ;; 只收**真的是库**的文件:首个 datum 为 (library …)。包里也会有测试程序、脚本,
  ;; 那些交给 bake 会走 compile-program,既无意义也可能失败。
  (define (tree-library-files srcdir name)
    (let* ([pre    (string-append srcdir "/")]
           [umb    (find-umbrella srcdir name)]
           [subs   (let ([d (join-paths srcdir name)])
                     (if (file-directory? d)
                         (filter library-source? (files-under d))
                         '()))])
      (map (lambda (abs) (strip-prefix abs pre))
           (list-sort string<? (append (if umb (list umb) '()) subs)))))

  (define (find-umbrella srcdir name)
    (let loop ([exts '(".chezscheme.sls" ".sls" ".ss" ".sc")])
      (cond
        [(null? exts) #f]
        [(file-exists? (join-paths srcdir (string-append name (car exts))))
         (join-paths srcdir (string-append name (car exts)))]
        [else (loop (cdr exts))])))

  (define (library-source? path)
    (and (or (string-suffix? ".ss" path) (string-suffix? ".sls" path)
             (string-suffix? ".sc" path))
         ;; ignore-errors = (guard (e [#t #f]) body ...) —— body 的**最后一个**
         ;; 表达式是它的值,所以这里不能再跟一个 #f 兜底,那会让它恒假。
         (ignore-errors
           (let ([d (call-with-input-file path read)])
             (and (pair? d) (eq? 'library (car d)))))))

  ;; 路径 → 合法且唯一的任务名片段:非字母数字一律 "-"
  (define (task-suffix rel)
    (list->string
      (map (lambda (c) (if (or (char-alphabetic? c) (char-numeric? c)) c #\-))
           (string->list rel))))

  ;; ── native 项解析(manifest native 字段:(native (<soname> (path …) (build <后端>) …) …))──
  (define (native-items spec)                ; spec = (native item…) 或 (native)
    (if (and (pair? spec) (eq? (car spec) 'native)) (cdr spec) '()))
  (define (native-item-soname item) (car item))
  (define (native-item-path item)
    (let ([c (assq 'path (cdr item))])
      (if c (cadr c) (string-append "native/" (symbol->string (native-item-soname item))))))
  (define (native-item-backend item)
    (let ([c (assq 'build (cdr item))]) (if c (cadr c) 'make)))

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
  (define (delete-if-exists p) (when (file-exists? p) (delete-file p)))

  (define (canonical-inline datum)
    ;; 单行 canonical 串(哈希/透传给 bake --spec 用);复用 write 到 string
    (let ([op (open-output-string)]) (write datum op) (get-output-string op))))
