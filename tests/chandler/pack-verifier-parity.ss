#!chezscheme
;;; tests/chandler/pack-verifier-parity.ss --- 部署侧校验器与进程内校验器的 parity
;;;
;;; chandler 里有两处「同一份决策表、两份实现」,而且**无法合并**:
;;;
;;;   ① 版本区间匹配   (chandler version) 的 version-match?
;;;                  ↔ (chandler pack run-sps) 的 version-match-src(生成的源码串)
;;;   ② target 三元组  (chandler pack verify) 的 verify-pack-target!
;;;                  ↔ (chandler pack run-sps) 的 full-target-check-src
;;;
;;; 不能合并的理由是硬的:部署态的包里没有 chandler 可以 import,run.sps 必须自含
;;; (designs/10 §5)。于是两份实现只能靠人去同步 —— 改一处漏一处的后果是
;;; 「打包期校验通过、启动期拒绝」(或反过来),而且只在真机部署时才现形。
;;;
;;; 本 suite 就是那道防线:把生成的源码串 eval 进一个干净的 (chezscheme) 环境,
;;; 拿到部署侧的实现,再对同一批输入逐条比对两者的判定。
;;;
;;; 部署侧的 (exit N) 由环境里替换掉的 `exit` 抛出来接住 —— 生成的代码在校验失败时
;;; 是**真的**要终止进程的(`(define %target (or … (begin … (exit 65))))`),
;;; 让它返回值继续往下跑会得到无意义的状态。

