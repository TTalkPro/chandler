#!chezscheme
;;; tests/chandler/cli-make.ss --- `chandler make …` 子 CLI 测试(P6 阶段 B6c;原 cli-bake)
;;;
;;; 覆盖 argv 语法(短旗标带值是它自带一套解析器的理由)、-T/-P/-n/-c、
;;; 退出码表,以及默认任务的端到端执行。

(library (tests chandler cli-make)
  (export suite)
  (import (chezscheme)
          (tests chandler harness)
          (tests chandler fixtures)
          (chandler base)
          (chandler task-engine)
          (chandler compile)
          (chandler recipe)
          (chandler cli make))

  ;; with-proj / run-quiet / capture-output / when-compiler 来自
  ;; (tests chandler fixtures)。

  ;; 一个不需要编译器的最小 recipe:两个 phony 任务,默认任务写文件。
  (define phony-files
    '(("chandler-tasks.ss" .
       "(task 'build \"build it\" '() (lambda () (write-text \"BUILT\" \"x\")))\n(task 'other \"other one\" '() (lambda () (write-text \"OTHER\" \"x\")))\n(task 'hidden (lambda () (void)))\n(default-task 'build)\n")))

  (define-suite suite

    (parse-value-flags
      ;; 自带解析器的**理由**:bake 的短旗标带值。chandler 主解析器会把
      ;; `-j 4` 拆成「布尔 -j」+「位置参数 4」,故这条是回归钉。
      (let ([o (make-parse-opts '("-f" "r.ss" "-j" "4" "build"))])
        (assert-string= "r.ss" (make-opt o 'recipe))
        (assert-string= "4" (make-opt o 'jobs))
        (assert-equal '("build") (make-opt o 'tasks)))
      (let ([o (make-parse-opts '("--recipe=x.ss" "--jobs=8"))])
        (assert-string= "x.ss" (make-opt o 'recipe))    ; 旧名向后兼容
        (assert-string= "8" (make-opt o 'jobs))
        (assert-equal '() (make-opt o 'tasks)))
      ;; 新名 --file(与文件重命名 recipe.ss → chandler-tasks.ss 配套)
      (let ([o (make-parse-opts '("--file" "t.ss"))])
        (assert-string= "t.ss" (make-opt o 'recipe)))
      (let ([o (make-parse-opts '("--file=t.ss"))])
        (assert-string= "t.ss" (make-opt o 'recipe)))
      ;; 默认文件名常量 = chandler 命名(不是 bake 的 recipe.ss)
      (assert-string= "chandler-tasks.ss" default-tasks-file))

    (parse-boolean-flags
      (let ([o (make-parse-opts '("-T" "-A" "-P" "-n" "-c" "-q" "-t"))])
        (for-each (lambda (k) (assert-true (make-opt o k)))
                  '(list all prereqs dry clean quiet trace))))

    (parse-tasks-and-passthrough
      (let ([o (make-parse-opts '("a" "b"))])
        (assert-equal '("a" "b") (make-opt o 'tasks)))
      ;; `--` 之后一律当任务名,即便长得像旗标
      (let ([o (make-parse-opts '("a" "--" "-n" "b"))])
        (assert-equal '("a" "-n" "b") (make-opt o 'tasks))))

    (parse-missing-value-is-usage-error
      (assert-raises (lambda () (make-parse-opts '("-f"))))
      (assert-equal exit-usage-error (*exit-code*))
      (assert-raises (lambda () (make-parse-opts '("-j"))))
      (assert-equal exit-usage-error (*exit-code*))
      (*exit-code* exit-ok))

    (parse-unknown-option-is-usage-error
      (assert-raises (lambda () (make-parse-opts '("--nope"))))
      (assert-equal exit-usage-error (*exit-code*))
      (*exit-code* exit-ok))

    (unknown-option-exit-64
      ;; make-main 把哨兵异常收成退出码,不往外抛
      (assert-equal exit-usage-error (run-quiet (lambda () (make-main '("--nope"))))))

    (missing-recipe-exit-2
      (with-proj '(("keep" . ""))
        (lambda (d)
          (assert-equal exit-config-error (run-quiet (lambda () (make-main '())))))))

    (help-exits-0
      (let ([out (capture-output (lambda () (assert-equal exit-ok (make-main '("--help")))))])
        (assert-true (string-contains? out "chandler make [options]"))
        (assert-true (string-contains? out "-j, --jobs"))))

    (default-task-runs
      (with-proj phony-files
        (lambda (d)
          (assert-equal exit-ok (run-quiet (lambda () (make-main '()))))
          (assert-true (file-exists? "BUILT"))
          (assert-false (file-exists? "OTHER")))))

    (named-task-runs
      (with-proj phony-files
        (lambda (d)
          (assert-equal exit-ok (run-quiet (lambda () (make-main '("other")))))
          (assert-true (file-exists? "OTHER"))
          (assert-false (file-exists? "BUILT")))))

    (unknown-task-exit-1
      (with-proj phony-files
        (lambda (d)
          (assert-equal exit-exec-error (run-quiet (lambda () (make-main '("nosuch"))))))))

    (dry-run-executes-nothing
      (with-proj phony-files
        (lambda (d)
          (let ([out (capture-output (lambda () (make-main '("-n"))))])
            (assert-false (file-exists? "BUILT"))))))

    (list-tasks-shows-described-and-default
      ;; -T 只列有描述的(一次 library-task 会派生几十个 file 目标,全列没法看),
      ;; 但**默认任务恒列出** —— bake 那份不列,于是 `library-task` 注册的无描述
      ;; 'build 偏偏是最该看见却看不见的那个。
      (with-proj phony-files
        (lambda (d)
          (let ([out (capture-output (lambda () (make-main '("-T"))))])
            (assert-true (string-contains? out "build (default)"))
            (assert-true (string-contains? out "# build it"))
            (assert-true (string-contains? out "other"))
            (assert-false (string-contains? out "hidden")))
          ;; -A 连没描述的也列
          (let ([out (capture-output (lambda () (make-main '("-T" "-A"))))])
            (assert-true (string-contains? out "hidden"))))))

    (prereqs-tree
      (with-proj
        '(("chandler-tasks.ss" .
           "(task 'leaf (lambda () (void)))\n(task 'top \"top\" '(leaf) (lambda () (void)))\n(default-task 'top)\n"))
        (lambda (d)
          (let ([out (capture-output (lambda () (make-main '("-P"))))])
            (assert-true (string-contains? out "top"))
            (assert-true (string-contains? out "└─ leaf"))))))

    (clean-removes-build-tree
      (when-compiler (lambda ()
        (with-proj
          '(("a.sls" . "(library (a) (export x) (import (rnrs)) (define x 1))")
            ("chandler-tasks.ss" . "(define-lib-roots \".\")\n(library-task 'build '(a))\n(default-task 'build)\n"))
          (lambda (d)
            (assert-equal exit-ok (run-quiet (lambda () (make-main '()))))
            (assert-true (file-exists? (join-paths (build-dir) "a.so")))
            (assert-equal exit-ok (run-quiet (lambda () (make-main '("-c")))))
            (assert-false (file-exists? "_build")))))))

    (parallel-jobs-produces-objects
      ;; -j 走子进程波前;产物与串行一致,且之后执行器不再重编。
      (when-compiler (lambda ()
        (with-proj
          '(("a.sls" . "(library (a) (export x) (import (rnrs)) (define x 1))")
            ("b.sls" . "(library (b) (export y) (import (rnrs) (a)) (define y x))")
            ("chandler-tasks.ss" . "(define-lib-roots \".\")\n(library-task 'build '(b))\n(default-task 'build)\n"))
          (lambda (d)
            (assert-equal exit-ok (run-quiet (lambda () (make-main '("-j" "2")))))
            (assert-true (file-exists? (join-paths (build-dir) "a.so")))
            (assert-true (file-exists? (join-paths (build-dir) "b.so"))))))))

    ))
