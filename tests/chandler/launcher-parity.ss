#!chezscheme
;;; tests/chandler/launcher-parity.ss --- sh 与 cmd 启动器的 parity(D34)
;;;
;;; 两族启动器(install 模式 / pack 模式)各有 POSIX 与 Windows 两份模板。
;;; 它们不是同一段代码 —— 一份是 sh、一份是批处理,语法上毫无共同点 ——
;;; 但编码的是**同一套决策**:去哪找 active version、runner 路径怎么拼、
;;; 运行时按什么顺序发现、失败退什么码。
;;;
;;; 分叉的后果是「一个平台好用、另一个平台行为不同」,而 CI 只在一个平台上跑,
;;; 于是没人会发现。本 suite 把两份模板都渲染出来,抽出这几项决策再对拍。
;;;
;;; 做法与 bootstrap-parity / pack-verifier-parity 同构:**不重新实现**模板逻辑
;;; (那只会变成第三份副本),而是把渲染结果当**文本数据**解析。
;;;
;;; **刻意保留的差异**在下方 known-divergences 里逐条钉住 —— 有意的差异必须
;;; 写下来,否则下一个人会把它「修」成 bug,或者反过来把 bug 当成有意的。

(library (tests chandler launcher-parity)
  (export suite)
  (import (chezscheme)
          (tests chandler harness)
          (tests chandler fixtures)
          (chandler util)
          (chandler fs)
          (chandler layout)
          (chandler pack launchers)
          (chandler cli commands))

  (define name "myapp")
  (define libdir "/opt/chez")
  (define version "1.2.3")

  ;; ── 文本探针 ──
  ;; 只问「这段文本里有没有出现 X」。比正则解析健壮:模板改了排版不会假红,
  ;; 但改了**决策**(路径段、退出码、发现顺序)一定红。
  (define (has? text sub) (string-contains? text sub))

  ;; 退出码集合:从两侧各自的写法里抽。sh 用 `exit 70`,cmd 用 `exit /b 70`。
  (define (sh-exit-codes text)
    (collect-numbers-after text "exit "))
  (define (cmd-exit-codes text)
    (collect-numbers-after text "exit /b "))

  ;; 找出 text 中每个 marker 后紧跟的十进制数,去重后升序
  (define (collect-numbers-after text marker)
    (let ([mlen (string-length marker)] [n (string-length text)])
      (let loop ([i 0] [acc '()])
        (if (>= i n)
            (list-sort < (dedupe acc))
            (if (and (<= (+ i mlen) n)
                     (string=? marker (substring text i (+ i mlen))))
                (let digits ([j (+ i mlen)] [ds '()])
                  (if (and (< j n) (char-numeric? (string-ref text j)))
                      (digits (+ j 1) (cons (string-ref text j) ds))
                      (loop j (if (null? ds)
                                  acc
                                  (cons (string->number
                                          (list->string (reverse ds)))
                                        acc)))))
                (loop (+ i 1) acc))))))

  (define (dedupe xs)
    (fold-left (lambda (acc x) (if (memv x acc) acc (cons x acc))) '() xs))

  ;; ── 运行时发现顺序 ──
  ;;「skiff 优先」是策略,两侧必须一致。**不能**拿「候选名在全文首次出现的位置」
  ;; 来排 —— sh 侧的 `case` 分支里 `chez)` 出现在发现循环之前,那样排出来是
  ;; (chez skiff scheme),测不出策略、只测出排版。(这一版是被本测试自己抓出来的。)
  ;;
  ;; 改为各自认准**发现构造**本身:
  ;;   sh  → `for _c in skiff scheme chez; do`
  ;;   cmd → 依次出现的 `where <cand>` 行
  (define (sh-discovery-order text)
    (let ([i (index-of text "for _c in ")])
      (and i
           (let* ([start (+ i (string-length "for _c in "))]
                  [end (or (index-of-from text ";" start) (string-length text))])
             (filter (lambda (s) (> (string-length s) 0))
                     (string-split (substring text start end) #\space))))))

  (define (cmd-discovery-order text)
    (let loop ([from 0] [acc '()])
      (let ([i (index-of-from text "where " from)])
        (if (not i)
            (reverse acc)
            (let* ([start (+ i (string-length "where "))]
                   [tok (token-at text start)])
              (loop (+ start (max 1 (string-length tok))) (cons tok acc)))))))

  ;; 从 i 起取到第一个空白为止
  (define (token-at text i)
    (let ([n (string-length text)])
      (let loop ([j i])
        (if (or (>= j n) (char-whitespace? (string-ref text j)))
            (substring text i j)
            (loop (+ j 1))))))

  (define (index-of text sub) (index-of-from text sub 0))

  (define (index-of-from text sub from)
    (let ([n (string-length text)] [m (string-length sub)])
      (let loop ([i from])
        (cond [(> (+ i m) n) #f]
              [(string=? sub (substring text i (+ i m))) i]
              [else (loop (+ i 1))]))))

  (define-suite suite

    ;; ══════════════════════════════════════════════════════════════
    ;; install 模式 shim
    ;; ══════════════════════════════════════════════════════════════

    ;; 两侧读的必须是同一个文件:.registry/<name>.active(D35 sidecar)。
    ;; 一侧读 .active、另一侧还在解析 .ss,是 C1 期间真实存在过的分叉。
    (install-both-read-active-sidecar
      (let ([sh (app-launcher-sh name libdir)]
            [cmd (app-launcher-cmd name libdir)])
        (assert-true (has? sh ".registry/$NAME.active"))
        (assert-true (has? cmd ".registry\\%NAME%.active"))
        ;; 谁都不许再碰 .ss —— 那是权威文件,shim 不该理解它的格式
        (assert-false (has? sh ".registry/$NAME.ss"))
        (assert-false (has? cmd ".registry\\%NAME%.ss"))))

    ;; runner 路径的拼法:<libdir>/<name>/<active>/.chandler/run.sps
    (install-both-build-same-runner-path
      (let ([sh (app-launcher-sh name libdir)]
            [cmd (app-launcher-cmd name libdir)])
        (assert-true (has? sh "$LIBDIR/$NAME/$ACTIVE/.chandler/run.sps"))
        (assert-true (has? cmd "%LIBDIR%\\%NAME%\\%ACTIVE%\\.chandler\\run.sps"))))

    ;; 退出码集合必须逐条相同(70 缺件 / 64 参数错 / 127 找不到运行时)
    (install-exit-codes-match
      (let ([sh (sh-exit-codes (app-launcher-sh name libdir))]
            [cmd (cmd-exit-codes (app-launcher-cmd name libdir))])
        (assert-equal '(64 70 127) sh)
        (assert-equal '(64 70 127) cmd)))

    ;; 运行时发现顺序:skiff > scheme > chez,两侧一致
    (install-runtime-discovery-order-matches
      (let ([sh (sh-discovery-order (app-launcher-sh name libdir))]
            [cmd (cmd-discovery-order (app-launcher-cmd name libdir))])
        (assert-equal '("skiff" "scheme" "chez") sh)
        (assert-equal '("skiff" "scheme" "chez") cmd)
        (assert-equal sh cmd)))

    ;; 两侧都认 CHANDLER_RUNTIME / CHANDLER_SKIFF / CHANDLER_SCHEME 三个变量
    (install-both-honor-runtime-env-vars
      (let ([sh (app-launcher-sh name libdir)]
            [cmd (app-launcher-cmd name libdir)])
        (for-each
          (lambda (v)
            (assert-true (has? sh v))
            (assert-true (has? cmd v)))
          '("CHANDLER_RUNTIME" "CHANDLER_SKIFF" "CHANDLER_SCHEME"))))

    ;; 两侧都不嵌 version(D17 稳定 shim:switch 不重写 launcher)
    (install-neither-embeds-version
      (let ([sh (app-launcher-sh name libdir)]
            [cmd (app-launcher-cmd name libdir)])
        (assert-false (has? sh version))
        (assert-false (has? cmd version))))

    ;; ══════════════════════════════════════════════════════════════
    ;; pack 模式 launcher
    ;; ══════════════════════════════════════════════════════════════

    ;; pack 启动器**嵌** version(包里就一个版本,无 registry 可查)
    (pack-both-embed-runner-path
      (let ([sh (launcher-sh-skiff name version)]
            [cmd (launcher-cmd-skiff name version)])
        (assert-true (has? sh (string-append "share/chez/" name "/" version
                                             "/.chandler/run.sps")))
        (assert-true (has? cmd (string-append "share\\chez\\" name "\\" version
                                              "\\.chandler\\run.sps")))))

    ;; skiff 包两侧都要设 SKIFF_BOOT_DIR —— boot 必须在进程有堆之前注册,
    ;; env 是唯一的交接方式;漏一侧则那个平台的包一启动就找不到 boot
    (pack-skiff-both-set-boot-dir
      (let ([sh (launcher-sh-skiff name version)]
            [cmd (launcher-cmd-skiff name version)])
        (assert-true (has? sh "SKIFF_BOOT_DIR"))
        (assert-true (has? cmd "SKIFF_BOOT_DIR"))
        (assert-true (has? sh "$HERE/lib/chez"))
        (assert-true (has? cmd "%HERE%\\lib\\chez"))))

    ;; stock 包的 -b 链:petite 恒随;scheme.boot 只在 runtime=scheme 时随。
    ;; boots-flags 是**两侧共用**的同一个函数(Chez 在 Windows 上也吃 `/`),
    ;; 故这里同时钉住「共用」这件事本身。
    (pack-stock-boot-chain-matches
      (let ([sh-p (launcher-sh-stock 'petite name version)]
            [cmd-p (launcher-cmd-stock 'petite name version)]
            [sh-s (launcher-sh-stock 'scheme name version)]
            [cmd-s (launcher-cmd-stock 'scheme name version)])
        (assert-true (has? sh-p "petite.boot"))
        (assert-true (has? cmd-p "petite.boot"))
        (assert-false (has? sh-p "scheme.boot"))
        (assert-false (has? cmd-p "scheme.boot"))
        (assert-true (has? sh-s "scheme.boot"))
        (assert-true (has? cmd-s "scheme.boot"))))

    ;; Windows 侧调可执行文件必须带 .exe(.cmd 按全名调用,无扩展名跑不起来)
    (pack-cmd-uses-exe-suffix
      (assert-true (has? (launcher-cmd-skiff name version) "skiff.exe"))
      (assert-true (has? (launcher-cmd-stock 'petite name version) "scheme.exe")))

    ;; 包内路径**全部**从 `%HERE%` 起,且必须是反斜杠形。
    ;;
    ;; 不能笼统地禁掉 `/` —— cmd 的开关本来就带斜杠(`exit /b`、`if /i`)。
    ;; 要钉的是「`%HERE%` 之后接的是不是反斜杠」:`boots-flags` 与 sh 侧共用同一个
    ;; 函数,出口忘了归一就会漏出 `"%HERE%/lib/chez/petite.boot"`。
    ;; Chez 照样能跑,所以这种回归只会被人眼发现,不会被任何功能测试发现。
    (cmd-templates-use-backslash-paths
      (for-each
        (lambda (text)
          (assert-false (has? text "%HERE%/"))
          (assert-true (has? text "%HERE%\\")))
        (list (launcher-cmd-skiff name version)
              (launcher-cmd-stock 'scheme name version))))

    ;; 生成进用户机器的批处理保持 **ASCII-only**:cmd.exe 按 OEM 代码页读批处理,
    ;; 不是 UTF-8。注释里的非 ASCII 字符即便无害也会显示成乱码。
    (cmd-templates-are-ascii
      (for-each
        (lambda (text) (assert-true (all-ascii? text)))
        (list (app-launcher-cmd name libdir)
              (launcher-cmd-skiff name version)
              (launcher-cmd-stock 'scheme name version))))

    ;; ══════════════════════════════════════════════════════════════
    ;; `.cmd` 的硬性格式要求
    ;; ══════════════════════════════════════════════════════════════

    ;; CRLF:cmd.exe 对 LF-only 的标签与 goto 会出错,而两族 cmd 模板都用标签。
    ;; 模板里直接写 \r\n,这条测试防的是有人「顺手清理」成 \n。
    (cmd-templates-are-crlf
      (for-each
        (lambda (text)
          (assert-true (has? text "\r\n"))
          (assert-false (has-bare-lf? text)))
        (list (app-launcher-cmd name libdir)
              (launcher-cmd-skiff name version)
              (launcher-cmd-stock 'scheme name version))))

    ;; 退出码必须显式转发 —— cmd 没有 exec,不写就永远返回 0
    (cmd-templates-forward-exit-code
      (for-each
        (lambda (text) (assert-true (has? text "exit /b %errorlevel%")))
        (list (app-launcher-cmd name libdir)
              (launcher-cmd-skiff name version)
              (launcher-cmd-stock 'scheme name version))))

    ;; 不 `cd`:保持 UNC 路径可用,也不改子进程的工作目录。
    ;; (`cd /d` 也不行 —— UNC 下 cmd 根本 cd 不过去。)
    (cmd-templates-do-not-cd
      (for-each
        (lambda (text) (assert-false (has? text "cd ")))
        (list (app-launcher-cmd name libdir)
              (launcher-cmd-skiff name version)
              (launcher-cmd-stock 'scheme name version))))

    ;; ══════════════════════════════════════════════════════════════
    ;; 刻意保留的差异 —— 有意为之,写下来免得被当 bug「修」掉
    ;; ══════════════════════════════════════════════════════════════

    (known-divergences
      (let ([sh (app-launcher-sh name libdir)]
            [cmd (app-launcher-cmd name libdir)])
        ;; ① sh 用 exec 顶替自身(无残留 shell 进程);cmd 无 exec,
        ;;    故 cmd.exe 会作为父进程留着,Ctrl+C 还会弹 Terminate batch job。
        ;;    无干净解法,除非将来出真的 .exe shim(designs/14 §11)。
        (assert-true (has? sh "exec "))
        (assert-false (has? cmd "exec "))
        ;; ② 参数转发:sh 的 "$@" 保真;cmd 的 %* 传原始命令行尾部,
        ;;    含 `%` 的参数会被展开(designs/14 §8.5,cmd 固有限制)。
        (assert-true (has? sh "\"$@\""))
        (assert-true (has? cmd "%*"))))
    )

  (define (all-ascii? s)
    (let loop ([i (- (string-length s) 1)])
      (cond [(< i 0) #t]
            [(> (char->integer (string-ref s i)) 126) #f]
            [else (loop (- i 1))])))

  ;; 是否存在**不带** \r 的裸 \n
  (define (has-bare-lf? s)
    (let ([n (string-length s)])
      (let loop ([i 0])
        (cond [(>= i n) #f]
              [(and (char=? #\newline (string-ref s i))
                    (or (= i 0) (not (char=? #\return (string-ref s (- i 1))))))
               #t]
              [else (loop (+ i 1))]))))
  )
