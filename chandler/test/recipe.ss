#!chezscheme
;;; chandler/test/recipe.ss --- (chandler recipe) 测试
;;;
;;; 覆盖 DSL 注册(task/file/rule/default-task)、recipe 加载(可变环境、
;;; 每次加载环境隔离、native 预扫钩子、失败即 config error)、目标选择与调用。
;;; 都在临时目录里造真 recipe 文件跑,不 mock —— load-recipe 的价值正是「读真文件、
;;; eval 在组好的环境里」,mock 掉就什么也没验。

(library (chandler test recipe)
  (export suite)
  (import (chezscheme)
          (chandler test harness)
          (chandler test fixtures)
          (chandler base)
          (chandler task-engine)
          (chandler recipe))

  ;; 在临时目录里跑 thunk(recipe 里的相对路径目标据此解析);无论成败都还原 cwd。
  (define (with-tmp-dir proc)
    (let ((d (mktmp))
          (old (current-directory)))
      (dynamic-wind
        (lambda () (current-directory d))
        (lambda () (proc d))
        (lambda () (current-directory old) (rm-rf d)))))

  ;; 写一份 recipe.ss 到 cwd 并加载;静音执行输出。
  (define (load-text! text)
    (write-file "recipe.ss" text)
    (load-recipe "recipe.ss"))

  (define (quiet thunk) (parameterize ((*quiet* #t)) (thunk)))

  (define-suite suite

    (load-registers-tasks
      ;; task/file/default-task 三种声明各自进 registry;default-task-name 被记下。
      (with-tmp-dir
        (lambda (d)
          (load-text! "(task 'hello \"say hi\" '() (lambda () (void)))
                       (file \"out.txt\" '() (lambda (t deps) (write-text t \"x\")))
                       (task 'build '(\"out.txt\") (lambda () (void)))
                       (default-task 'build)")
          (assert-equal 'build (default-task-name))
          (assert-true (task? (hashtable-ref task-registry 'hello #f)))
          (assert-true (task? (hashtable-ref task-registry "out.txt" #f)))
          (assert-equal 'phony (task-kind (hashtable-ref task-registry 'hello #f)))
          (assert-equal 'file  (task-kind (hashtable-ref task-registry "out.txt" #f)))
          (assert-string= "say hi"
                          (task-description (hashtable-ref task-registry 'hello #f))))))

    (invoke-file-and-phony
      ;; 走 engine:build 依赖 out.txt,file action 真写出文件。
      (with-tmp-dir
        (lambda (d)
          (load-text! "(file \"out.txt\" '() (lambda (t deps) (write-text t \"generated\")))
                       (task 'build '(\"out.txt\") (lambda () (write-text \"done.txt\" \"ok\")))
                       (default-task 'build)")
          (quiet (lambda () (invoke-task 'build)))
          (assert-true (file-exists? "out.txt"))
          (assert-string= "generated" (read-file-string "out.txt"))
          (assert-string= "ok" (read-file-string "done.txt")))))

    (recipe-sees-own-defines
      ;; recipe 顶层 (define …) 要能定义(环境必须可变)且被同份 recipe 的 action 看见。
      (with-tmp-dir
        (lambda (d)
          (load-text! "(define payload \"from-define\")
                       (task 'w (lambda () (write-text \"w.txt\" payload)))
                       (default-task 'w)")
          (quiet (lambda () (invoke-task 'w)))
          (assert-string= "from-define" (read-file-string "w.txt")))))

    (recipe-env-is-fresh-per-load
      ;; 上一份 recipe 的定义不得渗进下一份 —— 每次 load-recipe 现组环境。
      (with-tmp-dir
        (lambda (d)
          (load-text! "(define leaked 1)
                       (task 'x (lambda () (void)))
                       (default-task 'x)")
          (assert-raises
            (lambda ()
              (load-text! "(task 'y (lambda () (void)))
                           (display leaked)
                           (default-task 'y)")))
          (assert-equal exit-config-error (*exit-code*))
          (*exit-code* exit-ok))))

    (rule-materializes-target
      ;; rule pattern 经 miniregex 编译,resolve 时物化成 file 任务。
      (with-tmp-dir
        (lambda (d)
          (write-file "a.in" "src")
          (load-text! "(rule \"\\\\.out$\"
                             (lambda (t) (list (path-swap-ext t \".in\")))
                             (lambda (t deps)
                               (write-text t (string-append \"[\" (file->string (car deps)) \"]\"))))
                       (default-task \"a.out\")")
          (quiet (lambda () (invoke-task "a.out")))
          (assert-string= "[src]" (read-file-string "a.out")))))

    (rule-order-preserved
      ;; 多条 rule 按声明序排,先匹配者胜(rule-order-counter 从 0 起递增)。
      (with-tmp-dir
        (lambda (d)
          (load-text! "(rule \"\\\\.out$\" (lambda (t) '()) (lambda (t deps) (write-text t \"first\")))
                       (rule \"\\\\.out$\" (lambda (t) '()) (lambda (t deps) (write-text t \"second\")))
                       (default-task \"z.out\")")
          (assert-equal 2 (rule-order-counter))
          (quiet (lambda () (invoke-task "z.out")))
          (assert-string= "first" (read-file-string "z.out")))))

    (default-task-undeclared-is-config-error
      ;; 符号默认任务必须已声明(符号从不惰性物化)。
      (with-tmp-dir
        (lambda (d)
          (assert-raises (lambda () (load-text! "(default-task 'nope)")))
          (assert-equal exit-config-error (*exit-code*))
          (*exit-code* exit-ok))))

    (recipe-load-failure-is-config-error
      ;; recipe 里未绑定的标识符 → 加载失败,退出码 2(不是执行错的 1)。
      (with-tmp-dir
        (lambda (d)
          (assert-raises (lambda () (load-text! "(no-such-helper 1)")))
          (assert-equal exit-config-error (*exit-code*))
          (*exit-code* exit-ok))))

    (missing-prereq-is-exec-error
      (with-tmp-dir
        (lambda (d)
          (load-text! "(task 'x (lambda () (void)))
                       (default-task 'x)")
          (assert-raises (lambda () (quiet (lambda () (invoke-task "no-such-file.xyz")))))
          (assert-equal exit-exec-error (*exit-code*))
          (*exit-code* exit-ok))))

    (native-prescan-hook
      ;; B5 的 native loader 预扫钩子:拿到的是**整份** recipe 的 form 列表,
      ;; 且在任何一 form 求值**之前**调用(生成的 loader 源码要先落盘)。
      (with-tmp-dir
        (lambda (d)
          (let ((seen #f) (order '()))
            (parameterize ((current-native-prescan
                             (lambda (forms)
                               (set! seen forms)
                               (set! order (cons 'prescan order)))))
              (write-file "recipe.ss"
                          "(task 'a (lambda () (void)))
                           (task 'b (lambda () (void)))
                           (default-task 'a)")
              (load-recipe "recipe.ss"))
            (assert-equal 3 (length seen))
            (assert-equal 'task (car (car seen)))
            (assert-equal '(prescan) order)))))

    (normalize-and-select-targets
      ;; argv 恒是字符串:有同名 phony 则转符号,否则原样留给 file/rule 分支。
      (with-tmp-dir
        (lambda (d)
          (load-text! "(task 'smoke (lambda () (void)))
                       (default-task 'smoke)")
          (assert-equal 'smoke (normalize-target "smoke"))
          (assert-string= "a.out" (normalize-target "a.out"))
          (assert-equal 'smoke (normalize-target 'smoke))
          (assert-equal '(smoke) (select-targets '()))
          (assert-equal '(smoke "a.out") (select-targets '("smoke" "a.out"))))))

    (select-targets-without-default
      (with-tmp-dir
        (lambda (d)
          (load-text! "(task 'only (lambda () (void)))")
          (assert-false (default-task-name))
          (assert-raises (lambda () (select-targets '())))
          (assert-equal exit-config-error (*exit-code*))
          (*exit-code* exit-ok))))

    (clause-readers
      ;; %clause 取值 / 给默认;%clause-req 缺失即 config error。
      (let ((clauses '((backend script) (script "build.sh"))))
        (assert-equal 'script (%clause 'backend clauses #f))
        (assert-string= "build.sh" (%clause 'script clauses #f))
        (assert-equal 'fallback (%clause 'missing clauses 'fallback))
        (assert-string= "build.sh" (%clause-req "native-task" 'foo 'script "<path>" clauses))
        (assert-raises
          (lambda () (%clause-req "native-task" 'foo 'backend2 "<backend>" clauses)))
        (*exit-code* exit-ok)))

    (register-task-validation
      ;; phony 任务名必须是符号;prereqs/description/action 类型各自把关。
      (assert-raises (lambda () (register-task! "str" 'phony '() #f #f)))
      (assert-raises (lambda () (register-task! 'ok 'phony 'not-a-list #f #f)))
      (assert-raises (lambda () (register-task! 'ok 'phony '() #f 'not-a-string)))
      (assert-raises (lambda () (register-task! 'ok 'phony '() 'not-a-proc #f)))
      (assert-true (task? (register-task! 'ok 'phony '() #f "desc")))
      (hashtable-clear! task-registry)
      (*exit-code* exit-ok))

    (register-rule-validation
      (assert-raises (lambda () (register-rule! 42 (lambda (t) '()) #f #f)))
      (assert-raises (lambda () (register-rule! "\\.x$" 'not-a-proc #f #f)))
      (assert-raises (lambda () (register-rule! "\\.x$" (lambda (t) '()) 'not-a-proc #f)))
      (hashtable-clear! rule-registry)
      (rule-order-counter 0)
      (*exit-code* exit-ok))

    (recipe-environment-libs-validated
      ;; 环境组成是库引用的列表;B4/B5 往上追加,故值形状要把关。
      (assert-raises (lambda () (recipe-environment-libs 'not-a-list)))
      (assert-raises (lambda () (recipe-environment-libs '(chezscheme))))  ; 少一层括号
      (assert-true (memq 'chandler (map car (recipe-environment-libs)))))

    (recipe-helpers
      ;; recipe 面辅助:path-ext / file->string / file->lines / run/code。
      (assert-string= "ss" (path-ext "chandler/recipe.ss"))
      (assert-false (path-ext "no-ext"))
      (assert-string= ".foo" (path-ext ".foo"))
      (with-tmp-dir
        (lambda (d)
          (write-file "t.txt" "l1\nl2\n")
          (assert-string= "l1\nl2\n" (file->string "t.txt"))
          (assert-equal '("l1" "l2") (file->lines "t.txt"))
          (write-file "empty.txt" "")
          (assert-string= "" (file->string "empty.txt"))
          (assert-equal 0 (run/code "true"))
          (assert-false (= 0 (run/code "false")))
          (assert-string= "hi\n" (run/capture "echo" "hi"))
          (assert-raises (lambda () (run "false"))))))

    ))
