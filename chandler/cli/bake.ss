#!chezscheme
;;; chandler/cli/bake.ss --- `chandler bake …`:任务运行器的 CLI 面(吸收自 bake)
;;;
;;; 来源:bake/cli.ss(§13 选项解析 / §14 -T、-P / §15 help)+ bake/dispatch.ss(§16)。
;;; 供「只要构建、不要包管理」的用法:`chandler bake build` ≡ 旧的 `bake build`。
;;;
;;; **自带一套 argv 语法**,不走 `(chandler cli args)` —— bake 的短旗标带值
;;; (`-f path` / `-j N`),而 chandler 的解析器把未知短旗标一律当布尔,`-j 4` 会被
;;; 拆成「布尔 -j」+「位置参数 4」。故 `main` 在解析之前就把 `bake` 之后的 argv
;;; **原样**交给这里,子 CLI 自己解析自己的语法。
;;;
;;; 相对 bake 去掉三项(都已无对应物):
;;;   --bootstrap  bake 把自己 17 个模块编成 bake-all.so —— chandler 的安装由自含的
;;;                bootstrap.ss 负责(§18f 整段未搬)
;;;   -B           bake 自己就只打一句 "ignored in this version"
;;;   --name/--lib/--force  是 `bake init` 的选项;脚手架归 `chandler init`,
;;;                且 recipe.ss 自 B6b 起是可选的,再来一套 init 只会制造重复