(library (tests chandler pack-verifier-parity)
  (export suite)
  (import (chezscheme)
          (tests chandler harness)
          (chandler util)
          (chandler layout)
          (chandler version)
          (chandler runtime-detector)
          (chandler pack verify)
          (chandler pack run-sps))

  ;; ── 把一段生成的源码串 eval 进环境 ──
  (define (eval-src! src env)
    (let ([p (open-input-string src)])
      (let loop ()
        (let ([form (read p)])
          (unless (eof-object? form)
            (eval form env)
            (loop))))))

  (define (fresh-env)
    (copy-environment (environment '(chezscheme))))

  ;; ── ① 版本区间:部署侧的 %version-match? ──
  (define deployed-version-match?
    (let ([env (fresh-env)])
      (eval-src! version-match-src env)
      (eval '%version-match? env)))

  ;; ── ② target 决策:跑部署侧的检查,返回 'ok 或退出码 ──
  ;; fields 形如 ((target (machine-type ta6le) (chez-version "10.4.1") …) …)
  (define (deployed-target-verdict fields rt skiff-ver)
    (let ([env (fresh-env)])
      (eval-src! version-match-src env)
      (eval `(define %fields ',fields) env)
      (eval `(define %rt ',rt) env)
      (eval `(define (%skiff-ver) ',skiff-ver) env)
      (eval '(define (%err msg) (void)) env)
      (eval '(define (%err-sexp s) (void)) env)
      (eval '(define (exit n) (raise (cons 'deployed-exit n))) env)
      (guard (e [(and (pair? e) (eq? (car e) 'deployed-exit)) (cdr e)])
        (eval-src! full-target-check-src env)
        'ok)))

  ;; 进程内那份的 runtime 不是参数,是**探测**出来的:(chandler runtime-detector) 的
  ;; 契约就是「顶层绑没绑 skiff-version(字符串或返回字符串的过程)」。所以要驱动它的
  ;; skiff 分支,就照那个契约装一个 —— 这不是绕过实现,正是它对外声明的探测面。
  ;; 装完必须还原:留成 #f 与「未绑定」对探测器等价(两者都得到「非 skiff」)。
  (define (with-runtime rt skiff-ver thunk)
    (let ([had? (top-level-bound? 'skiff-version)]
          [old  (and (top-level-bound? 'skiff-version) (top-level-value 'skiff-version))])
      (dynamic-wind
        (lambda ()
          (define-top-level-value 'skiff-version
            (if (eq? rt 'skiff) skiff-ver #f)))
        thunk
        (lambda ()
          (define-top-level-value 'skiff-version (if had? old #f))))))

  ;; 进程内那份:#f = 通过 → 归一成 'ok,好和上面比。stderr 收进字符串端口,
  ;; 免得失败用例的诊断刷屏(诊断文本本身不在 parity 契约里,退出码才是)。
  (define (inprocess-target-verdict fields rt skiff-ver)
    (with-runtime rt skiff-ver
      (lambda ()
        (parameterize ([current-error-port (open-output-string)])
          (let ([r (verify-pack-target! fields)])
            (if r r 'ok))))))

  ;; 用当前进程的真实 mt / chez 版本造 target 字段 —— 两份实现都从运行进程取
  ;; 「实际值」,故只有「期望值」这一侧需要在用例里变化。
  (define this-mt (machine-type))
  (define this-chez (chez-version-string))

  (define (target-fields . kvs)
    (list (cons 'target kvs)))

  (define (matching-target . extra)
    (apply target-fields
           `((machine-type ,this-mt) (chez-version ,this-chez) ,@extra)))

  ;; 两份实现对同一输入必须给出同一判定
  (define (assert-parity fields rt skiff-ver)
    (let ([deployed (deployed-target-verdict fields rt skiff-ver)]
          [inproc   (inprocess-target-verdict fields rt skiff-ver)])
      (unless (equal? deployed inproc)
        (assert-equal (list 'deployed deployed) (list 'deployed inproc)))
      deployed))

  (define-suite suite

    ;; ══ ① 版本区间匹配 parity ══
    ;; 语料刻意覆盖 designs/10 里实际会出现的形状:>= 区间(stock 包的
    ;; skiff-compat 全开值)、精确串、空格合取、"*"。
    (version-match-parity-over-corpus
      (let ([constraints '(">=0.0.0" ">=1.0" ">=0.4 <0.5" "<2.0.0" "<=1.2.3"
                           ">1.0.0" "=1.2.3" "1.2.3" "*" "0.1" ">=10.0")]
            [versions '("0.0.0" "0.1.0" "0.4.9" "0.5.0" "1.0.0" "1.2.3" "1.2.4"
                        "2.0.0" "9.9.0" "10.0.0" "10.4.1" "v1.2.3" "1.2.3-alpha")])
        (for-each
          (lambda (c)
            (for-each
              (lambda (v)
                (let ([mine (version-match? c v)]
                      [theirs (deployed-version-match? c v)])
                  (unless (eq? (and mine #t) (and theirs #t))
                    (assert-equal (list c v 'chandler mine)
                                  (list c v 'chandler theirs)))))
              versions))
          constraints)))

    ;; **已知且刻意的差异**,钉住以免有人「顺手补上」时忘了另一边:
    ;; 部署侧不支持 caret/tilde(designs/10 §5 只要求操作符 + 合取),而
    ;; (chandler version) 支持。目前无害 —— manifest-writer 只会写 ">=0.0.0"
    ;; 或精确 skiff-version。若哪天 pack.manifest 里真出现 "^1.2",部署侧会把它
    ;; 解析成 (0 2) 做等值比较,静默判错;那时必须同时改两边。
    (version-match-caret-is-a-known-gap
      (assert-true (version-match? "^1.2.0" "1.5.0"))
      (assert-false (deployed-version-match? "^1.2.0" "1.5.0")))

    ;; ══ ② target 三元组决策表 parity(designs/10 §4 矩阵)══

    ;; 全对上 + 无 skiff 声明 → 通过
    (target-parity-plain-match
      (assert-equal 'ok (assert-parity (matching-target) 'chez #f)))

    ;; machine-type 不符 → 78,两边一致
    (target-parity-machine-type-mismatch
      (assert-equal 78 (assert-parity
                         (target-fields `(machine-type i3nt)
                                        `(chez-version ,this-chez))
                         'chez #f)))

    ;; chez-version 不符 → 78
    (target-parity-chez-version-mismatch
      (assert-equal 78 (assert-parity
                         (target-fields `(machine-type ,this-mt)
                                        '(chez-version "9.5.0"))
                         'chez #f)))

    ;; stock 包的全开 skiff-compat:stock Chez 与 skiff 上都必须通过
    (target-parity-open-compat-on-chez
      (assert-equal 'ok (assert-parity (matching-target '(skiff-compat ">=0.0.0"))
                                       'chez #f)))
    (target-parity-open-compat-on-skiff
      (assert-equal 'ok (assert-parity (matching-target '(skiff-compat ">=0.0.0"))
                                       'skiff "0.1.1")))

    ;; 非全开 compat + stock Chez → 78(包要 skiff,当前不是)
    (target-parity-compat-on-stock-chez
      (assert-equal 78 (assert-parity (matching-target '(skiff-compat ">=0.1.0"))
                                      'chez #f)))

    ;; 非全开 compat + skiff,区间满足 / 不满足
    (target-parity-compat-satisfied
      (assert-equal 'ok (assert-parity (matching-target '(skiff-compat ">=0.1.0"))
                                       'skiff "0.1.1")))
    (target-parity-compat-unsatisfied
      (assert-equal 78 (assert-parity (matching-target '(skiff-compat ">=0.2.0"))
                                      'skiff "0.1.1")))

    ;; 精确 skiff-version:相符 / 不符 / 当前是 stock
    (target-parity-exact-skiff-match
      (assert-equal 'ok (assert-parity (matching-target '(skiff-version "0.1.1"))
                                       'skiff "0.1.1")))
    (target-parity-exact-skiff-mismatch
      (assert-equal 78 (assert-parity (matching-target '(skiff-version "0.1.1"))
                                      'skiff "0.2.0")))
    (target-parity-exact-skiff-on-stock
      (assert-equal 78 (assert-parity (matching-target '(skiff-version "0.1.1"))
                                      'chez #f)))

    ;; skiff-version 优先于 skiff-compat(cond 的分支序;两边必须同序)
    (target-parity-exact-wins-over-compat
      (assert-equal 'ok (assert-parity
                          (matching-target '(skiff-version "0.1.1")
                                           '(skiff-compat ">=9.9.9"))
                          'skiff "0.1.1")))

    ;; 缺 (target …) → 65 EX_DATAERR
    (target-parity-missing-target-field
      (assert-equal 65 (assert-parity '((app "x")) 'chez #f)))

    ;; machine-type 与 skiff 同时不符 → 仍是 78(收集全部不符项后一次性判)
    (target-parity-multiple-mismatches
      (assert-equal 78 (assert-parity
                         (target-fields '(machine-type i3nt)
                                        '(chez-version "9.5.0")
                                        '(skiff-version "0.1.1"))
                         'chez #f)))

    ))
