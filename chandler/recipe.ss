#!chezscheme
;;; chandler/recipe.ss --- recipe DSL 宏 + 注册器 + recipe 加载(dev-time 层)
;;;
;;; 来源:bake/dsl.ss(§7 宏 + §8 注册器)+ bake/loader.ss(§9 加载)+
;;; bake/runtime.ss 的 recipe 面辅助(run/run-capture/displayln/file->*)。
;;; 注意:本文件是**库** (chandler recipe)——task-DSL 与加载器的实现;项目根的
;;; 构建描述文件叫 `chandler-tasks.ss`(default-tasks-file,原名 recipe.ss),是被本库
;;; load-recipe 加载的**程序**,不要与本库混淆。(库名保留 "recipe" 作内部概念名。)
;;;
;;; load-based → library 的两处改写:
;;;   1. recipe.ss 原先 eval 进 (interaction-environment),能看见 bake 全部顶层绑定。
;;;      library 词法封闭,故改为按 recipe-environment-libs 组装一个**可变**环境
;;;      (copy-environment;recipe 里的 (define …) 需要可变环境)。B4/B5 吸收后
;;;      往这个 parameter 上追加 (chandler compile)/(chandler native-build) 即可。
;;;   2. native-task 的 loader 预扫(bake/native.ss)是 forward reference,
;;;      改 current-native-prescan 参数钩子;B5 注册,未注册时是 no-op。

