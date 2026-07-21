#!chezscheme
;;; chandler/util.ss --- 横切工具:字符串处理 + alist 访问 + 错误处理宏
;;;
;;; 全仓公用,消除各模块各写一份 split/trim/prefix?/contains? 的冗余。纯函数,只 (chezscheme)。

(library (chandler util)
  (export string-split split-lines string-trim
          string-prefix? string-suffix? string-search string-contains?
          char-index strip-prefix strip-suffix string-join
          alist-ref getenv* ignore-errors)
  (import (chezscheme))

  ;; getenv 但空串视为未设(Chez putenv 无法删变量,还原为 "" 时需当作无)
  (define (getenv* name)
    (let ([v (getenv name)])
      (and v (> (string-length v) 0) v)))

  (define ws '(#\space #\tab #\return #\newline))

  ;; ── 分割:delim 为单字符或字符列表 ──
  (define (string-split s delim)
    (let ([delim? (if (char? delim)
                      (lambda (c) (char=? c delim))
                      (lambda (c) (and (memv c delim) #t)))])
      (let loop ([chars (string->list s)] [cur '()] [acc '()])
        (cond
          [(null? chars) (reverse (cons (list->string (reverse cur)) acc))]
          [(delim? (car chars))
           (loop (cdr chars) '() (cons (list->string (reverse cur)) acc))]
          [else (loop (cdr chars) (cons (car chars) cur) acc)]))))

  (define (split-lines s) (string-split s #\newline))

  ;; ── 去首尾空白 ──
  (define (string-trim s)
    (list->string
      (let ([cs (string->list s)])
        (reverse (drop-ws (reverse (drop-ws cs)))))))
  (define (drop-ws cs)
    (cond [(null? cs) cs] [(memv (car cs) ws) (drop-ws (cdr cs))] [else cs]))

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
  (define (string-search s sub)
    (let ([ls (string-length s)] [lsub (string-length sub)])
      (let loop ([i 0])
        (cond
          [(> (+ i lsub) ls) #f]
          [(string=? sub (substring s i (+ i lsub))) i]
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
  (define (string-join lst sep)
    (cond
      [(null? lst) ""]
      [else (fold-left (lambda (acc s) (string-append acc sep s)) (car lst) (cdr lst))]))

  ;; ── alist 访问:(alist-ref al key [default]) ──
  (define alist-ref
    (case-lambda
      [(al key) (alist-ref al key #f)]
      [(al key default) (let ([p (assq key al)]) (if p (cdr p) default))]))

  ;; ── 错误处理宏:求值 body,任何异常返回 #f(替 (guard (e [#t #f]) …))──
  (define-syntax ignore-errors
    (syntax-rules ()
      [(_ body ...) (guard (e [#t #f]) body ...)])))
