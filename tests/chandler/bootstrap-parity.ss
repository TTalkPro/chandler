#!chezscheme
;;; tests/chandler/bootstrap-parity.ss --- bootstrap.ss 与库侧策略表的 parity
;;;
;;; bootstrap.ss 有条**自包含红线**:纯 (chezscheme)、零 chandler import ——
;;; chandler 库坏了它也得能装。代价是它必须自带一份最小 stdlib,那部分是纯
;;; 管道(dirname/join-paths/rm-rf …),各写一份无所谓,反正行为由 Chez 定死。
;;;
;;; 但有两块**不是**管道,是策略 —— 它们编码的是「chandler 装到哪里」和
;;; 「用哪个运行时跑」,而库侧对同一问题另有一份权威实现:
;;;
;;;   ① 安装前缀   bootstrap 的 target-libdir / target-bindir
;;;              ↔ (chandler registry) 的 default-{user,system}-{libdir,bindir}
;;;   ② 运行时选择 bootstrap 的 interp 表达式
;;;              ↔ (chandler cli runtime-env) 的 choose-interp
;;;
;;; 两边分叉的后果很难查:bootstrap 把 chandler 装到 A,而装好的 chandler 自己
;;; 认为它该在 B —— 安装看起来成功,后续每条命令都找不到东西。
;;;
;;; 本 suite 的做法与 pack-verifier-parity 同构:**不重新实现** bootstrap 的
;;; 逻辑(那只会变成第三份副本),而是把 bootstrap.ss 当**数据**读进来,按名字
;;; 抽出那几个 define,eval 进一个干净的 (chezscheme) 环境,再逐条比对。
;;; 于是任何人改了 bootstrap 那两块而没同步库侧(或反过来),这里当场红。

