#!chezscheme
;;; chandler/test/cli-bake.ss --- `chandler bake …` 子 CLI 测试(P6 阶段 B6c)
;;;
;;; 覆盖 argv 语法(短旗标带值是它自带一套解析器的理由)、-T/-P/-n/-c、
;;; 退出码表,以及默认任务的端到端执行。

(library (chandler test cli-bake)
  (export suite)
  (import (chezscheme)
          (chandler test harness)
          (chandler test fixtures)
          (chandler base)
          (chandler task-engine)
          (chandler compile)
          (chandler cli bake))

  (define (with-proj files proc)
    (let ([d (mktmp)] [old (current-directory)])
      (for-each (lambda (f)
                  (let ([p (join-paths d (car f))])
                    (ensure-parent p)
                    (write-file p (cdr f))))
                files)
      (dynamic-wind
        (lambda () (current-directory d))
        (lambda () (proc d))
        (lambda () (current-directory old) (rm-rf d)))))

  ;; 吞掉 stdout(任务输出 + Chez 的 "compiling …")。run-quiet 返回 thunk 的值
  ;; (退出码),capture 返回吞下的文本。guard 先解开 parameterize 再重抛 ——
  ;; 否则断言失败时 harness 的 FAIL 行会被打进 sink 吞掉。
  (define (run-quiet thunk)
    (let ([sink (open-output-string)])
      (guard (e [#t (raise e)])
        (parameterize ([current-output-port sink]) (thunk)))))

  (define (capture thunk)
    (let ([sink (open-output-string)])
      (guard (e [#t (raise e)])
        (parameterize ([current-output-port sink]) (thunk)))
      (get-output-string sink)))

  (define (when-compiler proc) (when (compiler-available?) (proc)))

  ;; 一个不需要编译器的最小 recipe:两个 phony 任务,默认任务写文件。
  (define phony-files
    '(("recipe.ss" .
       "(task 'build \"build it\" '() (lambda () (write-text \"BUILT\" \"x\")))\n(task 'other \"other one\" '() (lambda () (write-text \"OTHER\" \"x\")))\n(task 'hidden (lambda () (void)))\n(default-task 'build)\n")))

  (define-suite suite

    (parse-value-flags
      ;; 自带解析器的**理由**:bake 的短旗标带值。chandler 主解析器会把
      ;; `-j 4` 拆成「布尔 -j」+「位置参数 4」,故这条是回归钉。
      (let ([o (bake-parse-opts '("-f" "r.ss" "-j" "4" "build"))])
        (assert-string= "r.ss" (bake-opt o 'recipe))
        (assert-string= "4" (bake-opt o 'jobs))
        (assert-equal '("build") (bake-opt o 'tasks)))
      (let ([o (bake-parse-opts '("--recipe=x.ss" "--jobs=8"))])
        (assert-string= "x.ss" (bake-opt o 'recipe))
        (assert-string= "8" (bake-opt o 'jobs))
        (assert-equal '() (bake-opt o 'tasks))))

    (parse-boolean-flags
      (let ([o (bake-parse-opts '("-T" "-A" "-P" "-n" "-c" "-q" "-t"))])
        (for-each (lambda (k) (assert-true (bake-opt o k)))
                  '(list all prereqs dry clean quiet trace))))

    (parse-tasks-and-passthrough
      (let ([o (bake-parse-opts '("a" "b"))])
        (assert-equal '("a" "b") (bake-opt o 'tasks)))
      ;; `--` 之后一律当任务名,即便长得像旗标
      (let ([o (bake-parse-opts '("a" "--" "-n" "b"))])
        (assert-equal '("a" "-n" "b") (bake-opt o 'tasks))))

    (parse-missing-value-is-usage-error
      (assert-raises (lambda () (bake-parse-opts '("-f"))))
      (assert-equal exit-usage-error (*exit-code*))
      (assert-raises (lambda () (bake-parse-opts '("-j"))))
      (assert-equal exit-usage-error (*exit-code*))
      (*exit-code* exit-ok))

    (parse-unknown-option-is-usage-error
      (assert-raises (lambda () (bake-parse-opts '("--nope"))))
      (assert-equal exit-usage-error (*exit-code*))
      (*exit-code* exit-ok))

    (unknown-option-exit-64
      ;; bake-main 把哨兵异常收成退出码,不往外抛
      (assert-equal exit-usage-error (run-quiet (lambda () (bake-main '("--nope"))))))

    (missing-recipe-exit-2
      (with-proj '(("keep" . ""))
        (lambda (d)
          (assert-equal exit-config-error (run-quiet (lambda () (bake-main '())))))))

    (help-exits-0
      (let ([out (capture (lambda () (assert-equal exit-ok (bake-main '("--help")))))])
        (assert-true (string-contains? out "chandler bake [options]"))
        (assert-true (string-contains? out "-j, --jobs"))))

    (default-task-runs
      (with-proj phony-files
        (lambda (d)
          (assert-equal exit-ok (run-quiet (lambda () (bake-main '()))))
          (assert-true (file-exists? "BUILT"))
          (assert-false (file-exists? "OTHER")))))

    (named-task-runs
      (with-proj phony-files
        (lambda (d)
          (assert-equal exit-ok (run-quiet (lambda () (bake-main '("other")))))
          (assert-true (file-exists? "OTHER"))
          (assert-false (file-exists? "BUILT")))))

    (unknown-task-exit-1
      (with-proj phony-files
        (lambda (d)
          (assert-equal exit-exec-error (run-quiet (lambda () (bake-main '("nosuch"))))))))

    (dry-run-executes-nothing
      (with-proj phony-files
        (lambda (d)
          (let ([out (capture (lambda () (bake-main '("-n"))))])
            (assert-false (file-exists? "BUILT"))))))

    (list-tasks-shows-described-and-default
      ;; -T 只列有描述的(一次 library-task 会派生几十个 file 目标,全列没法看),
      ;; 但**默认任务恒列出** —— bake 那份不列,于是 `library-task` 注册的无描述
      ;; 'build 偏偏是最该看见却看不见的那个。
      (with-proj phony-files
        (lambda (d)
          (let ([out (capture (lambda () (bake-main '("-T"))))])
            (assert-true (string-contains? out "build (default)"))
            (assert-true (string-contains? out "# build it"))
            (assert-true (string-contains? out "other"))
            (assert-false (string-contains? out "hidden")))
          ;; -A 连没描述的也列
          (let ([out (capture (lambda () (bake-main '("-T" "-A"))))])
            (assert-true (string-contains? out "hidden"))))))

    (prereqs-tree
      (with-proj
        '(("recipe.ss" .
           "(task 'leaf (lambda () (void)))\n(task 'top \"top\" '(leaf) (lambda () (void)))\n(default-task 'top)\n"))
        (lambda (d)
          (let ([out (capture (lambda () (bake-main '("-P"))))])
            (assert-true (string-contains? out "top"))
            (assert-true (string-contains? out "└─ leaf"))))))

    (clean-removes-build-tree
      (when-compiler (lambda ()
        (with-proj
          '(("a.sls" . "(library (a) (export x) (import (rnrs)) (define x 1))")
            ("recipe.ss" . "(define-lib-roots \".\")\n(library-task 'build '(a))\n(default-task 'build)\n"))
          (lambda (d)
            (assert-equal exit-ok (run-quiet (lambda () (bake-main '()))))
            (assert-true (file-exists? (join-paths (build-dir) "a.so")))
            (assert-equal exit-ok (run-quiet (lambda () (bake-main '("-c")))))
            (assert-false (file-exists? "_build")))))))

    (parallel-jobs-produces-objects
      ;; -j 走子进程波前;产物与串行一致,且之后执行器不再重编。
      (when-compiler (lambda ()
        (with-proj
          '(("a.sls" . "(library (a) (export x) (import (rnrs)) (define x 1))")
            ("b.sls" . "(library (b) (export y) (import (rnrs) (a)) (define y x))")
            ("recipe.ss" . "(define-lib-roots \".\")\n(library-task 'build '(b))\n(default-task 'build)\n"))
          (lambda (d)
            (assert-equal exit-ok (run-quiet (lambda () (bake-main '("-j" "2")))))
            (assert-true (file-exists? (join-paths (build-dir) "a.so")))
            (assert-true (file-exists? (join-paths (build-dir) "b.so"))))))))

    ))