(library (chandler recipe)
  (export
    ;; DSL 宏(recipe.ss 表面)
    task file rule default-task define-clause-task displayln
    ;; clause 读取(native-task 等 clause 形任务的 handler 用)
    %clause %clause-req
    ;; 注册器
    register-task! register-rule! register-default-task!
    ;; recipe 加载 + 目标调用
    load-recipe reset-registries! recipe-environment-libs recipe-environment
    register-recipe-library! recipe-reset-hooks register-recipe-reset!
    invoke-task normalize-target select-targets
    ;; forward-reference 钩子(B5 native 注册)
    current-native-prescan
    ;; recipe 面辅助(designs/02 §辅助函数)
    path-ext file->string file->lines run run/code run/capture shq
    ;; 项目构建描述文件的默认名(用户可见约定;与数据文件 manifest.ss 配对)
    default-tasks-file)
  (import (chezscheme)
          (chandler base)
          (chandler task-engine)
          (chandler miniregex))

  ;; 项目构建描述文件默认名(2026-07-24:原 bake 的 `recipe.ss` → chandler 命名)。
  ;; 它是**程序**(task/file/rule/default-task,加载即求值),与**数据**文件
  ;; manifest.ss 配对;是可选的(B6b:无它则 `chandler build` 从 manifest 推导)。
  (define default-tasks-file "chandler-tasks.ss")

  ;; ====================================================================
  ;; §7 DSL 宏 — designs/02 §宏签名(来自 bake/dsl.ss)
  ;; ====================================================================

  ;; clause-task 基础设施:工具任务(native-task 等)共用同一表面形状
  ;; (X-task 'name (key val …) …),把 clause 列表 quote 给运行时 handler。
  ;; define-clause-task 负责写出那个宏;%clause / %clause-req 读解析后的 clause。
  (define-syntax define-clause-task
    (syntax-rules ()
      ((_ macro-name handler)
       (define-syntax macro-name
         (syntax-rules ()
           ((_ name clause (... ...)) (handler name '(clause (... ...)))))))))

  (define (%clause key clauses default)
    (let ((c (assq key clauses)))
      (if c (cadr c) default)))

  ;; 必填 clause:缺失时给统一、可操作的报错。`what` 是消息里的占位符,如 "<backend>"。
  (define (%clause-req task-kind name key what clauses)
    (or (%clause key clauses #f)
        (bail-config "~a ~a: missing (~a ~a) clause" task-kind name key what)))

  ;; (default-task 'name) — 符号或字符串皆可
  (define-syntax default-task
    (lambda (x)
      (syntax-case x (quote)
        ;; quote 符号形
        ((_ (quote name))
         #'(begin
             (default-task-name 'name)
             (register-default-task! 'name)))
        ;; 字面字符串形(字符串即数据,不需 quote)
        ((_ name)
         (string? (syntax->datum #'name))
         #'(begin
             (default-task-name name)
             (register-default-task! name))))))

  (define (register-default-task! name)
    (when (not (or (symbol? name) (string? name)))
      (bail-config "default task name must be symbol or string, got ~s" name))
    ;; 符号默认任务必须已声明为 phony —— 符号从不被惰性物化。字符串默认任务
    ;; 可能是 file 任务 / rule 目标 / 源文件,都惰性解析,推迟到 load-recipe
    ;; 末尾那次 resolve 校验(designs/02 §default-task)。
    (when (and (symbol? name) (not (hashtable-ref task-registry name #f)))
      (bail-config "default task not declared: ~s" name)))

  ;; (task 'name ...) — 见 designs/02 §宏签名。`name` 必须是 quote 的符号。
  ;; 2 参形按形状消歧:列表字面量('(…) 或 (list …))是 prereqs(2b,无 action);
  ;; 其余是 action(2a)。
  (define-syntax task
    (lambda (x)
      (syntax-case x (quote list)
        ((_ (quote name))
         #'(register-task! 'name 'phony '() #f #f))
        ((_ (quote name) (quote prereqs))              ; 2b: '(…) prereqs,无 action
         #'(register-task! 'name 'phony 'prereqs #f #f))
        ((_ (quote name) (list p ...))                 ; 2b: (list …) prereqs,无 action
         #'(register-task! 'name 'phony (list p ...) #f #f))
        ((_ (quote name) action)                       ; 2a: action
         #'(register-task! 'name 'phony '() action #f))
        ((_ (quote name) prereqs action)
         #'(register-task! 'name 'phony prereqs action #f))
        ((_ (quote name) description prereqs action)
         #'(register-task! 'name 'phony prereqs action description))
        ((_ nm . rest)
         (errorf 'task "task name must be a quoted symbol like 'build, got ~s"
                 (syntax->datum #'nm))))))

  ;; (file "target" ...) — `target` 必须是字符串。同样的 2b 消歧。
  (define-syntax file
    (lambda (x)
      (define (check-target stx)
        (or (string? (syntax->datum stx))
            (error 'file "file target must be string, got ~s" (syntax->datum stx))))
      (syntax-case x (quote list)
        ((_ target)
         (check-target #'target)
         #'(register-task! target 'file '() #f #f))
        ((_ target (quote prereqs))                    ; 2b: '(…) prereqs,无 action
         (check-target #'target)
         #'(register-task! target 'file 'prereqs #f #f))
        ((_ target (list p ...))                       ; 2b: (list …) prereqs,无 action
         (check-target #'target)
         #'(register-task! target 'file (list p ...) #f #f))
        ((_ target action)                             ; 2a: action
         (check-target #'target)
         #'(register-task! target 'file '() action #f))
        ((_ target prereqs action)
         (check-target #'target)
         #'(register-task! target 'file prereqs action #f))
        ((_ target description prereqs action)
         (check-target #'target)
         #'(register-task! target 'file prereqs action description)))))

  ;; (rule pattern prereq-fn ...)
  (define-syntax rule
    (lambda (x)
      (syntax-case x ()
        ((_ pattern prereq-fn)
         #'(register-rule! pattern prereq-fn #f #f))
        ((_ pattern prereq-fn action)
         #'(register-rule! pattern prereq-fn action #f))
        ((_ pattern description prereq-fn action)
         #'(register-rule! pattern prereq-fn action description)))))

  ;; ====================================================================
  ;; §8 注册器 — designs/03 §registry(来自 bake/dsl.ss)
  ;;   rule-order-counter / default-task-name 在 task-engine 里是 parameter
  ;;   (R6RS library 不能 export 被 set! 的变量),故 set! → 调用。
  ;; ====================================================================

  (define (register-task! name kind prereqs action description)
    (when (and (eq? kind 'phony) (not (symbol? name)))
      (bail-config "task name must be symbol, got ~s" name))
    (when (and prereqs (not (list? prereqs)))
      (bail-config "prereqs must be list, got ~s" prereqs))
    (when (and description (not (string? description)))
      (bail-config "description must be string, got ~s" description))
    (when (and action (not (procedure? action)))
      (bail-config "action must be procedure, got ~s" action))
    (let ((t (make-task name kind prereqs action description #f #f #f)))
      (hashtable-set! task-registry name t)
      t))

  (define (register-rule! pattern prereq-fn action description)
    (unless (or (miniregex? pattern) (procedure? pattern) (string? pattern))
      (bail-config "rule pattern must be regex, got ~s" pattern))
    (unless (procedure? prereq-fn)
      (bail-config "prereq-fn must be procedure, got ~s" prereq-fn))
    (when (and action (not (procedure? action)))
      (bail-config "rule action must be procedure, got ~s" action))
    (let* ((pattern-obj (cond ((miniregex? pattern) pattern)
                              ((string? pattern)    (regexp pattern))
                              (else pattern)))
           (r (make-rule pattern-obj prereq-fn action description
                         (rule-order-counter))))
      (rule-order-counter (+ (rule-order-counter) 1))
      (hashtable-set! rule-registry (rule-order r) r)))

  ;; ====================================================================
  ;; §4 recipe 面辅助 — designs/02 §辅助函数(来自 bake/runtime.ss)
  ;;   path-root/path-swap-ext/mtime/file-exists? 等由 (chezscheme)+(chandler base)
  ;;   提供,这里只补 base 没有的几个 + 子进程封装。
  ;;   子进程签名与 (chandler proc) 的 run-capture/run-check 不兼容(可变参数
  ;;   vs 列表参数),recipe 表面沿用 bake 形状,不 alias。
  ;; ====================================================================

  (define (path-ext p)
    ;; 末尾扩展名,不含点。"build/out.txt" → "txt";"no-ext" → #f
    (let ((dot (let loop ((i (- (string-length p) 1)))
                 (cond
                   ((< i 0) #f)
                   ((char=? (string-ref p i) #\.) i)
                   (else (loop (- i 1)))))))
      (cond
        ((not dot) #f)
        ((= dot 0) p)                       ; ".foo" —— root 为空
        (else (substring p (+ dot 1) (string-length p))))))

  (define (file->string path)
    (call-with-input-file path
      (lambda (p)
        (let ((s (get-string-all p)))
          (if (eof-object? s) "" s)))))

  (define (file->lines path)
    (call-with-input-file path
      (lambda (p)
        (let loop ((lines '()))
          (let ((l (get-line p)))
            (if (eof-object? l)
                (reverse lines)
                (loop (cons l lines))))))))

  ;; shell 引用:路径没有 shell 特殊字符,双引号足够(与 (chandler proc) 的
  ;; shell-quote 单引号转义并存 —— 后者用于 exec 一族,这里用于拼 sh 命令串)。
  (define (shq s) (string-append "\"" s "\""))

  ;; Chez 的 `system` 只收一条命令串(交 /bin/sh),返回退出码;这里把 argv 用空格拼上。
  (define (%arg->string a) (if (string? a) a (format-object a)))

  (define (%join-args args)
    (let loop ((xs args) (acc ""))
      (cond
        ((null? xs) acc)
        ((string=? acc "") (loop (cdr xs) (%arg->string (car xs))))
        (else (loop (cdr xs)
                    (string-append acc " " (%arg->string (car xs))))))))

  (define %capture-counter 0)

  (define (run/code . args)
    ;; 经 shell 跑,返回退出码。不抛。
    (system (%join-args args)))

  (define (run . args)
    ;; 跑命令;非零即抛 —— 构建工具的安全默认(designs/02)。
    (let ((code (system (%join-args args))))
      (unless (= code 0)
        (errorf 'run "command exited with ~s: ~a" code (%join-args args)))))

  (define (run/capture . args)
    ;; 跑命令,返回 stdout 字符串;非零即抛。临时名带 pid,并发 bake 进程不撞。
    (set! %capture-counter (+ %capture-counter 1))
    (let* ((cmd (%join-args args))
           (tmp (string-append "/tmp/chandler-capture-"
                               (number->string (get-process-id)) "-"
                               (number->string %capture-counter)))
           (code (system (string-append cmd " > " tmp))))
      (let ((out (if (file-exists? tmp) (file->string tmp) "")))
        (when (file-exists? tmp) (delete-file tmp))
        (unless (= code 0)
          (errorf 'run/capture "command exited with ~s: ~a" code cmd))
        out)))

  (define-syntax displayln
    (syntax-rules ()
      ((displayln . args)
       (begin
         (for-each display (list . args))
         (newline)))))

  ;; ====================================================================
  ;; §9 recipe.ss 加载 — designs/04 §recipe.ss 加载机制(来自 bake/loader.ss)
  ;; ====================================================================

  ;; recipe 求值环境的组成。B4/B5 吸收后在此追加 (chandler compile) /
  ;; (chandler native-build),recipe 即可见 library-task / native-task。
  (define recipe-environment-libs
    (make-parameter
      '((chezscheme) (chandler base) (chandler task-engine) (chandler recipe))
      (lambda (ls)
        (unless (and (list? ls) (for-all list? ls))
          (error 'recipe-environment-libs "not a list of library references" ls))
        ls)))

  ;; 把一个库追加进 recipe 环境(幂等)。B4/B5 在自己的库体里调用,于是「谁提供
  ;; recipe 面 API」这件事由提供者自己声明,不必回头改本文件。
  (define (register-recipe-library! libref)
    (unless (member libref (recipe-environment-libs))
      (recipe-environment-libs (append (recipe-environment-libs) (list libref)))))

  ;; 每次 load-recipe 前跑一遍的复位钩子,alist:(key . thunk),按 key 去重。
  ;;
  ;; **为什么需要**:bake 是「一次调用 = 一个进程」,全局构建状态(编译节点表、
  ;; 指纹缓存、WPO 开关、codegen 根)靠进程退出复位。chandler 是单二进制、且
  ;; (chandler compile) 是**库**,同一进程里连着建两次是自然用法 —— 那样第二次
  ;; 会读到第一次的指纹缓存,内容真改了也判成「无需重编」。故把复位显式化。
  (define recipe-reset-hooks (make-parameter '()))

  (define (register-recipe-reset! key thunk)
    (recipe-reset-hooks
      (cons (cons key thunk)
            (remp (lambda (p) (eq? (car p) key)) (recipe-reset-hooks)))))

  (define (recipe-environment)
    ;; 每次加载现组一个**可变**环境:recipe 顶层可以 (define …),且上一份 recipe
    ;; 的定义不会渗进下一份。
    (copy-environment (apply environment (recipe-environment-libs))))

  ;; native-task 的 loader 预扫钩子(B5 的 (chandler native-build) 注册)。
  (define current-native-prescan
    (make-parameter
      (lambda (forms) (void))
      (lambda (f)
        (unless (procedure? f) (error 'current-native-prescan "not a procedure"))
        f)))

  ;; 把任务/规则登记表与全局构建状态清干净。load-recipe 的前奏,但**单独导出** ——
  ;; `chandler build` 是直接调 library-task/native-task 排单的(没有 recipe 文件可
  ;; 加载),它同样需要每轮从干净状态起步。
  (define (reset-registries!)
    (hashtable-clear! task-registry)
    (hashtable-clear! rule-registry)
    (rule-order-counter 0)
    (default-task-name #f)
    (*rule-depth* 0)
    (*exit-code* exit-ok)
    (for-each (lambda (p) ((cdr p))) (recipe-reset-hooks)))

  (define (load-recipe path)
    (reset-registries!)
    (*current-recipe* path)
    (with-exception-handler
      (lambda (e)
        (cond
          ((eq? e 'bake-error)
           (unless (> (*exit-code*) exit-ok) (*exit-code* exit-config-error))
           (raise 'bake-error))
          (else
           (eprintf "chandler: error: failed to load tasks file: ~a~%  Cause: ~a~%"
                    path (condition->string-fallback e))
           (*exit-code* exit-config-error)
           (raise 'bake-error))))
      (lambda ()
        ;; 先把整份 recipe **读完**,再预扫 native-task 声明、生成 loader 库
        ;; (designs/24),然后才逐 form 求值。必须如此:library-task /
        ;; program-task 在**求值当时**就跑 build-graph,而 build-graph 解析不到
        ;; 的库会报错 —— 生成的 (<lib> native-loader) 源码那时必须已在磁盘上,
        ;; 无论 recipe 里 native-task 是否写在前面。
        (let ((forms (let ((p (open-input-file path)))
                       (let loop ((acc '()))
                         (let ((form (read p)))
                           (cond
                             ((eof-object? form) (close-port p) (reverse acc))
                             (else (loop (cons form acc)))))))))
          ((current-native-prescan) forms)
          (let ((env (recipe-environment)))
            (for-each (lambda (form) (eval form env)) forms)))
        ;; 声明了 default-task 就确认它可解析 —— 走 resolve 让 rule 物化 /
        ;; 源文件合成生效,undefined-task 在这里就暴露(config error,退出 2)。
        (when (default-task-name)
          (guard (e (#t
                      (*exit-code* exit-config-error)
                      (raise 'bake-error)))
            (resolve (default-task-name)))))))

  ;; ====================================================================
  ;; §16 目标选择(来自 bake/dispatch.ss;CLI 接线在 B6)
  ;; ====================================================================

  ;; argv 恒是字符串,而 phony 任务登记在**符号**键下(`(task 'smoke …)`),
  ;; file 目标用字符串键。裸字符串 "smoke" 因此错过 task-registry、落到文件路径
  ;; 分支 → "missing prerequisite"。故优先试符号;无对应 phony 时保留字符串
  ;; (file 目标 / rule 目标 / 磁盘上的路径)。
  (define (normalize-target s)
    (if (string? s)
        (let ((sym (string->symbol s)))
          (if (hashtable-ref task-registry sym #f) sym s))
        s))

  (define (select-targets cli-tasks)
    (cond
      ((null? cli-tasks)
       (cond
         ((not (default-task-name))
          (bail-config "no default task defined; specify a task name or call (default-task ...) in recipe.ss"))
         (else (list (default-task-name)))))
      (else (map normalize-target cli-tasks))))

  (define (invoke-task name)
    (invoke (normalize-target name) '()))

  )