(library (tests chandler bootstrap-parity)
  (export suite)
  (import (chezscheme)
          (tests chandler harness)
          (tests chandler fixtures)
          (chandler util)
          (chandler proc)
          (chandler fs)
          (chandler layout)
          (chandler registry)
          (chandler runtime-detector)
          (chandler cli runtime-env))

  ;; ── 定位 bootstrap.ss ──
  ;; 测试从仓库根跑(run-tests.sps 的约定),故相对路径即可;找不到就硬错 ——
  ;; 「文件不在」必须是失败,不能让 suite 静默跳过它要守的那条线。
  (define bootstrap-path "bootstrap.ss")

  (define (bootstrap-forms)
    (unless (file-exists? bootstrap-path)
      (error 'bootstrap-parity
             (format "~a not found; parity suite must run from the repo root"
                     bootstrap-path)))
    ;; 首行是 `#!/usr/bin/env scheme-script`。read 不吃它(`#!` 后面只认
    ;; chezscheme/r6rs/eof 之类的 datum 指示符),故照 Chez --script 的办法
    ;; 先把 shebang 那行剥掉,再从字符串端口读。
    (let* ([text (read-file-string bootstrap-path)]
           [body (if (string-prefix? "#!/" text)
                     (let ([nl (char-index text #\newline)])
                       (if nl (substring text (+ nl 1) (string-length text)) ""))
                     text)])
      (let ([p (open-input-string body)])
        (let loop ([acc '()])
          (let ([x (read p)])
            (if (eof-object? x) (reverse acc) (loop (cons x acc))))))))

  ;; 顶层 define 的被定义名:(define (f a) …) → f;(define x …) → x
  (define (define-name form)
    (and (pair? form) (eq? (car form) 'define) (pair? (cdr form))
         (let ([t (cadr form)])
           (if (pair? t) (car t) t))))

  ;; 按名字取 bootstrap 里的那条 define。取不到即硬错(名字被改了 = 这份
  ;; parity 已经失效,必须有人来看,不能假装通过)。
  (define (bootstrap-define forms name)
    (or (find (lambda (f) (eq? name (define-name f))) forms)
        (error 'bootstrap-parity
               (format "bootstrap.ss has no top-level definition of `~a`; parity test needs updating"
                       name))))

  ;; ── 把 bootstrap 的一组定义 eval 进干净环境 ──
  ;; 依赖(join-paths / win? / getenv* / mt-string …)同样从 bootstrap.ss 抽,
  ;; **不**在测试里另写 —— 否则测的就是测试自己的副本,不是 bootstrap 那份。
  (define (bootstrap-env names)
    (let ([forms (bootstrap-forms)]
          [env (copy-environment (environment '(chezscheme)))])
      (for-each (lambda (n) (eval (bootstrap-define forms n) env)) names)
      env))

  ;; ① 安装前缀:target-libdir / target-bindir 依赖 win? / getenv* / join-paths / home
  (define (prefix-env)
    (bootstrap-env '(join-paths mt-string win? getenv* home
                     target-libdir target-bindir)))

  ;; ② 运行时选择:interp 是个**顶层值**,求值时点就读 env,故每次比对都要在
  ;;    改完环境变量之后重新 eval 一遍它。running-skiff? 换成受控桩:探测
  ;;    「当前跑在什么运行时上」不是本 parity 要守的东西(那是 runtime-detector
  ;;    的契约,已有它自己的测试),这里守的是 **env 三变量 → 可执行文件名**
  ;;    这张表。die 同样打桩:非法值两侧都该拒,但一个 exit、一个 raise。
  (define (interp-under rt-kind)
    (let ([env (bootstrap-env '(getenv* skiff-exe chez-exe))])
      (eval `(define (running-skiff?) ,(eq? rt-kind 'skiff)) env)
      (eval '(define (die code fmt . args) (raise (cons 'bootstrap-die code))) env)
      (eval (bootstrap-define (bootstrap-forms) 'interp) env)
      (eval 'interp env)))

  ;; 库侧:choose-interp 在**无 manifest** 的目录上跑 —— bootstrap 没有项目
  ;; 上下文,故只比 env 那一维(manifest 维是 chandler 独有的,不在契约里)。
  ;; runtime-detector 的 current-runtime 靠顶层 skiff-version 探测,按它对外
  ;; 声明的探测面装桩(与 pack-verifier-parity 的 with-runtime 同法)。
  (define (with-runtime rt thunk)
    (let ([had? (top-level-bound? 'skiff-version)]
          [old  (and (top-level-bound? 'skiff-version) (top-level-value 'skiff-version))])
      (dynamic-wind
        (lambda () (define-top-level-value 'skiff-version (if (eq? rt 'skiff) "0.1.1" #f)))
        thunk
        (lambda () (define-top-level-value 'skiff-version (if had? old #f))))))

  ;; 空目录 = 无 manifest,于是 interp-kind 落到「跟随当前运行时」那条默认分支
  (define (library-interp rt-kind)
    (let ([d (mktmp)])
      (with-runtime rt-kind (lambda () (choose-interp d '())))))

  ;; 环境变量存取还原(Chez 删不掉变量,故「未设」用空串表示 —— 两侧的 getenv*
  ;; 都把空串当未设,这正是本 suite 要守的一致性之一)。
  (define (with-env kvs thunk)
    (let ([saved (map (lambda (kv) (cons (car kv) (or (getenv (car kv)) ""))) kvs)])
      (dynamic-wind
        (lambda () (for-each (lambda (kv) (putenv (car kv) (cdr kv))) kvs))
        thunk
        (lambda () (for-each (lambda (kv) (putenv (car kv) (cdr kv))) saved)))))

  (define-suite suite

    ;; ══ ① 安装前缀决策表 ══

    (prefix-parity-user
      ;; --user 的 lib/bin 必须与 registry 的 default-user-* 逐字相同 ——
      ;; 分叉即「装到 A、自己以为在 B」。
      (let ([env (prefix-env)])
        (assert-string= (default-user-libdir)
                        (eval '(target-libdir '(user)) env))
        (assert-string= (default-user-bindir)
                        (eval '(target-bindir '(user)) env))))

    (prefix-parity-system
      (let ([env (prefix-env)])
        (assert-string= (default-system-libdir)
                        (eval '(target-libdir '(system)) env))
        (assert-string= (default-system-bindir)
                        (eval '(target-bindir '(system)) env))))

    (prefix-parity-explicit-prefix
      ;; --prefix=DIR:lib = DIR 本身,bin = DIR/bin(这条没有库侧对应物 ——
      ;; cmd-install 收的就是算好的前缀 —— 但布局约定同属一张表,一并钉住)
      (let ([env (prefix-env)])
        (assert-string= "/opt/x" (eval '(target-libdir '(prefix . "/opt/x")) env))
        (assert-string= "/opt/x/bin" (eval '(target-bindir '(prefix . "/opt/x")) env))))

    ;; ══ ② 运行时选择决策表(designs/06 §3)══
    ;; 优先级:CHANDLER_RUNTIME > 当前所在运行时;
    ;; 「哪个可执行文件」由 CHANDLER_SKIFF / CHANDLER_SCHEME 定。

    (interp-parity-default-follows-current-runtime
      ;; 三个变量都未设:两侧都该跟随「当前跑在哪」
      (with-env '(("CHANDLER_RUNTIME" . "") ("CHANDLER_SKIFF" . "") ("CHANDLER_SCHEME" . ""))
        (lambda ()
          (assert-string= (library-interp 'chez)  (interp-under 'chez))
          (assert-string= (library-interp 'skiff) (interp-under 'skiff))
          ;; 顺带钉住具体值,免得两边一起错成同一个东西
          (assert-string= "scheme" (interp-under 'chez))
          (assert-string= "skiff"  (interp-under 'skiff)))))

    (interp-parity-runtime-env-var-wins
      ;; CHANDLER_RUNTIME 显式指定 → 压过「当前所在运行时」
      (with-env '(("CHANDLER_RUNTIME" . "chez") ("CHANDLER_SKIFF" . "") ("CHANDLER_SCHEME" . ""))
        (lambda ()
          (assert-string= (library-interp 'skiff) (interp-under 'skiff))
          (assert-string= "scheme" (interp-under 'skiff))))
      (with-env '(("CHANDLER_RUNTIME" . "skiff") ("CHANDLER_SKIFF" . "") ("CHANDLER_SCHEME" . ""))
        (lambda ()
          (assert-string= (library-interp 'chez) (interp-under 'chez))
          (assert-string= "skiff" (interp-under 'chez)))))

    (interp-parity-exe-override
      ;; CHANDLER_SKIFF / CHANDLER_SCHEME 选「哪个可执行文件」
      (with-env '(("CHANDLER_RUNTIME" . "") ("CHANDLER_SKIFF" . "/opt/skiff/bin/skiff")
                  ("CHANDLER_SCHEME" . "/opt/chez/bin/scheme"))
        (lambda ()
          (assert-string= (library-interp 'skiff) (interp-under 'skiff))
          (assert-string= (library-interp 'chez)  (interp-under 'chez))
          (assert-string= "/opt/skiff/bin/skiff" (interp-under 'skiff))
          (assert-string= "/opt/chez/bin/scheme" (interp-under 'chez)))))

    (interp-parity-empty-env-means-unset
      ;; Chez 的 putenv 删不掉变量,还原「未设」只能置 ""。两侧都必须把空串
      ;; 当没设 —— 否则 bootstrap 会拿 "" 去 exec 一个空命令名。
      ;; (bootstrap 先前用裸 getenv,正是在这里与库侧分叉。)
      (with-env '(("CHANDLER_RUNTIME" . "") ("CHANDLER_SKIFF" . "") ("CHANDLER_SCHEME" . ""))
        (lambda ()
          (assert-string= "skiff"  (interp-under 'skiff))
          (assert-string= "scheme" (interp-under 'chez))
          (assert-string= (library-interp 'skiff) (interp-under 'skiff)))))

    (interp-parity-invalid-runtime-rejected-both-sides
      ;; 非法 CHANDLER_RUNTIME:两侧都必须拒(bootstrap exit 64、库侧 raise)。
      ;; 形式不同是刻意的 —— bootstrap 是脚本,库侧是可被捕获的错误 ——
      ;; 但「不许静默回落到某个默认运行时」这条必须一致。
      (with-env '(("CHANDLER_RUNTIME" . "wat") ("CHANDLER_SKIFF" . "") ("CHANDLER_SCHEME" . ""))
        (lambda ()
          (assert-raises (lambda () (interp-under 'chez)))
          (assert-raises (lambda () (library-interp 'chez))))))

    ;; ══ ③ shell 引用 ══

    (bootstrap-shell-quote-parity
      ;; bootstrap 的 q 与 (chandler proc) 的 shell-quote 同语义。它引的全是
      ;; 真实路径(仓库根、前缀、解释器、libdirs),含 $ / 空格 / 单引号的路径
      ;; 必须原样穿过 /bin/sh —— 先前两边都是「加双引号」,而双引号内 $ ` \ "
      ;; 对 sh 仍然特殊。
      (let ([env (bootstrap-env '(q q-sh q-cmd win? mt-string die))])
        (eval '(define (win?) #f) env)          ; 钉在 POSIX 侧比
        (for-each
          (lambda (s)
            (assert-string= (parameterize ([windows-shell? #f]) (shell-quote s))
                            (eval `(q ,s) env)))
          (list "plain" "with space" "we$ird" "back`tick" "quo\"te" "sin'gle" ""))))

    ;; **Windows 侧同样要 parity**(D33)。bootstrap 是 Windows 上装 chandler 的
    ;; 唯一入口 —— 它的引用错了,后面什么都不用谈。两边都用 MSVCRT 反斜杠规则,
    ;; 逐字比对生成的串。
    (bootstrap-cmd-quote-parity
      (let ([env (bootstrap-env '(q q-sh q-cmd win? mt-string die))])
        (eval '(define (win?) #t) env)          ; 钉在 Windows 侧比
        (for-each
          (lambda (s)
            (assert-string= (parameterize ([windows-shell? #t]) (shell-quote s))
                            (eval `(q ,s) env)))
          (list "plain"
                "with space"
                "C:\\Users\\t\\proj"           ; 普通 Windows 路径
                "C:\\Program Files\\x"           ; 含空格
                "ends\\with\\backslash\\"      ; 结尾反斜杠(要加倍,否则吃掉收尾引号)
                "amp&ersand"                         ; cmd 元字符
                "pipe|and>redirect<"
                "caret^and(paren)"
                "percent%20encoded"                  ; % 刻意放行,两侧都不拒
                ""))))

    ;; 两侧对**无法安全传递**的字符都硬错(一个 raise、一个 exit,故只比「拒不拒」)
    (bootstrap-cmd-quote-rejects-same-inputs
      (let ([env (bootstrap-env '(q q-sh q-cmd win? mt-string die))])
        (eval '(define (win?) #t) env)
        (eval '(define (die code fmt . args) (raise (cons (quote bootstrap-die) code))) env)
        (for-each
          (lambda (s)
            (assert-raises (lambda () (parameterize ([windows-shell? #t]) (shell-quote s))))
            (assert-raises (lambda () (eval `(q ,s) env))))
          (list "quo\"te" "line\nbreak" "cr\rhere"))))

    (bootstrap-shell-quote-survives-sh
      ;; 端到端:引用后的串交 /bin/sh 必须原样回来
      (let ([env (bootstrap-env '(q q-sh q-cmd win? mt-string die))]
            [nasty "a b $HOME `id` \"d\" 'e'"])
        (eval '(define (win?) #f) env)
        (let ([r (run-capture "sh" (list "-c" (string-append "printf %s "
                                                             (eval `(q ,nasty) env))))])
          (assert-equal 0 (proc-result-code r))
          (assert-string= nasty (proc-result-out r)))))

    ))