(library (chandler cli bake)
  (export bake-main bake-parse-opts bake-opt bake-list-tasks bake-show-prereqs)
  (import (chezscheme)
          (chandler base)
          (chandler task-engine)
          (chandler recipe)
          (chandler import-graph)
          (chandler compile)
          (chandler native-build))

  ;; ── 选项:alist,不用全局 set!(bake 那份是 *opts-* 一堆全局变量)──
  (define (bake-opt o k) (alist-ref o k))

  (define (usage-error fmt . args)
    (apply eprintf (string-append "chandler bake: error: " fmt "\n") args)
    (eprintf "Try `chandler bake --help` for usage.~%")
    (*exit-code* exit-usage-error)
    (raise 'bake-error))

  (define (bake-parse-opts argv)
    (let loop ([args argv] [o '()] [tasks '()])
      (define (put k v rest) (loop rest (cons (cons k v) o) tasks))
      (define (need k args what)
        (if (null? (cdr args))
            (usage-error "missing ~a for ~a" what (car args))
            (loop (cddr args) (cons (cons k (cadr args)) o) tasks)))
      (cond
        [(null? args) (cons (cons 'tasks (reverse tasks)) o)]
        [(string=? (car args) "--")
         (cons (cons 'tasks (append (reverse tasks) (cdr args))) o)]
        [(string-prefix? "--recipe=" (car args))
         (put 'recipe (strip-prefix (car args) "--recipe=") (cdr args))]
        [(string-prefix? "--jobs=" (car args))
         (put 'jobs (strip-prefix (car args) "--jobs=") (cdr args))]
        [(member (car args) '("--recipe" "-f")) (need 'recipe args "path")]
        [(member (car args) '("--jobs" "-j"))   (need 'jobs args "count")]
        [(member (car args) '("-T" "--tasks"))      (put 'list #t (cdr args))]
        [(member (car args) '("-A" "--all-tasks"))  (put 'all #t (cdr args))]
        [(member (car args) '("-P" "--prereqs"))    (put 'prereqs #t (cdr args))]
        [(member (car args) '("-n" "--dry-run"))    (put 'dry #t (cdr args))]
        [(member (car args) '("-c" "--clean"))      (put 'clean #t (cdr args))]
        [(member (car args) '("-q" "--quiet"))      (put 'quiet #t (cdr args))]
        [(member (car args) '("-v" "--verbose"))    (put 'verbose #t (cdr args))]
        [(member (car args) '("-t" "--trace"))      (put 'trace #t (cdr args))]
        [(member (car args) '("-h" "--help"))       (put 'help #t (cdr args))]
        [(member (car args) '("-V" "--version"))    (put 'version #t (cdr args))]
        [(and (> (string-length (car args)) 0) (char=? #\- (string-ref (car args) 0)))
         (usage-error "unknown option: ~a" (car args))]
        [else (loop (cdr args) o (cons (car args) tasks))])))

  ;; ── §14 -T:列任务 ──
  (define (symbol-<? a b) (string<? (symbol->string a) (symbol->string b)))

  (define (sort-task-names a b)
    (cond
      [(and (symbol? a) (symbol? b)) (symbol-<? a b)]
      [(and (string? a) (string? b)) (string<? a b)]
      [(symbol? a) #t]
      [else #f]))

  (define (bake-list-tasks)
    ;; 输出形如 "chandler bake <name>    # <描述>",默认任务带 (default) 标记。
    ;; 无描述的任务只在 -A 下露面 —— 一次 library-task 会派生几十个 file 目标,
    ;; 默认全列出来就没法看了。**默认任务恒列出**(bake 那份不列:`library-task`
    ;; 注册的 'build 没有描述,于是 `-T` 偏偏漏掉最该看见的那一个)。
    (let* ([names (list-sort sort-task-names (vector->list (hashtable-keys task-registry)))]
           [shown (filter (lambda (n)
                            (let ([t (hashtable-ref task-registry n #f)])
                              (or (*all-tasks*)
                                  (equal? (default-task-name) n)
                                  (and t (task-description t)))))
                          names)])
      (for-each
        (lambda (n)
          (let ([t (hashtable-ref task-registry n #f)])
            (display "chandler bake ")
            (display (task-name t))
            (when (equal? (default-task-name) (task-name t)) (display " (default)"))
            (display "    # ")
            (display (or (task-description t) "(no description)"))
            (newline)))
        shown)))

  ;; ── §14 -P:任务图诊断(逐任务打传递前置树)──
  (define (bake-show-prereqs)
    (define (children name)
      (let ([t (hashtable-ref task-registry name #f)])
        (if t (task-prereqs t) '())))          ; 未物化的名字作叶子打印
    (define (walk name depth seen)
      (if (= depth 0)
          (begin (display (format-object name)) (newline))
          (begin (display (make-string (+ 2 (* (- depth 1) 5)) #\space))
                 (display "└─ ") (display (format-object name)) (newline)))
      (unless (member name seen)                ; 环卫兵 —— 不再往下递归
        (for-each (lambda (c) (walk c (+ depth 1) (cons name seen))) (children name))))
    (for-each (lambda (n) (walk n 0 '()))
              (list-sort sort-task-names (vector->list (hashtable-keys task-registry)))))

  (define (print-help)
    (printf "chandler bake -- run tasks from a recipe.ss (the task runner absorbed from bake)~%~%")
    (printf "Usage: chandler bake [options] [task ...]~%~%")
    (printf "Options:~%")
    (printf "  -f, --recipe PATH   recipe file to load (default: ./recipe.ss)~%")
    (printf "  -T, --tasks         list tasks that carry a description~%")
    (printf "  -A, --all-tasks     with -T: list every task, described or not~%")
    (printf "  -P, --prereqs       print each task's prerequisite tree~%")
    (printf "  -j, --jobs N        compile .so units with N concurrent subprocesses~%")
    (printf "  -n, --dry-run       print the execution plan; run nothing~%")
    (printf "  -c, --clean         remove declared outputs and _build/~%")
    (printf "  -q, --quiet         suppress progress output~%")
    (printf "  -t, --trace         trace task invocation~%")
    (printf "  -h, --help          this message~%~%")
    (printf "Most projects do not need a recipe.ss at all: `chandler build` derives the~%")
    (printf "build from manifest.ss. Write one only for custom tasks (test, release, ...).~%"))

  ;; ── §16 dispatch ──
  (define (bake-main argv)
    (guard (e [(eq? e 'bake-error) (*exit-code*)])
      (let ([o (bake-parse-opts argv)])
        (cond
          [(bake-opt o 'help) (print-help) exit-ok]
          [(bake-opt o 'version) (printf "chandler ~a~%" chandler-version) exit-ok]
          [else (run-tasks o)]))))

  (define (run-tasks o)
    ;; 装配必须早于 load-recipe:Chez 惰性实例化库,而 recipe 里的
    ;; (define-lib-roots …) / (native-task …) 要求求值前环境里就有它们。
    (install-compile-hooks!)
    (install-native-hooks!)
    (*dry-run*   (and (bake-opt o 'dry) #t))
    (*quiet*     (and (bake-opt o 'quiet) #t))
    (*verbose*   (not (bake-opt o 'quiet)))
    (*trace*     (and (bake-opt o 'trace) #t))
    (*all-tasks* (and (bake-opt o 'all) #t))
    (let ([recipe (or (bake-opt o 'recipe) "recipe.ss")])
      (unless (file-exists? recipe)
        (bail-config "recipe file not found: ~a (use -f to specify)" recipe))
      (load-recipe recipe)
      (load-fp-manifest!)
      (cond
        [(bake-opt o 'clean)   (cmd-clean) (*exit-code*)]
        [(bake-opt o 'list)    (bake-list-tasks) exit-ok]
        [(bake-opt o 'prereqs) (bake-show-prereqs) exit-ok]
        [else
         ;; -j N:先用 N 个子进程把需要的 .so 编出来(designs/11 波前),之后
         ;; 进程内的执行器只管链接 + 跑 phony(编译产物已新鲜)。
         (when (and (bake-opt o 'jobs) (not (*dry-run*)))
           (parallel-build! (max 1 (or (string->number (bake-opt o 'jobs)) 1))))
         (for-each (lambda (t) (invoke t '())) (select-targets (bake-opt o 'tasks)))
         ;; 指纹只在**全程成功且非 dry-run** 后落盘(designs/07 §Manifest)
         (unless (*dry-run*) (write-fp-manifest!))
         exit-ok])))

  )
