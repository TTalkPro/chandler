#!chezscheme
;;; chandler/test/task-engine.ss --- (chandler task-engine) 测试
;;;
;;; 覆盖 record(task/rule/miniregex)+ parameter 钩子 + bail + join-chain。
;;; task-engine 的 engine 逻辑(execute/needed?)依赖外部注册的钩子(B4/B5
;;; 搬进来前由 bake 侧 miniregex/compile 注册),这里只测库本身可独立验证的部分。

(library (chandler test task-engine)
  (export suite)
  (import (chezscheme)
          (chandler test harness)
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

    (parameter-defaults
      ;; mutable globals 是 parameter(R6RS library 不能 export assigned variable)。
      (assert-false (*dry-run*))
      (assert-false (*quiet*))
      (assert-true  (*verbose*))
      (assert-false (*trace*))
      (assert-equal exit-ok (*exit-code*))
      (assert-equal 0 (*rule-depth*))
      (assert-false (default-task-name))
      (assert-equal 0 (rule-order-counter)))

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

    (hooks-default
      ;; forward-reference 钩子默认值:matcher 朴素相等、judge 返回 #f。
      (assert-true  ((current-regexp-matcher) "abc" "abc"))
      (assert-false ((current-regexp-matcher) "abc" "xyz"))
      (assert-false ((current-fingerprint-judge) "any.so"))
      (assert-false ((current-compile-needed) #f #f)))

    (hooks-register
      ;; 注册后,钩子调用注册的过程;测试结束复位(别污染其他 suite)。
      (current-regexp-matcher (lambda (pat s) #t))
      (assert-true  ((current-regexp-matcher) "x" "y"))
      (current-regexp-matcher (lambda (pat s) #f))
      (assert-false ((current-regexp-matcher) "x" "y"))
      (current-regexp-matcher (lambda (pattern s) (string=? pattern s))))

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
