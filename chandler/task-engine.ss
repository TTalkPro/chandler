#!chezscheme
;;; chandler/task-engine.ss --- bake task-engine 抽取为 library(designs/12 dev-time 层)
;;;
;;; 来源:bake/records.ss + bake/globals.ss + bake/util.ss(bail-*)+
;;; bake/loader.ss(condition->string-fallback)+ bake/output.ss + bake/engine.ss。
;;; 对 B4(compile)/B5(miniregex)的 forward reference 用 make-parameter 钩子桥接
;;; (load-based bake 靠运行时符号解析;library 词法封闭,故改参数注册):
;;;   current-regexp-matcher   ← miniregex 注册 regexp-match?
;;;   current-fingerprint-judge ← compile 注册 fingerprint-target?
;;;   current-compile-needed   ← compile 注册 needed-compile?

(library (chandler task-engine)
  (export
    ;; records(task/rule/miniregex + accessors)
    make-task task? task-name task-name-set!
    task-kind task-kind-set! task-prereqs
    task-action task-description
    task-invoked? task-invoked?-set! task-executed? task-executed?-set!
    task-failed? task-failed?-set!
    make-rule rule? rule-pattern rule-prereq-fn rule-action rule-description rule-order
    make-miniregex miniregex? miniregex-atoms miniregex-start-anchored? miniregex-end-anchored?
    ;; registries(可变,dsl set!)
    task-registry rule-registry default-task-name rule-order-counter
    ;; globals
    bake-version rule-recursion-limit *optimize-level*
    exit-ok exit-exec-error exit-config-error exit-usage-error exit-internal
    *dry-run* *quiet* *verbose* *trace* *all-tasks* *exit-code* *current-recipe* *rule-depth*
    ;; bail + condition
    bail-exec bail-config condition->string-fallback
    ;; output
    show-begin show-done show-skip-dryrun join-chain
    ;; engine
    sort-rules resolve materialize-rule invoke execute
    needed? needed?/mtime filter-map task-deps
    ;; hooks(make-parameter,桥接 B4/B5 forward reference)
    current-regexp-matcher current-fingerprint-judge current-compile-needed)
  (import (chezscheme) (chandler base))

  ;; ====================================================================
  ;; §records — designs/03 §数据结构(来自 bake/records.ss)
  ;; ====================================================================

  (define-record-type task
    (fields (mutable name)            ; symbol | string
            (mutable kind)            ; 'phony | 'file
            (mutable prereqs)         ; list of (symbol | string)
            (mutable action)          ; proc | #f
            (mutable description)     ; string | #f
            (mutable invoked?)        ; boolean
            (mutable executed?)       ; boolean
            (mutable failed?)))       ; boolean

  (define-record-type rule
    (fields (immutable pattern)       ; miniregex
            (immutable prereq-fn)
            (immutable action)
            (immutable description)
            (immutable order)))

  (define-record-type miniregex
    (fields atoms start-anchored? end-anchored?))

  ;; ── §2 Registries — designs/03 §registry ──
  ;; task-registry/rule-registry 是 hashtable,内容可变但变量本身不被 set!,故可直接 export。
  ;; default-task-name/rule-order-counter 被 dsl 的 set!,用 parameter(R6RS library 不能 export assigned variable)。
  (define task-registry      (make-hashtable equal-hash equal?))
  (define rule-registry      (make-eqv-hashtable))
  (define default-task-name  (make-parameter #f))
  (define rule-order-counter (make-parameter 0))

  ;; ====================================================================
  ;; §globals — designs/04(来自 bake/globals.ss)
  ;; ====================================================================

  (define bake-version "0.1.5")
  (define rule-recursion-limit 16)
  ;; Injected compile flag(designs/07 §编译动作). Env-overridable so a flag
  ;; change can be exercised without touching sources (I7).
  (define *optimize-level*
    (let ((e (getenv "BAKE_OPTIMIZE_LEVEL")))
      (or (and e (string->number e)) 2)))

  ;; Exit codes(designs/04 §退出码)
  (define exit-ok           0)
  (define exit-exec-error   1)
  (define exit-config-error 2)
  (define exit-usage-error  64)
  (define exit-internal     70)

  ;; State set by parsing CLI / running recipe — parameter 化(R6RS library 不能 export 被 set! 的变量)。
  ;; 约定:access `(*x*)`、set `(*x* v)`;星号名保留以最小化 bake 侧改写(只需 set!→调用、读取→加括号)。
  (define *dry-run*        (make-parameter #f))
  (define *quiet*          (make-parameter #f))
  (define *verbose*        (make-parameter #t))
  (define *trace*          (make-parameter #f))
  (define *all-tasks*      (make-parameter #f))
  (define *exit-code*      (make-parameter exit-ok))
  (define *current-recipe* (make-parameter #f))

  ;; Engine state
  (define *rule-depth*     (make-parameter 0))

  ;; ====================================================================
  ;; §bail — designs/04 §错误输出格式(来自 bake/util.ss)
  ;; ====================================================================

  ;; 前缀用 chandler(吸收后 bake 二进制作废,用户见到的工具名只有 chandler);
  ;; 内部哨兵符号仍是 'bake-error —— 它不面向用户,改名要连累 B4/B5 全部搬运。
  (define (bail-exec fmt . args)
    ;; Execution-time error → exit code 1.
    (apply eprintf (string-append "chandler: error: " fmt "\n") args)
    (*exit-code* exit-exec-error)
    (raise 'bake-error))

  (define (bail-config fmt . args)
    (apply eprintf (string-append "chandler: error: " fmt "\n") args)
    (*exit-code* exit-config-error)
    (raise 'bake-error))

  ;; ====================================================================
  ;; §condition(来自 bake/loader.ss)— 把 condition 渲染成可读字符串
  ;; ====================================================================

  (define (condition->string-fallback e)
    ;; Render a condition the way Chez's REPL would (message + who + irritants).
    (cond
      ((condition? e)
       (let ((p (open-output-string)))
         (display-condition e p)
         (get-output-string p)))
      (else (format-object e))))

  ;; ====================================================================
  ;; §output — designs/04 §输出格式(来自 bake/output.ss)
  ;; ====================================================================

  (define (show-begin t)
    (cond
      ((*quiet*) (void))
      (else
       (display "→ ")
       (display (task-name t))
       (cond
         ((not (task-action t))
          (display " (source)"))
         ((eq? (task-kind t) 'phony)
          (display " (phony)"))
         (else
          (display " (file)")))
       (newline))))

  (define (show-done t)
    (unless (*quiet*)
      (display "✓ ") (display (task-name t)) (newline)))

  (define (show-skip-dryrun t)
    (display "[dry-run] would execute: ")
    (display (task-name t))
    (newline))

  (define (join-chain names)
    ;; Join with the Unicode arrow " → " as required by designs/03.
    (let loop ((xs names) (acc ""))
      (cond
        ((null? xs) acc)
        ((string=? acc "") (loop (cdr xs) (format-object (car xs))))
        (else (loop (cdr xs)
                    (string-append acc " → " (format-object (car xs))))))))

  ;; ====================================================================
  ;; §hooks — make-parameter 桥接,resolve B4/B5 forward reference
  ;; ====================================================================

  (define current-regexp-matcher
    (make-parameter
      (lambda (pattern s) (string=? pattern s))    ; 默认:朴素相等(无 rule 时用)
      (lambda (f) (unless (procedure? f) (error 'current-regexp-matcher "not a procedure")) f)))

  (define current-fingerprint-judge
    (make-parameter
      (lambda (name) #f)                           ; 默认:无文件走指纹(全走 mtime)
      (lambda (f) (unless (procedure? f) (error 'current-fingerprint-judge "not a procedure")) f)))

  (define current-compile-needed
    (make-parameter
      (lambda (t dry?) #f)                         ; 默认:不触发重编
      (lambda (f) (unless (procedure? f) (error 'current-compile-needed "not a procedure")) f)))

  ;; ====================================================================
  ;; §engine — designs/03 §任务解析 + §拓扑执行算法(来自 bake/engine.ss)
  ;;   forward reference 改用钩子:resolve 的 regexp-match?、needed? 的
  ;;   fingerprint-target?/needed-compile? 分别走 current-*-parameter。
  ;; ====================================================================

  (define (sort-rules)
    (let loop ((i 0) (acc '()))
      (let ((r (hashtable-ref rule-registry i #f)))
        (if r
            (loop (+ i 1) (cons r acc))
            (reverse acc)))))

  (define (resolve name)
    (cond
      ((hashtable-ref task-registry name #f)
       => (lambda (t) t))
      ((string? name)
       (let loop ((rules (sort-rules)))
         (cond
           ((null? rules)
            (if (file-exists? name)
                (let ((t (make-task name 'file '() #f #f #f #f #f)))
                  (hashtable-set! task-registry name t)
                  t)
                (bail-exec "missing prerequisite: ~a" name)))
           (else
            (let ((r (car rules)))
              (if ((current-regexp-matcher) (rule-pattern r) name)
                  (materialize-rule r name)
                  (loop (cdr rules))))))))
      (else
       (bail-exec "undefined task: ~s" name))))

  (define (materialize-rule r target)
    (when (>= (*rule-depth*) rule-recursion-limit)
      (bail-exec "rule recursion too deep (limit ~a)" rule-recursion-limit))
    (*rule-depth* (+ (*rule-depth*) 1))
    (let ((prereqs
           (guard (e (#t
                       (bail-exec "rule prereq-fn threw for ~a: ~a"
                                  target (condition->string-fallback e))))
                  ((rule-prereq-fn r) target))))
      (*rule-depth* (- (*rule-depth*) 1))
      (let ((t (make-task target 'file prereqs
                          (rule-action r) (rule-description r)
                          #f #f #f)))
        (hashtable-set! task-registry target t)
        t)))

  (define (invoke name stack)
    ;; Cycle detection FIRST. Per designs/03 §拓扑执行算法 / §Cycle-free.
    (when (member name stack)                      ; equal? member — handles symbol|string
      (bail-exec "cyclic dependency: ~a" (join-chain (append stack (list name)))))
    (let ((t (resolve name)))
      ;; run-once: an already-invoked (black) task returns immediately.
      (unless (task-invoked? t)
        (task-invoked?-set! t #t)
        (when (*trace*)
          (eprintf "[trace] invoke ~a~a~%" (task-name t)
                   (if (null? stack) "" (string-append " <- " (join-chain stack)))))
        (let ((new-stack (append stack (list name))))
          (for-each (lambda (p) (invoke p new-stack)) (task-prereqs t))
          (cond
            ((needed? t) (execute t))
            ((*trace*) (eprintf "[trace] skip ~a (up-to-date)~%" (task-name t))))))))

  (define (execute t)
    (cond
      ((not (task-action t))
       (void))
      ((task-executed? t)
       (void))
      ((*dry-run*)
       ;; Dry-run: print only the execution plan, no →/✓ decoration
       ;; (designs/03 §Dry-run).
       (task-executed?-set! t #t)
       (show-skip-dryrun t))
      (else
       (task-executed?-set! t #t)
       (show-begin t)
       (guard (e ((eq? e 'bake-error) (raise e))  ; already reported downstream
                  (#t
                   (task-failed?-set! t #t)
                   (eprintf "chandler: error: task ~a failed~%  Exception: ~a~%"
                            (task-name t) (condition->string-fallback e))
                   (*exit-code* exit-exec-error)
                   (raise 'bake-error)))
         (let ((action (task-action t))
               (name   (task-name t))
               (kind   (task-kind t)))
           (case kind
             ((phony) (action))
             ((file) (action name (task-deps t))))))
       (show-done t))))

  (define (needed? t)
    ;; Fingerprinted file targets (compiled libs, iteration 2; and custom
    ;; providers like native backends, designs/20) use fingerprint invalidation;
    ;; everything else uses the iteration-1 mtime check.
    (if (and (eq? (task-kind t) 'file)
             ((current-fingerprint-judge) (task-name t)))
        ((current-compile-needed) t #f)
        (needed?/mtime t)))

  (define (needed?/mtime t)
    (case (task-kind t)
      ((phony) #t)
      ((file)
       (cond
         ((not (file-exists? (task-name t)))
          #t)
         (else
          (let ((target-mtime (file-modification-time (task-name t))))
            (let loop ((ps (task-prereqs t)) (needed? #f))
              (cond
                ((null? ps) needed?)
                (else
                 (let* ((pname (car ps))
                        (ptask (resolve pname)))
                   (cond
                     ((eq? (task-kind ptask) 'file)
                      (cond
                        ((not (file-exists? pname))
                         (bail-exec
                           "missing prerequisite file: ~a (required by ~a)"
                           pname (task-name t)))
                        (else
                         (let ((pmtime (file-modification-time pname)))
                           (loop (cdr ps)
                                 (or needed? (time>? pmtime target-mtime)))))))
                     (else (loop (cdr ps) needed?)))))))))))))

  (define (task-deps t)
    (filter-map
      (lambda (p)
        (let ((pt (resolve p)))
          (and (eq? (task-kind pt) 'file) (task-name pt))))
      (task-prereqs t)))

  )
