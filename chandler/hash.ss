#!chezscheme
;;; chandler/hash.ss --- 纯 Scheme SHA-256(自包含,不依赖外部工具)
;;;
;;; 供 lock 的 manifest-sha256 与 registry 文件完整性用(designs/02 §2、05 §2)。
;;; 只用 (chezscheme) 整数位运算,可移植。以标准测试向量校验(见 test/hash.ss)。

(library (chandler hash)
  (export sha256-bytevector sha256-string sha256-file)
  (import (chezscheme))

  (define mask32 #xffffffff)

  (define (u32 x) (bitwise-and x mask32))
  (define (add . xs) (u32 (apply + xs)))

  (define (rotr x n)
    (u32 (bitwise-ior (bitwise-arithmetic-shift-right x n)
                      (bitwise-arithmetic-shift-left x (- 32 n)))))
  (define (shr x n) (bitwise-arithmetic-shift-right x n))

  (define K
    '#(#x428a2f98 #x71374491 #xb5c0fbcf #xe9b5dba5 #x3956c25b #x59f111f1 #x923f82a4 #xab1c5ed5
       #xd807aa98 #x12835b01 #x243185be #x550c7dc3 #x72be5d74 #x80deb1fe #x9bdc06a7 #xc19bf174
       #xe49b69c1 #xefbe4786 #x0fc19dc6 #x240ca1cc #x2de92c6f #x4a7484aa #x5cb0a9dc #x76f988da
       #x983e5152 #xa831c66d #xb00327c8 #xbf597fc7 #xc6e00bf3 #xd5a79147 #x06ca6351 #x14292967
       #x27b70a85 #x2e1b2138 #x4d2c6dfc #x53380d13 #x650a7354 #x766a0abb #x81c2c92e #x92722c85
       #xa2bfe8a1 #xa81a664b #xc24b8b70 #xc76c51a3 #xd192e819 #xd6990624 #xf40e3585 #x106aa070
       #x19a4c116 #x1e376c08 #x2748774c #x34b0bcb5 #x391c0cb3 #x4ed8aa4a #x5b9cca4f #x682e6ff3
       #x748f82ee #x78a5636f #x84c87814 #x8cc70208 #x90befffa #xa4506ceb #xbef9a3f7 #xc67178f2))

  (define H0
    '#(#x6a09e667 #xbb67ae85 #x3c6ef372 #xa54ff53a #x510e527f #x9b05688c #x1f83d9ab #x5be0cd19))

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
          [h (list->vector (vector->list H0))])   ; 可变副本
      (let ([nchunks (div (bytevector-length msg) 64)])
        (do ([c 0 (+ c 1)]) ((= c nchunks))
          (process-chunk! h msg (* c 64))))
      (hash->hex h)))

  (define (process-chunk! h msg off)
    (let ([w (make-vector 64 0)])
      ;; 前 16 字:大端读入
      (do ([i 0 (+ i 1)]) ((= i 16))
        (let ([b (+ off (* i 4))])
          (vector-set! w i
            (u32 (bitwise-ior
                   (bitwise-arithmetic-shift-left (bytevector-u8-ref msg b) 24)
                   (bitwise-arithmetic-shift-left (bytevector-u8-ref msg (+ b 1)) 16)
                   (bitwise-arithmetic-shift-left (bytevector-u8-ref msg (+ b 2)) 8)
                   (bytevector-u8-ref msg (+ b 3)))))))
      ;; 扩展 16..63
      (do ([i 16 (+ i 1)]) ((= i 64))
        (let* ([s0 (bitwise-xor (rotr (vector-ref w (- i 15)) 7)
                                (rotr (vector-ref w (- i 15)) 18)
                                (shr (vector-ref w (- i 15)) 3))]
               [s1 (bitwise-xor (rotr (vector-ref w (- i 2)) 17)
                                (rotr (vector-ref w (- i 2)) 19)
                                (shr (vector-ref w (- i 2)) 10))])
          (vector-set! w i (add (vector-ref w (- i 16)) s0 (vector-ref w (- i 7)) s1))))
      ;; 压缩
      (let loop ([i 0]
                 [a (vector-ref h 0)] [b (vector-ref h 1)] [c (vector-ref h 2)] [d (vector-ref h 3)]
                 [e (vector-ref h 4)] [f (vector-ref h 5)] [g (vector-ref h 6)] [hh (vector-ref h 7)])
        (if (= i 64)
            (begin
              (vector-set! h 0 (add (vector-ref h 0) a))
              (vector-set! h 1 (add (vector-ref h 1) b))
              (vector-set! h 2 (add (vector-ref h 2) c))
              (vector-set! h 3 (add (vector-ref h 3) d))
              (vector-set! h 4 (add (vector-ref h 4) e))
              (vector-set! h 5 (add (vector-ref h 5) f))
              (vector-set! h 6 (add (vector-ref h 6) g))
              (vector-set! h 7 (add (vector-ref h 7) hh)))
            (let* ([S1 (bitwise-xor (rotr e 6) (rotr e 11) (rotr e 25))]
                   [ch (bitwise-xor (bitwise-and e f) (bitwise-and (bitwise-not e) g))]
                   [temp1 (add hh S1 ch (vector-ref K i) (vector-ref w i))]
                   [S0 (bitwise-xor (rotr a 2) (rotr a 13) (rotr a 22))]
                   [maj (bitwise-xor (bitwise-and a b) (bitwise-and a c) (bitwise-and b c))]
                   [temp2 (add S0 maj)])
              (loop (+ i 1)
                    (add temp1 temp2) a b c
                    (add d temp1) e f g))))))

  (define (hash->hex h)
    (let ([op (open-output-string)])
      (do ([i 0 (+ i 1)]) ((= i 8))
        (let ([x (vector-ref h i)])
          (do ([s 24 (- s 8)]) ((< s 0))
            (let ([byte (bitwise-and (bitwise-arithmetic-shift-right x s) #xff)])
              (display (hex2 byte) op)))))
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
