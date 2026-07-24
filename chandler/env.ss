#!chezscheme
;;; chandler/env.ss --- .env 项目配置读取(阶段 C3)
;;;
;;; run / repl / exec 起应用子进程时注入 .env,`chandler env` 也导出它 ——
;;; 应用运行期读配置的统一入口。**不碰 build / deps / install**:那三者若受
;;; 环境变量影响,同一份源码在不同 .env 下会产出不同结果,损害可复现性。
;;;
;;; 决定(2026-07-24,规格来源缺失,由用户逐条拍板):
;;;   • 优先级:.env **覆盖**进程已有环境变量(项目配置即真相);
;;;   • 来源:项目根 <root>/.env + 显式 `--env-file <path>`;依赖树里的 .env
;;;     **一概不读**(依赖是不可信第三方,它的 .env 不该被你的进程加载 ——
;;;     否则依赖可偷偷注入 PATH/LD_PRELOAD 等,与 designs/08 信任模型一致);
;;;   • 语法:`KEY=value` 一行一条,`#` 行注释与空行跳过,可选 `export ` 前缀;
;;;     value 支持单/双引号与 `${VAR}` 展开(单引号内不展开,同 shell)。
;;;
;;; 返回**有序** alist((key . value) …,文件顺序),不直接 putenv —— 调用方决定
;;; 是注入子进程(env-prefix)还是导出(chandler env)。同一进程内也就不会污染
;;; chandler 自己的环境。

(library (chandler env)
  (export read-dotenv dotenv-file-path)
  (import (chezscheme)
          (chandler util)
          (chandler layout)
          (chandler fs))

  (define (dotenv-file-path root) (join-paths root ".env"))

  ;; path → ((key . value) …);文件不存在返回 '()。展开 ${VAR} 时,先查**本文件里
  ;; 更早的条目**,再查进程环境(getenv),都无则空串 —— 与 shell dotenv 一致。
  (define (read-dotenv path)
    (if (not (file-exists? path))
        '()
        (let loop ([lines (read-lines path)] [n 1] [acc '()])
          (if (null? lines)
              (reverse acc)
              (let ([entry (parse-line (car lines) n acc path)])
                (loop (cdr lines) (+ n 1)
                      (if entry (cons entry acc) acc)))))))

  ;; 一行 → (key . value) 或 #f(空行/注释)。malformed 即报错(带行号,可操作)。
  ;; acc 是**倒序**的已解析条目(供 ${VAR} 查更早的值)。
  (define (parse-line raw n acc path)
    (let ([line (string-trim raw)])
      (cond
        [(string=? line "") #f]
        [(char=? #\# (string-ref line 0)) #f]
        [else
         (let* ([line (strip-export line)]
                [eq (char-index line #\=)])
           (unless eq
             (error 'read-dotenv
                    (format "~a:~a: line is neither blank, comment, nor KEY=value: ~s"
                            path n raw)))
           (let ([key (string-trim (substring line 0 eq))]
                 [rhs (substring line (+ eq 1) (string-length line))])
             (when (string=? key "")
               (error 'read-dotenv (format "~a:~a: empty variable name" path n)))
             (unless (valid-key? key)
               (error 'read-dotenv
                      (format "~a:~a: invalid variable name ~s (want [A-Za-z_][A-Za-z0-9_]*)"
                              path n key)))
             (cons key (parse-value (string-trim-left rhs) acc))))])))

  ;; 可选 `export ` 前缀(.env 常见,便于 `source` 该文件)
  (define (strip-export line)
    (if (and (>= (string-length line) 7) (string=? (substring line 0 7) "export "))
        (string-trim-left (substring line 7 (string-length line)))
        line))

  (define (valid-key? k)
    (and (> (string-length k) 0)
         (let ([c0 (string-ref k 0)])
           (or (char-alphabetic? c0) (char=? c0 #\_)))
         (let loop ([i 1])
           (or (>= i (string-length k))
               (let ([c (string-ref k i)])
                 (and (or (char-alphabetic? c) (char-numeric? c) (char=? c #\_))
                      (loop (+ i 1))))))))

  ;; value 三形:'…'(字面,不展开)/ "…"(展开 + 转义)/ 裸(展开,去尾部空白)
  (define (parse-value v acc)
    (cond
      [(string=? v "") ""]
      [(char=? #\' (string-ref v 0)) (single-quoted v)]
      [(char=? #\" (string-ref v 0)) (expand-vars (double-quoted v) acc)]
      [else (expand-vars (string-trim-right v) acc)]))

  ;; 取到闭合引号为止;缺闭合引号则取到行尾(宽容)
  (define (single-quoted v)
    (let ([i (char-index-from v #\' 1)])
      (if i (substring v 1 i) (substring v 1 (string-length v)))))

  ;; 双引号:取到闭合引号,途中 \n \t \r \\ \" 转义;缺闭合取到行尾
  (define (double-quoted v)
    (let ([n (string-length v)])
      (let loop ([i 1] [out '()])
        (cond
          [(>= i n) (list->string (reverse out))]
          [(char=? (string-ref v i) #\") (list->string (reverse out))]
          [(and (char=? (string-ref v i) #\\) (< (+ i 1) n))
           (let ([c (string-ref v (+ i 1))])
             (loop (+ i 2)
                   (cons (case c
                           [(#\n) #\newline] [(#\t) #\tab] [(#\r) #\return]
                           [else c])          ; \\ \" \$ 等:取原字符
                         out)))]
          [else (loop (+ i 1) (cons (string-ref v i) out))]))))

  ;; ${VAR} 展开:先查本文件更早条目(acc 倒序),再查进程环境,都无 → 空串。
  ;; 只认 ${…} 形(规格限定),裸 $VAR 不展开(避免路径里的 $ 误伤)。
  (define (expand-vars s acc)
    (let ([n (string-length s)])
      (let loop ([i 0] [out '()])
        (cond
          [(>= i n) (list->string (reverse out))]
          [(and (char=? (string-ref s i) #\$)
                (< (+ i 1) n) (char=? (string-ref s (+ i 1)) #\{))
           (let ([close (char-index-from s #\} (+ i 2))])
             (if close
                 (let* ([name (substring s (+ i 2) close)]
                        [val  (lookup name acc)])
                   (loop (+ close 1) (append (reverse (string->list val)) out)))
                 ;; 无闭合 } → 原样保留 ${,不当展开
                 (loop (+ i 1) (cons #\$ out))))]
          [else (loop (+ i 1) (cons (string-ref s i) out))]))))

  (define (lookup name acc)
    (cond
      [(assoc name acc) => cdr]              ; 本文件更早的条目优先
      [(getenv name)]                        ; 再查进程环境
      [else ""]))

  ;; 小工具(util 里有 string-trim,但没有单侧 trim / 从某位起找字符)
  (define (string-trim-left s)
    (let ([n (string-length s)])
      (let loop ([i 0])
        (cond [(>= i n) ""]
              [(char-whitespace? (string-ref s i)) (loop (+ i 1))]
              [else (substring s i n)]))))

  (define (string-trim-right s)
    (let loop ([i (string-length s)])
      (cond [(= i 0) ""]
            [(char-whitespace? (string-ref s (- i 1))) (loop (- i 1))]
            [else (substring s 0 i)])))

  (define (char-index-from s ch start)
    (let ([n (string-length s)])
      (let loop ([i start])
        (cond [(>= i n) #f]
              [(char=? (string-ref s i) ch) i]
              [else (loop (+ i 1))])))))
