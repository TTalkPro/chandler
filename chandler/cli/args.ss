#!chezscheme
;;; chandler/cli/args.ss --- CLI 参数解析(designs/01)
;;;
;;; 解析 argv → (values subcommand positionals flags rest)。
;;;   --name        → (name . #t)
;;;   --name=val    → (name . "val")
;;;   -C dir        → (C . "dir")(取值短旗标)
;;;   --            → 其后原样进 rest(给 exec 透传)
;;; 未知 --flag 视为布尔;不做严格校验(命令层决定认哪些)。

(library (chandler cli args)
  (export parse-args flag flag? positional-ref)
  (import (chezscheme))

  ;; 取值短旗标(-C dir)
  (define value-short '(#\C))
  ;; 取值长旗标(--tag v / --tag=v 皆可):其余长旗标为布尔
  (define value-long '(tag rev branch path name runtime))

  (define (parse-args argv)
    (let loop ([args argv] [pos '()] [flags '()] [rest #f])
      (cond
        [(null? args)
         (let ([p (reverse pos)])
           (values (if (null? p) #f (car p))     ; subcommand
                   (if (null? p) '() (cdr p))    ; 其余 positionals
                   (reverse flags)
                   (and rest (reverse rest))))]
        [rest                                    ; 已过 -- ,原样收集
         (loop (cdr args) pos flags (cons (car args) rest))]
        [(string=? (car args) "--")
         (loop (cdr args) pos flags '())]
        [(long-flag? (car args))
         (let-values ([(k v) (split-long (car args))])
           (cond
             ;; --k=v 已带值,或非取值长旗标 → 直接用 v(v=#t 表布尔)
             [(not (eq? v 'need-value))
              (loop (cdr args) pos (cons (cons k v) flags) rest)]
             ;; --k(取值长旗标)→ 吃下一个 token 作值
             [(null? (cdr args)) (error 'parse-args "长旗标缺参数" (car args))]
             [else (loop (cddr args) pos (cons (cons k (cadr args)) flags) rest)]))]
        [(short-value-flag? (car args))
         (let ([k (string->symbol (substring (car args) 1 2))])
           (if (null? (cdr args))
               (error 'parse-args "短旗标缺参数" (car args))
               (loop (cddr args) pos (cons (cons k (cadr args)) flags) rest)))]
        [(and (> (string-length (car args)) 1) (char=? #\- (string-ref (car args) 0)))
         ;; 其它短旗标:布尔
         (loop (cdr args) pos
               (cons (cons (string->symbol (substring (car args) 1 (string-length (car args)))) #t)
                     flags) rest)]
        [else (loop (cdr args) (cons (car args) pos) flags rest)])))

  (define (long-flag? s)
    (and (> (string-length s) 2) (string=? "--" (substring s 0 2))))

  (define (short-value-flag? s)
    (and (= (string-length s) 2) (char=? #\- (string-ref s 0))
         (memv (string-ref s 1) value-short)))

  ;; --k 或 --k=v → (values key val);val=#t 布尔、'need-value 待吃下一 token
  (define (split-long s)
    (let ([body (substring s 2 (string-length s))])
      (let ([eq (index-of body #\=)])
        (if eq
            (values (string->symbol (substring body 0 eq))
                    (substring body (+ eq 1) (string-length body)))
            (let ([k (string->symbol body)])
              (values k (if (memq k value-long) 'need-value #t)))))))

  (define (index-of s c)
    (let ([n (string-length s)])
      (let loop ([i 0])
        (cond [(>= i n) #f] [(char=? c (string-ref s i)) i] [else (loop (+ i 1))]))))

  ;; flags alist 访问
  (define (flag flags k . default)
    (let ([p (assq k flags)])
      (if p (cdr p) (if (null? default) #f (car default)))))
  (define (flag? flags k) (and (assq k flags) #t))
  (define (positional-ref pos i default)
    (if (< i (length pos)) (list-ref pos i) default)))
