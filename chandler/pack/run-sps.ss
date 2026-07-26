#!chezscheme
;;; chandler/pack/run-sps.ss --- pack 模式 run.sps 内联段 + 生成器(原 pack.ss §6)
;;;
;;; pack 模式的 run.sps 在 install 模式之上追加:
;;;   stderr-diag + runtime-detect + version-match + manifest-read
;;;   + verify-format + full-target-check + native-walk
;;; 都在 stock Chez 与 Skiff 上跑**同一份** —— 先读 pack.manifest,校验 (format N)
;;; 与 target 三元组(按当前 runtime 分派,矩阵见 designs/05 §verify-pack),
;;; 全部通过才碰 library-directories / native / import。校验失败一律显式
;;; (exit N)(sysexits:65/70/78)+ 单行 s-expr 诊断,不走 Chez error。
;;; 不再单独生成 bootstrap.ss —— verifier 直接内联进 run.sps。
;;;
;;; 包根推导:run.sps 恒在 <libdir>/<name>/<version>/.chandler/run.sps → 4× path-parent
;;; = %root(install 模式 = libdir;pack 模式 = share/chez)。pack.manifest 在包根,
;;; 即 %root 再上两层(见 manifest-read-src 的 %pack-root)。

(library (chandler pack run-sps)
  (export run-sps-content
          stderr-diag-src runtime-detect-src version-match-src
          manifest-read-src verify-format-src full-target-check-src
          native-walk-src)
  (import (chezscheme)
          (chandler util))

  ;; stderr 诊断:人类可读行 + 单行 s-expr(orchestrator 用 read 收,故 s-expr
  ;; 恒单行、无换行;designs/10 §5)。
  (define stderr-diag-src
    (string-append
      "(define (%err msg)\n"
      "  (fprintf (current-error-port) \"chandler-pack: ~a~n\" msg)\n"
      "  (flush-output-port (current-error-port)))\n"
      "(define (%err-sexp s)\n"
      "  (fprintf (current-error-port) \"~s~n\" s)\n"
      "  (flush-output-port (current-error-port)))\n"))

  ;; runtime 探测:一字不改照搬 (chandler runtime) skiff-version-string 的守卫
  ;; (designs/06 §4):skiff-version 可能绑字符串、也可能绑返回字符串的过程
  ;; (skiff 0.1.1 起为过程),两形都认;取不到即 stock Chez。
  (define runtime-detect-src
    (string-append
      "(define %rt\n"
      "  (if (and (top-level-bound? 'skiff-version)\n"
      "           (guard (e [#t #f])\n"
      "             (let ([v (top-level-value 'skiff-version)])\n"
      "               (or (string? v) (procedure? v)))))\n"
      "      'skiff 'chez))\n"
      "(define (%skiff-ver)\n"
      "  (guard (e [#t #f])\n"
      "    (let ([v (top-level-value 'skiff-version)])\n"
      "      (cond\n"
      "        [(string? v) v]\n"
      "        [(procedure? v) (let ([r (v)]) (and (string? r) r))]\n"
      "        [else #f]))))\n"))

  ;; 内联 (chandler version) 的区间匹配:部署态没有 chandler 可 import,bootstrap
  ;; 必须自含。支持精确 / "*" / >= <= > < = 操作符与空格合取,与 skiff/app.ss 的
  ;; version-in-range? 同语义。解析容错(非法分量当 0)+ 整体 guard 兜成 #f:
  ;; 部署侧宁可按「不匹配」走 78,也不能让畸形版本串把进程抛进 debugger。
  (define version-match-src
    (string-append
      "(define (%ssplit s delims)\n"
      "  (let loop ([i 0] [start 0] [acc '()])\n"
      "    (cond\n"
      "      [(= i (string-length s))\n"
      "       (reverse (if (> i start) (cons (substring s start i) acc) acc))]\n"
      "      [(memv (string-ref s i) delims)\n"
      "       (loop (+ i 1) (+ i 1) (if (> i start) (cons (substring s start i) acc) acc))]\n"
      "      [else (loop (+ i 1) start acc)])))\n"
      "(define (%sprefix? p s)\n"
      "  (let ([n (string-length p)])\n"
      "    (and (>= (string-length s) n) (string=? p (substring s 0 n)))))\n"
      "(define (%sdrop s n) (substring s n (string-length s)))\n"
      "(define (%parse-version s0)\n"
      "  (let* ([s (if (and (> (string-length s0) 0)\n"
      "                     (memv (string-ref s0 0) '(#\\v #\\V)))\n"
      "                (substring s0 1 (string-length s0))\n"
      "                s0)]\n"
      "         [core (car (%ssplit s '(#\\- #\\+)))])\n"
      "    (map (lambda (p)\n"
      "           (let ([n (string->number p)])\n"
      "             (if (and n (integer? n) (exact? n) (>= n 0)) n 0)))\n"
      "         (%ssplit core '(#\\.)))))\n"
      "(define (%pad-to a b)\n"
      "  (let ([la (length a)] [lb (length b)])\n"
      "    (if (>= la lb) a (append a (make-list (- lb la) 0)))))\n"
      "(define (%version-compare a b)\n"
      "  (let loop ([a (%pad-to a b)] [b (%pad-to b a)])\n"
      "    (cond\n"
      "      [(and (null? a) (null? b)) 0]\n"
      "      [(< (car a) (car b)) -1]\n"
      "      [(> (car a) (car b)) 1]\n"
      "      [else (loop (cdr a) (cdr b))])))\n"
      "(define (%match-one tok v)\n"
      "  (cond\n"
      "    [(string=? tok \"*\") #t]\n"
      "    [(%sprefix? \">=\" tok) (>= (%version-compare v (%parse-version (%sdrop tok 2))) 0)]\n"
      "    [(%sprefix? \"<=\" tok) (<= (%version-compare v (%parse-version (%sdrop tok 2))) 0)]\n"
      "    [(%sprefix? \">\" tok)  (>  (%version-compare v (%parse-version (%sdrop tok 1))) 0)]\n"
      "    [(%sprefix? \"<\" tok)  (<  (%version-compare v (%parse-version (%sdrop tok 1))) 0)]\n"
      "    [(%sprefix? \"=\" tok)  (=  (%version-compare v (%parse-version (%sdrop tok 1))) 0)]\n"
      "    [else (= (%version-compare v (%parse-version tok)) 0)]))\n"
      "(define (%version-match? constraint ver)\n"
      "  (guard (e [#t #f])\n"
      "    (let ([v (%parse-version ver)])\n"
      "      (for-all (lambda (tok) (%match-one tok v))\n"
      "               (%ssplit constraint '(#\\space #\\tab))))))\n"))

  ;; 读 pack.manifest:不可读 / 不是 (pack ...) → 65 EX_DATAERR(对齐
  ;; skiff/app.ss read-manifest)。只定义 %fields / %field1;(target …) 的缺失
  ;; 由 full-target-check-src 判(先让 (format N) 检查跑,顺序与 skiff --app 一致)。
  (define manifest-read-src
    (string-append
      ;; %root = share/chez(库前缀);pack.manifest 在包根 = 再上两层。
      "(define %pack-root (path-parent (path-parent %root)))\n"
      "(define %manifest-path (string-append %pack-root \"/pack.manifest\"))\n"
      "(define %manifest\n"
      "  (guard (e [#t #f])\n"
      "    (call-with-input-file %manifest-path read)))\n"
      "(unless (and %manifest (pair? %manifest) (eq? (car %manifest) 'pack))\n"
      "  (%err (string-append \"manifest missing or invalid: \" %manifest-path))\n"
      "  (%err-sexp '(chandler-pack-error (manifest-invalid)))\n"
      "  (exit 65))\n"
      "(define %fields (cdr %manifest))\n"
      "(define (%field1 key)\n"
      "  (let ([c (assq key %fields)])\n"
      "    (and c (pair? (cdr c)) (cadr c))))\n"))

  ;; (format N) 前向兼容:N > pack-format-supported(=1)→ 70 EX_SOFTWARE;
  ;; 字段缺省视为 0(对齐 skiff/app.ss verify-format! 的 (or (field1 m 'format) 0))。
  (define verify-format-src
    (string-append
      "(define pack-format-supported 1)\n"
      "(let ([fmt (or (%field1 'format) 0)])\n"
      "  (when (and (number? fmt) (> fmt pack-format-supported))\n"
      "    (%err (format \"pack format ~a is newer than supported (~a)\"\n"
      "                  fmt pack-format-supported))\n"
      "    (%err-sexp (list 'chandler-pack-error\n"
      "                     (list 'format-too-new\n"
      "                           (list 'pack fmt)\n"
      "                           (list 'supported pack-format-supported))))\n"
      "    (exit 70)))\n"))

  ;; runtime-aware verify-target!(designs/10 §4 矩阵全 13 行):
  ;;   - machine-type / chez-version 永不放宽,不符即 78 EX_CONFIG;
  ;;   - (skiff-version "X") 精确:runtime 是 skiff 则值比对;是 stock 则必 78
  ;;     (pack requires skiff, current runtime is stock Chez);
  ;;   - (skiff-compat "<range>"):runtime 是 skiff 则 %version-match?;是 stock
  ;;     则必 78;唯独全开 \">=0.0.0\"(stock 包默认)在两种 runtime 上都通过;
  ;;   - 两者都不声明:不查 skiff;
  ;;   - SKIFF_ALLOW_VERSION_SKEW=1 只放宽 skiff 维(WARNING + 通过),
  ;;     machine-type / chez-version 不动;
  ;;   - 缺 (target …) → 65 EX_DATAERR。
  ;; 失败先出人读诊断、再出单行 s-expr,显式 (exit N),绝不走 Chez error。
  (define full-target-check-src
    (string-append
      "(define %target\n"
      "  (or (assq 'target %fields)\n"
      "      (begin\n"
      "        (%err \"manifest missing (target ...)\")\n"
      "        (%err-sexp '(chandler-pack-error (manifest-invalid (target-missing))))\n"
      "        (exit 65))))\n"
      "(define (%tfield1 key)\n"
      "  (let ([c (assq key (cdr %target))])\n"
      "    (and c (pair? (cdr c)) (cadr c))))\n"
      "(define %want-mt (%tfield1 'machine-type))\n"
      "(define %want-chez (%tfield1 'chez-version))\n"
      "(define %want-skiff (%tfield1 'skiff-version))\n"
      "(define %want-compat (%tfield1 'skiff-compat))\n"
      "(define %actual-mt (machine-type))\n"
      "(define %actual-chez\n"
      "  (let* ([s (scheme-version)] [n (string-length s)])\n"
      "    (let loop ([i (- n 1)])\n"
      "      (cond\n"
      "        [(< i 0) s]\n"
      "        [(char-whitespace? (string-ref s i)) (substring s (+ i 1) n)]\n"
      "        [else (loop (- i 1))]))))\n"
      "(define %skew-ok? (equal? (getenv \"SKIFF_ALLOW_VERSION_SKEW\") \"1\"))\n"
      "(define %bad '())\n"
      "(define (%mismatch! what expected actual advice)\n"
      "  (set! %bad (cons (list what expected actual advice) %bad)))\n"
      "(unless (eq? %want-mt %actual-mt)\n"
      "  (%mismatch! 'machine-type %want-mt %actual-mt\n"
      "              \"wrong platform pack; fetch the build for this machine-type\"))\n"
      "(unless (equal? %want-chez %actual-chez)\n"
      "  (%mismatch! 'chez-version %want-chez %actual-chez\n"
      "              \"install the matching runtime or re-pack the app\"))\n"
      "(cond\n"
      "  [(and %want-skiff (string? %want-skiff))\n"
      "   (if (eq? %rt 'skiff)\n"
      "       (let ([actual (%skiff-ver)])\n"
      "         (unless (equal? actual %want-skiff)\n"
      "           (if %skew-ok?\n"
      "               (%err (format \"WARNING: skiff-version skew allowed by SKIFF_ALLOW_VERSION_SKEW=1 (pack ~a, runtime ~a)\" %want-skiff actual))\n"
      "               (%mismatch! 'skiff-version %want-skiff actual\n"
      "                           \"install the matching skiff runtime or re-pack the app\"))))\n"
      "       (%mismatch! 'skiff-version %want-skiff 'stock-chez\n"
      "                   \"pack requires skiff, current runtime is stock Chez\"))]\n"
      "  [(and %want-compat (string? %want-compat)\n"
      "        (not (string=? %want-compat \">=0.0.0\")))\n"
      "   (if (eq? %rt 'skiff)\n"
      "       (let ([actual (%skiff-ver)])\n"
      "         (unless (and actual (%version-match? %want-compat actual))\n"
      "           (if %skew-ok?\n"
      "               (%err (format \"WARNING: skiff-version skew allowed by SKIFF_ALLOW_VERSION_SKEW=1 (pack compat ~a, runtime ~a)\" %want-compat actual))\n"
      "               (%mismatch! 'skiff-version (string-append \"compat \" %want-compat) actual\n"
      "                           \"install the matching skiff runtime or re-pack the app\"))))\n"
      "       (%mismatch! 'skiff-version (string-append \"compat \" %want-compat) 'stock-chez\n"
      "                   \"pack requires skiff, current runtime is stock Chez\"))]\n"
      "  [else #t])\n"
      "(unless (null? %bad)\n"
      "  (%err \"pack target mismatch; refusing to load\")\n"
      "  (for-each\n"
      "    (lambda (b)\n"
      "      (%err (format \"  ~a: expected ~s, actual ~s~n    -> ~a\"\n"
      "                    (car b) (cadr b) (caddr b) (cadddr b))))\n"
      "    (reverse %bad))\n"
      "  (%err-sexp (cons 'chandler-pack-error\n"
      "                   (list (cons 'target-mismatch\n"
      "                               (map (lambda (b)\n"
      "                                      (list (car b)\n"
      "                                            (list 'expected (cadr b))\n"
      "                                            (list 'actual (caddr b))))\n"
      "                                    (reverse %bad))))))\n"
      "  (exit 78))\n"))

  ;; 统一加载 native:**递归**走整棵对象树。这是兜底 —— 生成的 loader 正常先到 ——
  ;; 但一个会静默漏掉一半库的兜底不算兜底(一层扫描找不到 (chez async) 那类)。
  (define native-walk-src
    (string-append
      "(define (%load-natives dir)\n"
      "  (when (file-exists? dir)\n"
      "    (for-each\n"
      "      (lambda (e)\n"
      "        (let ((p (string-append dir \"/\" e)))\n"
      "          (when (file-directory? p)\n"
      "            (if (string=? e \"native\")\n"
      "                (for-each (lambda (f)\n"
      "                            (let ((q (string-append p \"/\" f)))\n"
      "                              (unless (file-directory? q) (load-shared-object q))))\n"
      "                          (directory-list p))\n"
      "                (%load-natives p)))))\n"
      "      (directory-list dir))))\n"))

  ;; run-sps-content:生成统一 run.sps,install/pack 模式共用。
  ;;
  ;; v3(D18):lock 驱动 —— 不再 scan-libdirs 全扫,而是读 chandler-manifest.lock
  ;; 拿精确 deps,只挂 lock 声明的版本。这样多版本 lib 共存时,app A 用 1.0.0、
  ;; app B 用 2.0.0,互不干扰(Chez 不会看到不相关的版本)。
  ;;
  ;; 根推导:run.sps 恒在 <root>/<name>/<version>/.chandler/run.sps → 4× path-parent → <root>
  ;;   install 模式:<root> = libdir
  ;;   pack 模式:<root> = pack-root
  ;;
  ;; pack 模式追加:pack.manifest 校验 + native 加载。
  (define (run-sps-content entry main . mode)
    (let ([entry-str (string-join (map symbol->string entry) " ")]
          [main-str (symbol->string main)]
          [pack? (and (pair? mode) (eq? (car mode) 'pack))])
      (string-append
        "(import (chezscheme))\n"
        ";; runner generated by chandler v3 (lock-driven) -- do not edit\n"
        ;; ── 根推导 ──
        "(define %runner (car (command-line)))\n"
        "(define %dot-chandler (path-parent %runner))\n"
        "(define %version-dir (path-parent %dot-chandler))\n"
        "(define %name-dir (path-parent %version-dir))\n"
        "(define %root (path-parent %name-dir))\n"
        "(define %mt (symbol->string (machine-type)))\n"
        ;; ── lock 驱动:读 chandler-manifest.lock,挂精确 dep 版本 ──
        ;; 零依赖项目没有 lock 文件(deps 从未需要写)→ 视为空闭包,不算错误。
        "(define %lock-path (string-append %dot-chandler \"/chandler-manifest.lock\"))\n"
        "(define %lock-datum (and (file-exists? %lock-path)\n"
        "                         (call-with-input-file %lock-path read)))\n"
        ;; lock datum = (lock (format 1) (manifest-sha256 ...) (chandler ...)
        ;;               (resolved (dep1 ...) (dep2 ...) ...) [(files ...)])
        ;; 我们要 (resolved ...) 各项的 (name (pin (kind "val")) ...)
        "(define (lock-resolved body)\n"
        "  (let loop ([xs body])\n"
        "    (cond\n"
        "      [(null? xs) '()]\n"
        "      [(and (pair? (car xs)) (eq? 'resolved (caar xs))) (cdr (car xs))]\n"
        "      [else (loop (cdr xs))])))\n"
        "(define (dep-name+version entry)\n"
        "  ;; entry: (name (source ...) (pin (kind \"val\")) (rev ...) ...)\n"
        "  ;; 版本目录名 = pin 的 val(与 locked-dep-pin-val / install 布局一致),\n"
        "  ;; 不是顶层的 (rev \"hash\") —— 那是内容寻址,不是目录名。\n"
        "  (let* ([name (car entry)]\n"
        "         [pin-field (let loop ([xs (cdr entry)])\n"
        "                      (cond\n"
        "                        [(null? xs) #f]\n"
        "                        [(and (pair? (car xs)) (eq? (caar xs) 'pin))\n"
        "                         (car xs)]\n"
        "                        [else (loop (cdr xs))]))]\n"
        "         [inner (and pin-field (pair? (cdr pin-field)) (cadr pin-field))]\n"
        "         [pin-val (and inner (pair? inner) (pair? (cdr inner)) (cadr inner))])\n"
        "    (cons name pin-val)))\n"
        "(define %lock-body (if %lock-datum (cdr %lock-datum) '()))\n"
        "(define %resolved (lock-resolved %lock-body))\n"
        "(define %dep-pairs\n"
        "  (map (lambda (e)\n"
        "         (let* ([nv (dep-name+version e)]\n"
        "                [n (symbol->string (car nv))]\n"
        "                [v (cdr nv)])\n"
        "           (and v\n"
        "                (let* ([vroot (string-append %root \"/\" n \"/\" v)]\n"
        "                       [src (string-append vroot \"/src\")]\n"
        "                       [obj (string-append vroot \"/\" %mt)])\n"
        "                  (if (file-directory? src) (cons src obj) #f)))))\n"
        "       %resolved))\n"
        ;; 自己的 vroot 对(src . obj)
        "(define %self-pair\n"
        "  (cons (string-append %version-dir \"/src\")\n"
        "        (string-append %version-dir \"/\" %mt)))\n"
        "(library-directories\n"
        "  (cons %self-pair\n"
        "        (filter (lambda (x) x) %dep-pairs)))\n"
        ;; ── pack 额外段:校验 + native ──
        (if pack? stderr-diag-src "")
        (if pack? runtime-detect-src "")
        (if pack? version-match-src "")
        (if pack? manifest-read-src "")
        (if pack? verify-format-src "")
        (if pack? full-target-check-src "")
        (if pack? "(compile-imported-libraries #f)\n" "")
        (if pack? native-walk-src "")
        (if pack? "(%load-natives %root)\n" "")
        ;; ── 入口(共享) ──
        ;; args 必须 quote:(list 'main args) 会把实参表当 form 求值
        ;; (变成把 "--version" 当过程 apply)。契约:main 接收整个 argv 表。
        ;; 传退出码:main 契约是 argv → exit-code;不 exit 则启动器包住的 app
        ;; 恒退 0,失败无法被调用方(如 bootstrap 编排)检测。
        ;; env 必须含 (chezscheme):否则 quote/let 等核心语法在 eval 环境里未绑定。
        "(let ([args (cdr (command-line))]\n"
        "      [env (environment '(chezscheme) '(" entry-str "))])\n"
        "  (let ([rc (eval (list '" main-str " (list 'quote args)) env)])\n"
        "    (exit (if (fixnum? rc) rc 0))))\n")))
  )
