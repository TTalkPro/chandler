#!chezscheme
;;; tests/chandler/task-engine.ss --- (chandler task-engine) 测试
;;;
;;; 覆盖 record(task/rule/miniregex)+ parameter 钩子 + bail + join-chain。
;;; task-engine 的 engine 逻辑(execute/needed?)依赖外部注册的钩子(B4/B5
;;; 搬进来前由 bake 侧 miniregex/compile 注册),这里只测库本身可独立验证的部分。

(library (tests chandler task-engine)
  (export suite)
  (import (chezscheme)
          (tests chandler harness)
          (chandler task-engine))

  (define-suite suite
    (task-record
      ;; make-task 接 8 个位置参数:name kind prereqs action desc invoked? executed? failed?
      (let ((t (make-task "build" 'file '("a" "b") #f "desc" #f #f #f)))
        (assert-string= "build" (task-name t))
        (assert-equal 'file (task-kind t))
        (assert-equal '("a" "b") (task-prereqs t))
        (assert-equal "desc" (task-description t))
        (task-name-set! t "test")
        (task-kind-set! t 'phony)
        (assert-string= "test" (task-name t))
        (assert-equal 'phony (task-kind t))))

    (rule-record
      (let ((r (make-rule 'pat (lambda (t) '()) (lambda args 'done) "a rule" 3)))
        (assert-equal 'pat (rule-pattern r))
        (assert-equal 3 (rule-order r))
        (assert-string= "a rule" (rule-description r))))

    (miniregex-record
      (let ((re (make-miniregex '(#\a #\b) #t #f)))
        (assert-equal '(#\a #\b) (miniregex-atoms re))
        (assert-true (miniregex-start-anchored? re))
        (assert-false (miniregex-end-anchored? re))))

    (registries
      ;; task-registry/rule-registry 是 hashtable(内容可变,变量本身不被 set!)。
      (hashtable-set! task-registry "k" 'v)
      (assert-equal 'v (hashtable-ref task-registry "k" #f))
      (hashtable-clear! task-registry))

    (parameters-are-parameters
      ;; 被 set! 的全局改成了 parameter(R6RS library 不能 export assigned variable)。
      ;; 断言的是**语义**(可 parameterize、可读写),不是「此刻的全局值」——
      ;; default-task-name / rule-order-counter 属于**构建会话**状态,别的 suite
      ;; (build / recipe / compile)跑完会留下值,断言默认值等于断言测试顺序。
      (parameterize ([*dry-run* #t] [*quiet* #t] [*trace* #t]
                     [default-task-name 'x] [rule-order-counter 3])
        (assert-true  (*dry-run*))
        (assert-true  (*quiet*))
        (assert-true  (*trace*))
        (assert-equal 'x (default-task-name))
        (assert-equal 3 (rule-order-counter)))
      ;; parameterize 退出即还原(证明它们真是 parameter 而非全局变量)
      (let ([saved (*dry-run*)])
        (parameterize ([*dry-run* (not saved)]) (void))
        (assert-equal saved (*dry-run*)))
      ;; 退出码常量表(designs/04 §退出码)
      (assert-equal 0  exit-ok)
      (assert-equal 1  exit-exec-error)
      (assert-equal 2  exit-config-error)
      (assert-equal 64 exit-usage-error)
      (assert-equal 70 exit-internal))

    (parameter-set-get
      ;; access (*x*) / set (*x* v) — parameter 语义。
      (*dry-run* #t)
      (assert-true (*dry-run*))
      (*dry-run* #f)
      (assert-false (*dry-run*))
      (*exit-code* exit-exec-error)
      (assert-equal exit-exec-error (*exit-code*))
      (*exit-code* exit-ok)
      (rule-order-counter 7)
      (assert-equal 7 (rule-order-counter))
      (rule-order-counter 0))

    (hooks-are-parameters
      ;; forward-reference 钩子是 parameter,值恒是过程。
      ;; **不断言默认值**:默认只在没人注册时有效,而 miniregex / compile 一旦被
      ;; 加载就会把自己注册进来(测试进程里正是如此)。断言默认行为等于断言
      ;; 「这两个库没被加载」,那是与测试顺序耦合的假约束。
      (assert-true (procedure? (current-regexp-matcher)))
      (assert-true (procedure? (current-fingerprint-judge)))
      (assert-true (procedure? (current-compile-needed)))
      (parameterize ((current-regexp-matcher (lambda (pat s) 'matched)))
        (assert-equal 'matched ((current-regexp-matcher) "a" "b")))
      (assert-raises (lambda () (current-regexp-matcher 'not-a-procedure))))

    (hooks-register
      ;; 注册后,钩子调用注册的过程;测试结束**复位成原值**(不是复位成默认值——
      ;; (chandler miniregex) 实例化时已把 regexp-match? 注册进来,写死默认值
      ;; 会把它抹掉,后跑的 recipe rule 用例就匹配不上了)。
      (let ((orig (current-regexp-matcher)))
        (current-regexp-matcher (lambda (pat s) #t))
        (assert-true  ((current-regexp-matcher) "x" "y"))
        (current-regexp-matcher (lambda (pat s) #f))
        (assert-false ((current-regexp-matcher) "x" "y"))
        (current-regexp-matcher orig)))

    (join-chain-format
      ;; designs/03 要求用 Unicode 箭头 " → " 分隔。
      (assert-string= "a" (join-chain '("a")))
      (assert-string= "a → b" (join-chain '("a" "b")))
      (assert-string= "a → b → c" (join-chain '("a" "b" "c")))
      (assert-string= "build" (join-chain '(build))))

    (bail-raises
      ;; bail-exec/bail-config 抛 'bake-error + 各自设置 *exit-code*。
      (assert-raises (lambda () (bail-exec "test error ~a" 42)))
      (assert-equal exit-exec-error (*exit-code*))
      (assert-raises (lambda () (bail-config "config error")))
      (assert-equal exit-config-error (*exit-code*))
      (*exit-code* exit-ok))

    ))
