#!chezscheme
;;; chandler/pack/verify.ss --- verify-pack(原 pack.ss §9)
;;;
;;; 完整性 + (可选)format/target 校验(designs/09 §9, 10 §7)
;;;   完整性(2026-07-26 严格化):顶层必须 (pack …)(expect-tag,受控错);
;;;   (files …) 缺失/为空即 65 —— 没有文件清单的包无法证明完整性(旧行为把
;;;   缺失当空表 → 所有文件 EXTRA 却不计 bad → 对任何包开绿灯)。每个 entry 必须
;;;   ("<rel>" (sha256 "<hex>") (size <n>)),缺 hash/size 即 fatal(旧行为是
;;;   (and want-h …) 条件检查:没声明 hash 的 entry 只要文件在就过)。
;;;   MISSING/CHANGED/INVALID/EXTRA 全部计入 bad —— EXTRA 曾只报告,但不在
;;;   清单里的文件可能是注入载荷,必须致命。
;;;   L1 加两块(designs/10 §7):
;;;     verify-format!       (format N) > pack-format-supported(=1)→ 70;
;;;     --target             对当前 runtime 跑 designs/10 §4 全矩阵 → 78。
;;;   退出码(sysexits):0 全过;65 完整性/schema 错(EX_DATAERR,对齐 skiff/app.ss);
;;;   70 format 超出(EX_SOFTWARE);78 --target 不符(EX_CONFIG)。
;;;   与 bootstrap 共用措辞与单行 s-expr 诊断(那边是自含生成码,这边直调
;;;   (chandler runtime)/(chandler version);决策表是同一份)。

