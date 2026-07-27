#!chezscheme
;;; chandler/hash.ss --- 纯 Scheme SHA-256(自包含,不依赖外部工具)
;;;
;;; 供 lock 的 manifest-sha256 与 registry 文件完整性用(designs/02 §2、05 §2)。
;;; 只用 (chezscheme) 整数位运算,可移植。以标准测试向量校验(见 test/hash.ss)。

(library (chandler hash)
  (export sha256-bytevector sha256-string sha256-file)
  (import (chezscheme))

  (define mask32 #xffffffff)

  ;; ── 32 位字运算 ──
  ;; 每 64 字节的分块要跑约 500 次字运算,这里是全库最热的循环。用 fx* 定点运算
  ;; 取代通用 bitwise-*,省掉泛型数值派发 —— 实测 2.7×。
  ;;
  ;; fx 路径要求 fixnum 容得下 5 个 32 位字之和(< 2^35),即宽度 ≥ 37 位。64 位
  ;; Chez 是 61 位,满足;32 位构建(30 位)容不下,回落通用整数运算 —— 慢,但结果
  ;; 逐位相同。meta-cond 在展开期决断,而 chandler 按 machine-type 分别编译,
  ;; 故展开机即目标机。
  (meta-cond
    [(>= (fixnum-width) 37)
     (define-syntax w+       (syntax-rules () [(_ x ...) (fxand (fx+ x ...) #xffffffff)]))
     (define-syntax wxor     (syntax-rules () [(_ x ...) (fxlogxor x ...)]))
     (define-syntax wand     (syntax-rules () [(_ x y)   (fxand x y)]))
     (define-syntax wandnot  (syntax-rules () [(_ x y)   (fxand (fxnot x) y)]))
     (define-syntax wor      (syntax-rules () [(_ x ...) (fxlogor x ...)]))
     (define-syntax wshl     (syntax-rules () [(_ x n)   (fxsll x n)]))
     (define-syntax wshr     (syntax-rules () [(_ x n)   (fxsrl x n)]))
     ;; 左半必须先掩掉低 n 位再左移:fixnum 容不下 (fxsll x (- 32 n)) 的 2^62。
     (define-syntax wrotr
       (syntax-rules ()
         [(_ x n) (let ([v x])
                    (fxlogor (fxsrl v n)
                             (fxsll (fxand v (fx- (fxsll 1 n) 1)) (fx- 32 n))))]))
     (define-syntax words-ref  (syntax-rules () [(_ v i)   (fxvector-ref v i)]))
     (define-syntax words-set! (syntax-rules () [(_ v i x) (fxvector-set! v i x)]))
     (define (make-words n) (make-fxvector n 0))
     (define (words xs) (list->fxvector xs))]
    [else
     (define-syntax w+       (syntax-rules () [(_ x ...) (bitwise-and (+ x ...) #xffffffff)]))
     (define-syntax wxor     (syntax-rules () [(_ x ...) (bitwise-xor x ...)]))
     (define-syntax wand     (syntax-rules () [(_ x y)   (bitwise-and x y)]))
     (define-syntax wandnot  (syntax-rules () [(_ x y)   (bitwise-and (bitwise-not x) y)]))
     (define-syntax wor      (syntax-rules () [(_ x ...) (bitwise-ior x ...)]))
     (define-syntax wshl     (syntax-rules () [(_ x n)   (bitwise-arithmetic-shift-left x n)]))
     (define-syntax wshr     (syntax-rules () [(_ x n)   (bitwise-arithmetic-shift-right x n)]))
     (define-syntax wrotr
       (syntax-rules ()
         [(_ x n) (let ([v x])
                    (bitwise-and (bitwise-ior (bitwise-arithmetic-shift-right v n)
                                              (bitwise-arithmetic-shift-left v (- 32 n)))
                                 #xffffffff))]))
     (define-syntax words-ref  (syntax-rules () [(_ v i)   (vector-ref v i)]))
     (define-syntax words-set! (syntax-rules () [(_ v i x) (vector-set! v i x)]))
     (define (make-words n) (make-vector n 0))
     (define (words xs) (list->vector xs))])

  (define K
    (words
      '(#x428a2f98 #x71374491 #xb5c0fbcf #xe9b5dba5 #x3956c25b #x59f111f1 #x923f82a4 #xab1c5ed5
        #xd807aa98 #x12835b01 #x243185be #x550c7dc3 #x72be5d74 #x80deb1fe #x9bdc06a7 #xc19bf174
        #xe49b69c1 #xefbe4786 #x0fc19dc6 #x240ca1cc #x2de92c6f #x4a7484aa #x5cb0a9dc #x76f988da
        #x983e5152 #xa831c66d #xb00327c8 #xbf597fc7 #xc6e00bf3 #xd5a79147 #x06ca6351 #x14292967
        #x27b70a85 #x2e1b2138 #x4d2c6dfc #x53380d13 #x650a7354 #x766a0abb #x81c2c92e #x92722c85
        #xa2bfe8a1 #xa81a664b #xc24b8b70 #xc76c51a3 #xd192e819 #xd6990624 #xf40e3585 #x106aa070
        #x19a4c116 #x1e376c08 #x2748774c #x34b0bcb5 #x391c0cb3 #x4ed8aa4a #x5b9cca4f #x682e6ff3
        #x748f82ee #x78a5636f #x84c87814 #x8cc70208 #x90befffa #xa4506ceb #xbef9a3f7 #xc67178f2)))

  (define H0
    '(#x6a09e667 #xbb67ae85 #x3c6ef372 #xa54ff53a #x510e527f #x9b05688c #x1f83d9ab #x5be0cd19))

  ;; padding:附 0x80,补 0 到 56 mod 64,末尾 64-bit 大端位长
  (define (pad bv)
    (let* ([len (bytevector-length bv)]
           [bitlen (* len 8)]
           [k (modulo (- 56 (modulo (+ len 1) 64)) 64)]
           [total (+ len 1 k 8)]
           [out (make-bytevector total 0)])
      (bytevector-copy! bv 0 out 0 len)
      (bytevector-u8-set! out len #x80)
      (do ([i 0 (+ i 1)]) ((= i 8))
        (bytevector-u8-set! out (- total 1 i)
                            (bitwise-and (bitwise-arithmetic-shift-right bitlen (* i 8)) #xff)))
      out))

  (define (sha256-bytevector bv)
    (let ([msg (pad bv)]
          [h (words H0)]            ; 可变副本
          [w (make-words 64)])      ; 消息调度表,跨分块复用
      (let ([nchunks (div (bytevector-length msg) 64)])
        (do ([c 0 (+ c 1)]) ((= c nchunks))
          (process-chunk! h w msg (* c 64))))
      (hash->hex h)))

  (define (process-chunk! h w msg off)
    ;; 前 16 字:大端读入
    (do ([i 0 (+ i 1)]) ((= i 16))
      (let ([b (+ off (* i 4))])
        (words-set! w i
          (wor (wshl (bytevector-u8-ref msg b) 24)
               (wshl (bytevector-u8-ref msg (+ b 1)) 16)
               (wshl (bytevector-u8-ref msg (+ b 2)) 8)
               (bytevector-u8-ref msg (+ b 3))))))
    ;; 扩展 16..63
    (do ([i 16 (+ i 1)]) ((= i 64))
      (let* ([w15 (words-ref w (- i 15))]
             [w2  (words-ref w (- i 2))]
             [s0 (wxor (wrotr w15 7) (wrotr w15 18) (wshr w15 3))]
             [s1 (wxor (wrotr w2 17) (wrotr w2 19) (wshr w2 10))])
        (words-set! w i (w+ (words-ref w (- i 16)) s0 (words-ref w (- i 7)) s1))))
    ;; 压缩
    (let loop ([i 0]
               [a (words-ref h 0)] [b (words-ref h 1)] [c (words-ref h 2)] [d (words-ref h 3)]
               [e (words-ref h 4)] [f (words-ref h 5)] [g (words-ref h 6)] [hh (words-ref h 7)])
      (if (= i 64)
          (begin
            (words-set! h 0 (w+ (words-ref h 0) a))
            (words-set! h 1 (w+ (words-ref h 1) b))
            (words-set! h 2 (w+ (words-ref h 2) c))
            (words-set! h 3 (w+ (words-ref h 3) d))
            (words-set! h 4 (w+ (words-ref h 4) e))
            (words-set! h 5 (w+ (words-ref h 5) f))
            (words-set! h 6 (w+ (words-ref h 6) g))
            (words-set! h 7 (w+ (words-ref h 7) hh)))
          (let* ([S1 (wxor (wrotr e 6) (wrotr e 11) (wrotr e 25))]
                 [ch (wxor (wand e f) (wandnot e g))]
                 [temp1 (w+ hh S1 ch (words-ref K i) (words-ref w i))]
                 [S0 (wxor (wrotr a 2) (wrotr a 13) (wrotr a 22))]
                 [maj (wxor (wand a b) (wand a c) (wand b c))]
                 [temp2 (w+ S0 maj)])
            (loop (+ i 1)
                  (w+ temp1 temp2) a b c
                  (w+ d temp1) e f g)))))

  (define (hash->hex h)
    (let ([op (open-output-string)])
      (do ([i 0 (+ i 1)]) ((= i 8))
        (let ([x (words-ref h i)])
          (do ([s 24 (- s 8)]) ((< s 0))
            (display (hex2 (bitwise-and (bitwise-arithmetic-shift-right x s) #xff)) op))))
      (get-output-string op)))

  (define hex-digits "0123456789abcdef")
  (define (hex2 b)
    (string (string-ref hex-digits (bitwise-arithmetic-shift-right b 4))
            (string-ref hex-digits (bitwise-and b #xf))))

  (define (sha256-string s)
    (sha256-bytevector (string->utf8 s)))

  (define (sha256-file path)
    (sha256-bytevector
      (call-with-port (open-file-input-port path)
        (lambda (p) (get-bytevector-all p))))))
