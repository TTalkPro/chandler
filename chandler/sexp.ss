#!chezscheme
;;; chandler/sexp.ss --- 清单 read + canonical 写(只读不求值)+ s-表达式访问助手
;;;
;;; 安全边界(见 designs/08 §3):清单(manifest/lock/registry/pack)一律 `read` 为
;;; 纯数据,永不 eval/load。本库只提供 read/write 与结构访问,不含任何求值。
;;; canonical 写保证「同输入 → 同字节」(见 designs/02 §2 lock 字节稳定要求)。

(library (chandler sexp)
  (export read-datum-file write-canonical-file canonical-string
          tagged-list? expect-tag
          field field-ref field-ref* field-all field-keys
          alist->sorted)
  (import (chezscheme))

  ;; ── 读:单一顶层 datum,拒空/拒多 form ──
  (define (read-datum-file path)
    (call-with-input-file path
      (lambda (p)
        (let ([datum (read p)])
          (when (eof-object? datum)
            (error 'read-datum-file "文件为空,期望单一 s-表达式" path))
          (let ([rest (read p)])
            (unless (eof-object? rest)
              (error 'read-datum-file "文件含多个顶层 form,期望单一" path rest)))
          datum))))

  ;; ── 结构助手 ──
  ;; (tagged-list? x 'foo) → x 形如 (foo ...)
  (define (tagged-list? x tag)
    (and (pair? x) (eq? (car x) tag)))

  ;; 断言 datum 是 (tag ...),返回其 body(cdr);否则报错
  (define (expect-tag datum tag who)
    (unless (tagged-list? datum tag)
      (error who (format "期望 (~a ...),实际" tag) datum))
    (cdr datum))

  ;; 在 body(形如 ((k v ...) ...))中找**首个** key=k 的项,返回整项 (k v ...) 或 #f
  (define (field body k)
    (cond
      [(null? body) #f]
      [(and (pair? (car body)) (eq? (caar body) k)) (car body)]
      [else (field (cdr body) k)]))

  ;; 取 (k v) 的 v(单值);缺省返回 default(默认 #f)
  (define field-ref
    (case-lambda
      [(body k) (field-ref body k #f)]
      [(body k default)
       (let ([f (field body k)])
         (if (and f (pair? (cdr f))) (cadr f) default))]))

  ;; 取 (k v0 v1 ...) 的全部 v(列表);缺省 '()
  (define (field-ref* body k)
    (let ([f (field body k)])
      (if f (cdr f) '())))

  ;; 取 body 中**所有** key=k 的项(可重复字段,如 deps 内多条)
  (define (field-all body k)
    (filter (lambda (x) (and (pair? x) (eq? (car x) k))) body))

  ;; body 内所有形如 (k ...) 的顶层字段的 key 列表(校验未知字段用)
  (define (field-keys body)
    (map car (filter pair? body)))

  ;; alist 按 car(symbol)字典序稳定排序 —— lock canonical 输出用
  (define (alist->sorted alist)
    (list-sort (lambda (a b)
                 (string<? (symbol->string (car a)) (symbol->string (car b))))
               alist))

  ;; ── canonical 写:确定性缩进打印,同输入必出同字节 ──
  (define line-budget 72)              ; 叶子列表内联上限(字符)

  (define (canonical-string datum)
    (let ([op (open-output-string)])
      (print-datum datum op 0)
      (newline op)                     ; 文件尾恒一个换行
      (get-output-string op)))

  (define (write-canonical-file path datum)
    (call-with-output-file path
      (lambda (p) (display (canonical-string datum) p))
      'truncate))

  ;; 打印一个 datum,col = 当前列(即左括号所在缩进)
  (define (print-datum x op col)
    (cond
      [(and (pair? x) (list? x)) (print-list x op col)]
      [else (write-atom x op)]))

  (define (write-atom x op) (write x op))

  ;; 叶子列表(元素全为原子)且短 → 内联;否则首元素跟在 ( 后,余元素逐行缩进 +2
  (define (print-list lst op col)
    (let ([inline (try-inline lst)])
      (if (and inline (<= (+ col (string-length inline)) line-budget))
          (display inline op)
          (print-list-broken lst op col))))

  ;; 尝试整表内联为一行字符串;含子列表也可内联(只要总长受控,由调用方判 budget)
  (define (try-inline lst)
    (let ([op (open-output-string)])
      (write-inline lst op)
      (get-output-string op)))

  (define (write-inline x op)
    (cond
      [(and (pair? x) (list? x))
       (display "(" op)
       (let loop ([xs x] [first #t])
         (unless (null? xs)
           (unless first (display " " op))
           (write-inline (car xs) op)
           (loop (cdr xs) #f)))
       (display ")" op)]
      [else (write-atom x op)]))

  (define (print-list-broken lst op col)
    (display "(" op)
    (let* ([head (car lst)]
           [rest (cdr lst)]
           ;; 首元素与 ( 同行
           [ignore (print-datum head op (+ col 1))]
           [child-col (+ col 2)])
      (for-each
        (lambda (e)
          (newline op)
          (indent op child-col)
          (print-datum e op child-col))
        rest)
      (display ")" op)))

  (define (indent op n)
    (do ([i 0 (+ i 1)]) ((= i n)) (display #\space op))))
