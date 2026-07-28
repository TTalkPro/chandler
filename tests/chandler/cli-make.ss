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

  ;; n 层菱形堆叠:t_i 依赖 a_i 与 b_i,两者都依赖 t_{i+1}。
  ;; 节点数 3n+1(线性),而**未折叠**的树是 2^n —— 这正是共享子树重复展开的
  ;; 最小复现形状,库任务图(一个 util 被所有人 import)就是它的现实版。
  (define (diamond-stack-tasks n)
    (let ([op (open-output-string)])
      (do ([i 0 (+ i 1)]) ((= i n))
        (fprintf op "(task 'a~a '(t~a) (lambda () (void)))~%" i (+ i 1))
        (fprintf op "(task 'b~a '(t~a) (lambda () (void)))~%" i (+ i 1))
        (fprintf op "(task 't~a '(a~a b~a) (lambda () (void)))~%" i i i))
      (fprintf op "(task 't~a '() (lambda () (void)))~%" n)
      (fprintf op "(default-task 't0)~%")
      (get-output-string op)))

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

    ;; **重复子树折叠**:共享的前置只完整展开一次,再遇打 `name ...` 且不下钻。
    ;;
    ;; 先前的卫兵传的是**路径**(祖先链),只挡得住环、挡不住共享子树 —— 每条到达
    ;; 它的路径都把它整棵重展一遍。实测 18 层菱形堆叠(55 个任务)打出 419 万行;
    ;; 而库任务图天然就是这个形状(`util` 被几乎所有库 import)。
    ;;
    ;; **断言落在行数上,不在措辞上** —— 指数爆炸的症状就是行数,而且是唯一
    ;; 能把「守卫真的短路了」与「守卫写成了空转」区分开的东西(bake D60:
    ;; 那边第一版修复把守卫写成 `(unless #f …)`,测试/注释/commit 全描述着正确
    ;; 行为,唯独代码没拦住下钻)。
    (prereqs-folds-repeated-subtrees
      (with-proj
        (list (cons "chandler-tasks.ss" (diamond-stack-tasks 12)))
        (lambda (d)
          (let* ([out (capture-output (lambda () (make-main '("-P"))))]
                 [n (length (split-lines out))])
            ;; 37 个任务。折叠前是 2^12 量级(实测 18 层 = 419 万行);
            ;; 折叠后每个根最多把每个任务打一次 ⇒ 上界 37×37。
            ;; 用一个宽松但**指数进不来**的界:5000。
            (assert-true (< n 5000))
            ;; 不是空输出蒙混过关:每个任务至少作为根出现一次
            (assert-true (> n 37))
            ;; 共享节点确实被折叠标出来了
            (assert-true (string-contains? out " ..."))))))

    ;; 环:必须终止(折叠之后环上的节点第二次出现即停),且退出码正常。
    ;; 先前靠单独的路径卫兵挡环,折叠接管之后这条仍须成立。
    (prereqs-terminates-on-cycle
      (with-proj
        '(("chandler-tasks.ss" .
           "(task 'a '(b) (lambda () (void)))\n(task 'b '(a) (lambda () (void)))\n(default-task 'a)\n"))
        (lambda (d)
          (let* ([out (capture-output (lambda () (assert-equal exit-ok (make-main '("-P")))))]
                 [n (length (split-lines out))])
            (assert-true (< n 20))))))

    ;; 叶子重复出现时**不加**省略号 —— 没有被省掉的东西,加了是误导
    (prereqs-repeated-leaf-has-no-ellipsis
      (with-proj
        '(("chandler-tasks.ss" .
           "(task 'leaf (lambda () (void)))\n(task 'x '(leaf) (lambda () (void)))\n(task 'y '(leaf) (lambda () (void)))\n(task 'top '(x y) (lambda () (void)))\n(default-task 'top)\n"))
        (lambda (d)
          (let ([out (capture-output (lambda () (make-main '("-P"))))])
            ;; leaf 在 top 的树里出现两次(经 x 与经 y),但它没有前置
            (assert-false (string-contains? out "leaf ..."))
            ;; 而有前置的 x/y 之类被折叠时该带省略号(此图里由 top 树验不到,
            ;; 故只钉住上面那条;带省略号的情形由 prereqs-folds-repeated-subtrees 覆盖)
            (assert-true (string-contains? out "leaf"))))))

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
