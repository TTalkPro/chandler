#!chezscheme
;;; chandler/miniregex.ss --- 极简正则(rule pattern 匹配;Chez 无内建 regex)
;;;
;;; 来源:bake/miniregex.ss(原 §3)。**由 B5 提前到 B2**:dsl 的 register-rule!
;;; 要把字符串 pattern 编成 miniregex,engine 的 resolve 要拿它匹配 rule,
;;; 二者都是 B2 的必要前置;而本模块自含 70 行、零下游依赖,提前无代价。
;;;
;;; 支持的文法:字面量、转义 `\X`、`.`(任意单字符)、`^`/`$` 锚点 ——
;;; 足够表达设计里的 rule pattern(如 `\.txt$`)。
;;; 库体末尾把 regexp-match? 注册进 (chandler task-engine) 的
;;; current-regexp-matcher 钩子(load-based bake 靠运行时符号解析,
;;; library 词法封闭,故改参数注册)。

(library (chandler miniregex)
  (export regexp regexp-match?)
  (import (chezscheme)
          (chandler task-engine))

  (define (regexp pat)
    ;; 把 pattern 字符串解析成 miniregex record。
    (let loop ((i 0) (atoms '()) (start? #f) (end? #f))
      (cond
        ((>= i (string-length pat))
         (make-miniregex (reverse atoms) start? end?))
        ((char=? (string-ref pat i) #\^)
         (loop (+ i 1) atoms #t end?))
        ((char=? (string-ref pat i) #\$)
         (loop (+ i 1) atoms start? #t))
        ((char=? (string-ref pat i) #\\)
         (if (< (+ i 1) (string-length pat))
             (loop (+ i 2)
                   (cons (list 'lit (string-ref pat (+ i 1))) atoms)
                   start? end?)
             '()))
        ((char=? (string-ref pat i) #\.)
         (loop (+ i 1) (cons '(any) atoms) start? end?))
        (else
         (loop (+ i 1)
               (cons (list 'lit (string-ref pat i)) atoms)
               start? end?)))))

  (define (regexp-match? re str)
    ;; re 匹配 str 的任意位置即 #t;带锚点则受锚点约束。
    (let* ((r     (if (string? re) (regexp re) re))
           (atoms (miniregex-atoms r))
           (sa?   (miniregex-start-anchored? r))
           (ea?   (miniregex-end-anchored? r))
           (sl    (string-length str))
           (al    (length atoms)))
      (let try-pos ((pos 0))
        (cond
          ((> (+ pos al) sl) #f)
          ((and (try-atoms-at atoms str pos)
                (or (not ea?) (= (+ pos al) sl))
                (or (not sa?) (= pos 0)))
           #t)
          (else (try-pos (+ pos 1)))))))

  (define (try-atoms-at atoms str pos)
    (cond
      ((null? atoms) #t)
      ((>= pos (string-length str)) #f)
      (else
       (let ((a (car atoms)))
         (cond
           ((eq? (car a) 'any)
            (try-atoms-at (cdr atoms) str (+ pos 1)))
           ((char=? (cadr a) (string-ref str pos))
            (try-atoms-at (cdr atoms) str (+ pos 1)))
           (else #f))))))

  ;; ── 注册钩子:engine 的 resolve 用它把 target 名匹配到 rule ──
  (current-regexp-matcher regexp-match?))
