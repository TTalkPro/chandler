#!chezscheme
;;; chandler/version.ss --- 版本区间解析与匹配(designs/02 §版本区间语法)
;;;
;;; 支持:精确 "1.2.0" / caret "^1.2.0" / tilde "~1.2.0" / 操作符 ">=1.2" ">" "<=" "<" "="
;;;       / 任意 "*" / 空格合取 ">=0.4 <0.5"。caret 用 npm「最左非零」语义
;;;       (^1.2.3→>=1.2.3 <2.0.0;^0.2.3→>=0.2.3 <0.3.0),比朴素「破主版本」更正确。

(library (chandler version)
  (export parse-version version-compare version<? version=?
          version-match? select-highest strip-v)
  (import (chezscheme)
          (chandler util))

  ;; ── 解析:字符串 → (int ...);剥 v 前缀,按 . 切,pre-release/build(- +)截断 ──
  (define (strip-v s)
    (if (and (> (string-length s) 0)
             (memv (string-ref s 0) '(#\v #\V)))
        (substring s 1 (string-length s))
        s))

  (define (parse-version s0)
    (let* ([s (strip-v s0)]
           [core (car (string-split s '(#\- #\+)))]      ; 去 pre-release/build
           [parts (string-split core '(#\.))])
      (map (lambda (p)
             (let ([n (string->number p)])
               (if (and n (integer? n) (exact? n) (>= n 0)) n
                   (error 'parse-version "invalid version component" s0 p))))
           (filter (lambda (p) (> (string-length p) 0)) parts))))

  ;; 分量个数(caret/tilde 判断「指定到哪一级」用)
  (define (version-arity s0)
    (length (parse-version s0)))

  ;; 补齐到 3 位(缺位补 0)
  (define (pad3 v)
    (let loop ([v v] [n 0] [acc '()])
      (cond
        [(= n 3) (reverse acc)]
        [(null? v) (loop v (+ n 1) (cons 0 acc))]
        [else (loop (cdr v) (+ n 1) (cons (car v) acc))])))

  ;; ── 比较:按分量,缺位视 0;返回 -1/0/1 ──
  (define (version-compare a b)
    (let loop ([a (pad-to a b)] [b (pad-to b a)])
      (cond
        [(and (null? a) (null? b)) 0]
        [(< (car a) (car b)) -1]
        [(> (car a) (car b)) 1]
        [else (loop (cdr a) (cdr b))])))

  ;; 把 a 补到至少和 b 一样长(补 0)
  (define (pad-to a b)
    (let ([la (length a)] [lb (length b)])
      (if (>= la lb) a (append a (make-list (- lb la) 0)))))

  (define (version<? a b) (< (version-compare a b) 0))
  (define (version=? a b) (= (version-compare a b) 0))

  ;; ── 约束匹配 ──
  ;; version-match? : 约束串 × 版本串 → bool(合取:空格分隔各项全满足)
  (define (version-match? constraint ver)
    (let ([v (parse-version ver)]
          [toks (filter (lambda (t) (> (string-length t) 0))
                        (string-split constraint '(#\space #\tab)))])
      (for-all (lambda (tok) (match-one tok v)) toks)))

  (define (match-one tok v)
    (cond
      [(string=? tok "*") #t]
      [(string-prefix? "^" tok) (in-range? v (caret-range (rest tok)))]
      [(string-prefix? "~" tok) (in-range? v (tilde-range (rest tok)))]
      [(string-prefix? ">=" tok) (>= (version-compare v (parse-version (rest2 tok))) 0)]
      [(string-prefix? "<=" tok) (<= (version-compare v (parse-version (rest2 tok))) 0)]
      [(string-prefix? ">" tok)  (>  (version-compare v (parse-version (rest tok))) 0)]
      [(string-prefix? "<" tok)  (<  (version-compare v (parse-version (rest tok))) 0)]
      [(string-prefix? "=" tok)  (=  (version-compare v (parse-version (rest tok))) 0)]
      [else               (=  (version-compare v (parse-version tok)) 0)]))  ; 裸串=精确

  ;; range = (lo . hi):lo 闭、hi 开;hi=#f 表无上界
  (define (in-range? v range)
    (and (>= (version-compare v (car range)) 0)
         (or (not (cdr range)) (< (version-compare v (cdr range)) 0))))

  ;; caret:最左非零分量之后可变。lo=pad3;hi=最左非零位+1、其后清零(npm 语义)
  (define (caret-range s)
    (let ([v (pad3 (parse-version s))])
      (cons v (caret-hi v))))

  (define (caret-hi v)
    (let* ([a (list-ref v 0)] [b (list-ref v 1)] [c (list-ref v 2)])
      (cond
        [(> a 0) (list (+ a 1) 0 0)]
        [(> b 0) (list 0 (+ b 1) 0)]
        [(> c 0) (list 0 0 (+ c 1))]
        [else    (list 0 0 1)])))           ; ^0.0.0 → <0.0.1

  ;; tilde:指定到 minor(≥2 分量)→ 放 patch;仅 major → 放 minor
  (define (tilde-range s)
    (let* ([v (pad3 (parse-version s))]
           [arity (version-arity s)]
           [a (list-ref v 0)] [b (list-ref v 1)])
      (if (>= arity 2)
          (cons v (list a (+ b 1) 0))       ; ~1.2 / ~1.2.3 → >=… <1.3.0
          (cons v (list (+ a 1) 0 0)))))    ; ~1 → >=1.0.0 <2.0.0

  ;; ── 从 tag 列表选满足约束的最高者(返回原始 tag 串,或 #f)──
  (define (select-highest constraint tags)
    (let ([ok (filter (lambda (t)
                        (ignore-errors (version-match? constraint t)))  ; 非版本样式 tag 跳过
                      tags)])
      (if (null? ok) #f
          (fold-left (lambda (best t)
                       (if (> (version-compare (parse-version t) (parse-version best)) 0)
                           t best))
                     (car ok) (cdr ok)))))

  ;; ── 小工具(通用字符串来自 util:prefix? / split → string-prefix? / string-split)──
  (define (rest s) (substring s 1 (string-length s)))
  (define (rest2 s) (substring s 2 (string-length s))))
