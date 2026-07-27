#!chezscheme
;;; chandler/util.ss --- 横切工具:字符串处理 + alist 访问 + 错误处理宏
;;;
;;; 全仓公用,消除各模块各写一份 split/trim/prefix?/contains? 的冗余。纯函数,只 (chezscheme)。

(library (chandler util)
  (export string-split split-lines string-trim
          string-prefix? string-suffix? string-search string-contains?
          char-index strip-prefix strip-suffix string-join
          alist-ref getenv* ignore-errors plural
          chandler-version
          format-object eprintf datum->string name->string
          filter-map short-rev)
  (import (chezscheme))

  ;; chandler 自身版本 —— 单一出处:umbrella (chandler)、CLI --version、lock 的
  ;; (chandler …) 快照、以及 manifest 的 (chandler "<range>") 运行时门都读它。
  (define chandler-version "0.1.6")

  ;; 英文单复数选词(用户可见输出用;避免 "1 dependencies" 之类)
  (define (plural n one many) (if (= n 1) one many))

  ;; getenv 但空串视为未设(Chez putenv 无法删变量,还原为 "" 时需当作无)
  (define (getenv* name)
    (let ([v (getenv name)])
      (and v (> (string-length v) 0) v)))

  (define ws '(#\space #\tab #\return #\newline))

  ;; ── 分割:delim 为单字符或字符列表 ──
  ;; 按下标走 + substring 切段。先前是 string->list 后逐字符 cons,每个字符要三次
  ;; 表分配(chars/cur/acc);1.6 MB 输入实测 42 ms → 6 ms。split-lines 会喂到
  ;; `git tag` 列表、`git status --porcelain` 这类大输出上,值得。
  (define (string-split s delim)
    (let* ([n (string-length s)]
           [delim? (if (char? delim)
                       (lambda (c) (char=? c delim))
                       (lambda (c) (and (memv c delim) #t)))])
      (let loop ([i 0] [start 0] [acc '()])
        (cond
          [(= i n) (reverse (cons (substring s start n) acc))]
          [(delim? (string-ref s i))
           (loop (+ i 1) (+ i 1) (cons (substring s start i) acc))]
          [else (loop (+ i 1) start acc)]))))

  (define (split-lines s) (string-split s #\newline))

  ;; ── 去首尾空白 ──
  ;; 同样按下标走:原先 string->list + 两次 reverse + list->string,四趟外加整条
  ;; 字符表的分配。每个捕获到的子进程输出都要过一遍它。
  (define (string-trim s)
    (let ([n (string-length s)])
      (let ([b (let loop ([i 0]) (if (and (< i n) (memv (string-ref s i) ws))
                                     (loop (+ i 1)) i))])
        (let ([e (let loop ([i n]) (if (and (> i b) (memv (string-ref s (- i 1)) ws))
                                       (loop (- i 1)) i))])
          (if (and (= b 0) (= e n)) s (substring s b e))))))

  ;; ── 前缀/后缀 ──
  (define (string-prefix? p s)
    (let ([lp (string-length p)] [ls (string-length s)])
      (and (>= ls lp) (string=? p (substring s 0 lp)))))

  (define (string-suffix? suf s)
    (let ([lf (string-length suf)] [ls (string-length s)])
      (and (>= ls lf) (string=? suf (substring s (- ls lf) ls)))))

  (define (strip-prefix s pre)
    (if (string-prefix? pre s) (substring s (string-length pre) (string-length s)) s))

  (define (strip-suffix s suf)
    (if (string-suffix? suf s) (substring s 0 (- (string-length s) (string-length suf))) s))

  ;; ── 子串搜索 ──
  ;; string-search:sub 在 s 中的起始下标,或 #f
  ;; 逐位置比 string-ref,不再每个位置切一个 substring —— 原先是 O(n·m) 的**分配**,
  ;; 而不只是 O(n·m) 的比较。目前只喂短串(URL、path-sep),但指向文件内容就会炸。
  (define (string-search s sub)
    (let ([ls (string-length s)] [lsub (string-length sub)])
      (let loop ([i 0])
        (cond
          [(> (+ i lsub) ls) #f]
          [(let inner ([k 0])
             (or (= k lsub)
                 (and (char=? (string-ref s (+ i k)) (string-ref sub k))
                      (inner (+ k 1)))))
           i]
          [else (loop (+ i 1))]))))

  (define (string-contains? s sub) (and (string-search s sub) #t))

  ;; char-index:字符 c 在 s 中(从 start,默认 0)的下标,或 #f
  (define char-index
    (case-lambda
      [(s c) (char-index s c 0)]
      [(s c start)
       (let ([ls (string-length s)])
         (let loop ([i start])
           (cond [(>= i ls) #f]
                 [(char=? c (string-ref s i)) i]
                 [else (loop (+ i 1))])))]))

  ;; ── 连接:以 sep 连接字符串列表 ──
  ;; 走 string port 而非 fold-left + string-append:后者每接一段都重新分配并复制
  ;; 已有前缀,对总长度是平方级。本函数在指纹计算、库名→路径、libdirs 串拼接
  ;; 这些逐节点/逐边跑的地方都在用。
  (define (string-join lst sep)
    (if (null? lst)
        ""
        (let ([op (open-output-string)])
          (display (car lst) op)
          (for-each (lambda (s) (display sep op) (display s op)) (cdr lst))
          (get-output-string op))))

  ;; ── alist 访问:(alist-ref al key [default]) ──
  (define alist-ref
    (case-lambda
      [(al key) (alist-ref al key #f)]
      [(al key default) (let ([p (assq key al)]) (if p (cdr p) default))]))

  ;; ── 错误处理宏:求值 body,任何异常返回 #f(替 (guard (e [#t #f]) …))──
  (define-syntax ignore-errors
    (syntax-rules ()
      [(_ body ...) (guard (e [#t #f]) body ...)]))

  ;; ── 格式化与输出 ──
  (define (format-object v) (format "~a" v))

  (define (eprintf fmt . args)
    (apply fprintf (current-error-port) fmt args))

  ;; 包名/库名归一:symbol 与 string 两形都收(manifest/CLI 给字符串,lock 与
  ;; registry 记录给 symbol),要拼路径或做文件名时统一成字符串。
  (define (name->string n) (if (symbol? n) (symbol->string n) n))

  ;; s-expression → 其书面文本(用于生成代码/清单)
  (define (datum->string d)
    (let ([p (open-output-string)]) (write d p) (get-output-string p)))

  ;; ── filter-map:map 并跳过 #f 结果(各模块自写一份的统一出处)──
  (define (filter-map f lst)
    (fold-right (lambda (x acc) (let ([r (f x)]) (if r (cons r acc) acc))) '() lst))

  ;; ── short-rev:截 git rev/sha 到 10 字符(展示用;install/commands 各写一份)──
  (define (short-rev rev)
    (if (and (string? rev) (>= (string-length rev) 10))
        (substring rev 0 10)
        rev)))