(library (chandler pack verify)
  (export verify-pack)
  (import (chezscheme)
          (chandler fs)
          (chandler sexp)
          (chandler hash)
          (chandler layout)
          (chandler version)
          (chandler runtime-detector)
          (chandler util))

  (define pack-format-supported 1)

  (define (%pack-err msg)
    (fprintf (current-error-port) "chandler-pack: ~a~%" msg)
    (flush-output-port (current-error-port)))

  (define (%pack-err-sexp s)
    (fprintf (current-error-port) "~s~%" s)
    (flush-output-port (current-error-port)))

  ;; pack-field1 已由 (chandler sexp) 的 field-ref 提供同一语义(assq + cadr)。

  ;; (format N) 前向兼容:N > pack-format-supported(=1)→ 70 EX_SOFTWARE;
  ;; 字段缺省视为 0(对齐 bootstrap 的 verify-format-src)。返回 #f(通过)或 70。
  (define (verify-pack-format! fields)
    (let ([fmt (or (field-ref fields 'format) 0)])
      (and (number? fmt) (> fmt pack-format-supported)
           (begin
             (%pack-err (format "pack format ~a is newer than supported (~a)"
                                fmt pack-format-supported))
             (%pack-err-sexp (list 'chandler-pack-error
                                   (list 'format-too-new
                                         (list 'pack fmt)
                                         (list 'supported pack-format-supported))))
             70))))

  ;; entry schema:必须 ("<rel>" (sha256 "<hex>") (size <n>))。返回 #f(合法)
  ;; 或缺失原因 symbol。缺任一项 → 该 entry 计 bad(严格化:不再「文件在就过」)。
  (define (verify-entry-schema e)
    (cond
      [(not (and (pair? e) (string? (car e)))) 'malformed-entry]
                   [(not (string? (field-ref (cdr e) 'sha256))) 'missing-sha256]
      ;; integer? 是全类型安全谓词(#f/"x" → #f),exact? 不是(非 number 即抛)
                   [(let ([s (field-ref (cdr e) 'size)]) (not (and (integer? s) (exact? s)))) 'missing-size]
      [else #f]))

  ;; 完整性:MISSING/CHANGED/INVALID(schema)/EXTRA 全部记 bad(致命)。返回 bad 计数。
  (define (verify-pack-integrity! root files)
    ;; declared 是 rel → #t 索引而非表:下面 EXTRA 那一趟要对包里**每个**文件查一次
    ;; 「清单声明过没有」,而清单条目数 = 包内文件数,拿 member 线性扫就是平方级。
    (let ([declared (make-hashtable string-hash string=?)] [ok 0] [bad 0] [extra 0])
      (for-each
        (lambda (e)
          ;; rel 可辨即先登记:schema 不合格的 entry 不该再让同名文件被二次计 EXTRA
          (when (and (pair? e) (string? (car e)))
            (hashtable-set! declared (car e) #t))
          (let ([schema-bad (verify-entry-schema e)])
            (if schema-bad
                (begin
                  (set! bad (+ bad 1))
                  (fprintf (current-error-port) "  INVALID ~s (~a)~%" e schema-bad))
                (let* ([rel (car e)]
                   [want-h (field-ref (cdr e) 'sha256)]
                   [want-s (field-ref (cdr e) 'size)]
                       [abs (join-paths root rel)])
                  (cond
                    [(not (file-exists? abs))
                     (set! bad (+ bad 1)) (fprintf (current-error-port) "  MISSING ~a~%" rel)]
                    [(not (string=? want-h (sha256-file abs)))
                     (set! bad (+ bad 1)) (fprintf (current-error-port) "  CHANGED ~a (sha256 mismatch)~%" rel)]
                     [(not (= want-s (file-byte-size abs)))
                     (set! bad (+ bad 1)) (fprintf (current-error-port) "  CHANGED ~a (size mismatch)~%" rel)]
                    [else (set! ok (+ ok 1))])))))
        files)
      ;; pack.manifest 自己从不被声明(最后写),排除掉;其余未声明文件 = EXTRA,致命
      (for-each
        (lambda (abs)
          (let ([rel (strip-prefix abs (string-append root "/"))])
            (unless (or (string=? rel "pack.manifest") (hashtable-ref declared rel #f))
              (set! extra (+ extra 1))
              (set! bad (+ bad 1))
              (fprintf (current-error-port) "  EXTRA ~a (not in manifest)~%" rel))))
        (files-under root))
      (printf "verify ~a: ~a ok, ~a bad, ~a extra~%" root ok bad extra)
      bad))

  ;; runtime-aware verify-target!(designs/10 §4 矩阵,与 bootstrap 的
  ;; full-target-check-src 同决策、同措辞):
  ;;   - machine-type / chez-version 永不放宽,不符即 78 EX_CONFIG;
  ;;   - (skiff-version "X") 精确:runtime 是 skiff 则值比对;是 stock 则必 78;
  ;;   - (skiff-compat "<range>") 非全开:runtime 是 skiff 则 version-match?;
  ;;     是 stock 则必 78;全开 ">=0.0.0"(stock 包默认)在两种 runtime 上都过;
  ;;   - 两者都不声明:不查 skiff;
  ;;   - SKIFF_ALLOW_VERSION_SKEW=1 只放宽 skiff 维(WARNING + 通过);
  ;;   - 缺 (target …) → 65 EX_DATAERR。
  ;; 全部不符项收集后一次性出人读诊断 + 单行 s-expr。返回 #f(通过)或退出码。
  (define (verify-pack-target! fields)
    (let ([target (assq 'target fields)])
      (cond
        [(not target)
         (%pack-err "manifest missing (target ...)")
         (%pack-err-sexp '(chandler-pack-error (manifest-invalid (target-missing))))
         65]
        [else
         (let* ([tfields (cdr target)]
                   [want-mt (field-ref tfields 'machine-type)]
                   [want-chez (field-ref tfields 'chez-version)]
                   [want-skiff (field-ref tfields 'skiff-version)]
                   [want-compat (field-ref tfields 'skiff-compat)]
                [rt (current-runtime)]
                [actual-mt (machine-type)]
                [actual-chez (chez-version-string)]
                [skew-ok? (equal? (getenv "SKIFF_ALLOW_VERSION_SKEW") "1")]
                [bad '()]
                [mismatch! (lambda (what expected actual advice)
                             (set! bad (cons (list what expected actual advice) bad)))])
           (unless (eq? want-mt actual-mt)
             (mismatch! 'machine-type want-mt actual-mt
                        "wrong platform pack; fetch the build for this machine-type"))
           (unless (equal? want-chez actual-chez)
             (mismatch! 'chez-version want-chez actual-chez
                        "install the matching runtime or re-pack the app"))
           (cond
             [(and want-skiff (string? want-skiff))
              (if (eq? rt 'skiff)
                  (let ([actual (runtime-version)])
                    (unless (equal? actual want-skiff)
                      (if skew-ok?
                          (%pack-err (format "WARNING: skiff-version skew allowed by SKIFF_ALLOW_VERSION_SKEW=1 (pack ~a, runtime ~a)"
                                             want-skiff actual))
                          (mismatch! 'skiff-version want-skiff actual
                                     "install the matching skiff runtime or re-pack the app"))))
                  (mismatch! 'skiff-version want-skiff 'stock-chez
                             "pack requires skiff, current runtime is stock Chez"))]
             [(and want-compat (string? want-compat)
                   (not (string=? want-compat ">=0.0.0")))
              (if (eq? rt 'skiff)
                  (let ([actual (runtime-version)])
                    (unless (and actual (version-match? want-compat actual))
                      (if skew-ok?
                          (%pack-err (format "WARNING: skiff-version skew allowed by SKIFF_ALLOW_VERSION_SKEW=1 (pack compat ~a, runtime ~a)"
                                             want-compat actual))
                          (mismatch! 'skiff-version (string-append "compat " want-compat) actual
                                     "install the matching skiff runtime or re-pack the app"))))
                  (mismatch! 'skiff-version (string-append "compat " want-compat) 'stock-chez
                             "pack requires skiff, current runtime is stock Chez"))]
             [else #t])
           (if (null? bad)
               #f
               (begin
                 (%pack-err "pack target mismatch; refusing to load")
                 (for-each
                   (lambda (b)
                     (%pack-err (format "  ~a: expected ~s, actual ~s~%    -> ~a"
                                        (car b) (cadr b) (caddr b) (cadddr b))))
                   (reverse bad))
                 (%pack-err-sexp
                   (cons 'chandler-pack-error
                         (list (cons 'target-mismatch
                                     (map (lambda (b)
                                            (list (car b)
                                                  (list 'expected (cadr b))
                                                  (list 'actual (caddr b))))
                                          (reverse bad))))))
                 78)))])))

  ;; (files …) 缺失/为空/非列表 → 65 EX_DATAERR:没有文件清单的包无法证明完整性。
  ;; 旧行为把缺失当空表 → 所有文件成 EXTRA 却不计 bad → 对任何包都开绿灯。
  (define (verify-pack-files-field! files)
    (and (or (not files) (null? files) (not (list? files)))
         (begin
           (%pack-err "manifest missing or empty (files ...)")
           (%pack-err-sexp '(chandler-pack-error (manifest-invalid (files-missing))))
           65)))

  ;; verify-pack path [target?] → 退出码。顺序:format → files 清单在否 → 完整性 →
  ;; --target(format 太新时清单结构不可信,先于一切;没有 (files …) 则完整性无从
  ;; 谈起;--target 是「这包能不能在本机跑」的附加检查,只在完整性过关后有意义)。
  ;; 顶层 datum 经 expect-tag:不是 (pack …) → 受控错(不再是低级 cdr 错)。
  (define (verify-pack path . maybe-target?)
    (let ([target? (and (pair? maybe-target?) (car maybe-target?))])
      (let* ([is-mf (string-suffix? "pack.manifest" path)]
             [root  (if is-mf (parent-dir path) path)]
             [mf    (if is-mf path (join-paths path "pack.manifest"))])
        (unless (file-exists? mf)
          (error 'verify-pack (format "pack.manifest not found at ~a" mf)))
        (let* ([form   (read-datum-file mf)]
               [fields (expect-tag form 'pack 'verify-pack)]
               [files  (let ([c (assq 'files fields)]) (and c (cdr c)))])
          (or (verify-pack-format! fields)
              (verify-pack-files-field! files)
              (let ([bad (verify-pack-integrity! root files)])
                (cond
                  [(> bad 0) 65]
                  [target? (or (verify-pack-target! fields) 0)]
                   [else 0])))))))

  ;; attr 已由 (chandler sexp) 的 field-ref 提供同一语义;
  ;; (attr key e) ≡ (field-ref (cdr e) key)。
  )
