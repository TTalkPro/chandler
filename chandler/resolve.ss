#!chezscheme
;;; chandler/resolve.ss --- 依赖解析:BFS 层序 + 冲突裁决 + 环检测 + 出 lock(designs/03)
;;;
;;; git-first:无全局版本空间可求解,解析器职责是收集闭包 + 裁决同名冲突 + 定序。
;;; BFS 保证「先见者 = 层近者」;首见即选(root deps 先入队 → 天然 R1 根覆盖 / R2 层近者胜)。
;;; 算法与 IO(metadata provider)解耦:核心可用 mock provider 单测,默认 provider 走 git。

(library (chandler resolve)
  (export resolve resolve/provider
           resolution-lock resolution-warnings)
  (import (chezscheme)
          (chandler util)
          (chandler layout)
          (chandler sexp)
          (chandler manifest)
          (chandler lock)
          (chandler fetch)
          (chandler version))

  (define-record-type resolution (fields lock warnings))

  ;; 待处理依赖 spec(BFS 队列元素)
  (define-record-type rspec
    (fields name source-kind source-loc pin-kind pin-val depth scope root?))

  ;; 已选条目(内部;含 depth,便于裁决与调试)
  (define-record-type rentry
    (fields name source-kind source-loc pin-kind pin-val rev deps natives scope depth path? resources))

  ;; ── 公共入口:默认 git provider ──
  ;; opts: (production . #t) (root-dir . "path")
  (define (resolve root-mf . opts)
    (let ([o (if (null? opts) '() (car opts))])
      (resolve/provider root-mf (git-provider (alist-ref o 'root-dir ".")) o)))

  ;; ── 核心算法(provider 注入)──
  ;; provider: (name sk sl pk pv) → (values rev child-deps natives path? resources)
  ;;   child-deps = manifest dep record 列表;natives = symbol 列表;rev=#f 表 path(不入 lock)
  (define (resolve/provider root-mf provider opts)
    (let* ([production? (alist-ref opts 'production #f)]
           [overrides (manifest-overrides root-mf)]
           [chosen (make-eq-hashtable)]        ; name → rentry
           [warnings '()])
      (define (warn! msg) (set! warnings (cons msg warnings)))

      ;; 初始 frontier:root deps(+ dev-deps 除非 production)
      (define (initial)
        (append
          (map (lambda (d) (dep->rspec d 1 'runtime #t)) (manifest-deps root-mf))
          (if production? '()
              (map (lambda (d) (dep->rspec d 1 'dev #t)) (manifest-dev-deps root-mf)))))

      ;; BFS
      (let loop ([frontier (initial)])
        (unless (null? frontier)
          (let ([next '()])
            (for-each
              (lambda (spec)
                (let ([name (rspec-name spec)])
                  (cond
                    [(hashtable-ref chosen name #f)
                     => (lambda (existing) (arbitrate! existing spec warn!))]
                    [(builtin? name) (void)]         ; 内建库不入图
                    [else
                     ;; 应用 override 的 source/pin 重定向
                     (let* ([spec* (apply-override-source spec overrides)]
                            [entry (resolve-one spec* provider overrides warn!)])
                       (hashtable-set! chosen name entry)
                       ;; 递归其子依赖(path 与 git 一致递归;path 自身不入 lock)
                       (set! next
                         (append next
                           (map (lambda (d)
                                  (dep->rspec d (+ (rspec-depth spec) 1) (rspec-scope spec) #f))
                                (rentry-deps entry)))))])))
              frontier)
            (loop next))))

      ;; 环检测(仓库级):基于 chosen 的 deps 图
      (detect-cycles chosen warn!)

      (make-resolution (chosen->lock chosen root-mf) (reverse warnings))))

  ;; ── 解析单个 spec → rentry ──
  (define (resolve-one spec provider overrides warn!)
    (let ([name (rspec-name spec)]
          [sk (rspec-source-kind spec)])
      ;; prebuilt 在 resolve 层就拒绝,不依赖 provider 实现(D27):
      ;; git-provider 会再挡一次(双保险),但 mock provider / 测试注入的 provider
      ;; 不会 —— 所以检查必须在调 provider 之前,否则 prebuilt 会被静默吞掉。
      (when (eq? sk 'prebuilt)
        (error 'resolve "prebuilt source not yet supported; use git" name))
      (let-values ([(rev child-deps natives path? resources)
                    (provider name sk (rspec-source-loc spec)
                              (rspec-pin-kind spec) (rspec-pin-val spec))])
        ;; override 的 metadata(deps/natives)替换上游
        (let* ([ov (assq name overrides)]
               [deps*   (if (ov-has? ov 'deps) (parse-ov-deps ov) child-deps)]
               [natives* (if (ov-has? ov 'natives) (ov-natives ov) natives)])
          (make-rentry name (rspec-source-kind spec) (rspec-source-loc spec)
                       (rspec-pin-kind spec) (rspec-pin-val spec)
                       rev deps* natives* (rspec-scope spec) (rspec-depth spec) path?
                       resources)))))

  ;; ── 冲突裁决(R1-R4);BFS 下 existing 恒 depth ≤ new,故「首见者胜」──
  (define (arbitrate! existing new warn!)
    (let ([name (rentry-name existing)])
      (cond
        ;; 完全相同来源+pin → 静默(同一依赖多路径到达)
        [(and (equal? (rentry-source-loc existing) (rspec-source-loc new))
              (eq? (rentry-pin-kind existing) (rspec-pin-kind new))
              (equal? (rentry-pin-val existing) (rspec-pin-val new)))
         (void)]
        ;; 不同 host → R4 硬错(疑似撞名两个库)
        [(not (string=? (url-host (rentry-source-loc existing))
                        (url-host (rspec-source-loc new))))
         (error 'resolve
                (format "dependency name ~a collides: already chose ~a, now also ~a on a different host; pin the source with overrides in the root manifest"
                        name (rentry-source-loc existing) (rspec-source-loc new)))]
        ;; 同 host 不同 pin/url → R3 警告,保留首见(层近者胜)
        [else
         (warn! (format "dependency ~a conflict: using ~a@~a (depth ~a), ignoring ~a@~a"
                        name (rentry-source-loc existing)
                        (pin-str (rentry-pin-kind existing) (rentry-pin-val existing))
                        (rentry-depth existing)
                        (rspec-source-loc new)
                        (pin-str (rspec-pin-kind new) (rspec-pin-val new))))])))

  ;; ── chosen → lock(排除 path 依赖;dev scope 保留)──
  (define (chosen->lock chosen root-mf)
    (let ([entries (filter (lambda (e) (not (rentry-path? e)))
                           (vector->list (hashtable-values chosen)))])
      (make-lock
        1
        #f                                  ; manifest-sha256 由 install 层填(它有文件路径)
        chandler-version
        (map entry->locked entries))))

  (define (entry->locked e)
    (make-locked-dep
      (rentry-name e)
      (rentry-source-kind e) (rentry-source-loc e)
      (or (rentry-pin-kind e) 'rev) (or (rentry-pin-val e) (rentry-rev e))
      (rentry-rev e)
      (filter-nonpath-names (rentry-deps e))    ; deps 字段:子依赖名(仅名)
      (rentry-natives e)
       (rentry-scope e)
       (rentry-resources e)
       #f))   ; v2 provenance:resolve 阶段还未填(v2.4 prebuilt 实现时填)

  (define (filter-nonpath-names deps)
    (map dep-name deps))                    ; lock deps 存名;path 子依赖名也留(图完整)

  ;; ── 环检测 ──
  (define (detect-cycles chosen warn!)
    (let ([by-name chosen] [state (make-eq-hashtable)])
      (define (visit n path)
        (case (hashtable-ref state n #f)
          [(done) (void)]
          [(active) (warn! (format "dependency cycle detected: ~a -> ~a (cycle broken, continuing)"
                                   (reverse path) n))]
          [else
           (let ([e (hashtable-ref by-name n #f)])
             (when e
               (hashtable-set! state n 'active)
               (for-each (lambda (d) (visit (dep-name d) (cons n path))) (rentry-deps e))
               (hashtable-set! state n 'done)))]))
      (vector-for-each (lambda (e) (visit (rentry-name e) '()))
                       (hashtable-values chosen))))

  ;; ── git-backed provider ──
  (define (git-provider root-dir)
    (lambda (name sk sl pk pv)
      (case sk
        [(git)
          (let* ([rev (resolve-rev sl pk pv)]
                 [content (show-file sl rev "chandler-manifest.ss")])
            (if content
                (let ([mf (parse-manifest (read-datum-string content))])
                  (values rev (manifest-deps mf)
                          (map native-name (manifest-native mf)) #f
                          (manifest-resources mf)))
                (values rev '() '() #f #f)))]     ; 裸库默认
        [(path)
         (let* ([dir (join-paths root-dir sl)]
                [mpath (join-paths dir "chandler-manifest.ss")])
           (if (file-exists? mpath)
               (let ([mf (read-manifest mpath)])
                  (values #f (manifest-deps mf)
                          (map native-name (manifest-native mf)) #t
                          (manifest-resources mf)))
               (values #f '() '() #t)))]
        [(prebuilt)
         (error 'git-provider "prebuilt source not yet supported; use git" sk)]
        [else (error 'git-provider "unknown source kind" sk)])))

  (define (resolve-rev url pk pv)
    (case pk
      [(tag branch rev) (resolve-pin url pk pv)]
      [(version)
       (let ([t (select-highest pv (list-tags url))])
         (unless t (error 'resolve-rev "no tag satisfies version range" url pv))
         (resolve-tag url t))]
      [(#f) (resolve-pin url 'branch (default-branch url))]
      [else (error 'resolve-rev "unknown pin kind" pk)]))

  (define (default-branch url) "HEAD")     ; 缺 pin:解析远端 HEAD(rev-parse HEAD 生效)

  ;; ── overrides 辅助 ──
  (define (apply-override-source spec overrides)
    (let ([ov (assq (rspec-name spec) overrides)])
      (if (not ov) spec
          (let ([src (ov-field-list ov 'source)]     ; (kind loc)
                [pin (ov-field-list ov 'pin)])        ; (kind val)
            (make-rspec
              (rspec-name spec)
              (if src (car src) (rspec-source-kind spec))
              (if src (cadr src) (rspec-source-loc spec))
              (if pin (car pin) (rspec-pin-kind spec))
              (if pin (cadr pin) (rspec-pin-val spec))
              (rspec-depth spec) (rspec-scope spec) (rspec-root? spec))))))

  (define (ov-field-list ov key)           ; (key a b) → (a b)
    (and ov (let ([f (assq key (cdr ov))]) (and f (cdr f)))))
  (define (ov-has? ov key) (and ov (assq key (cdr ov)) #t))
  (define (ov-natives ov) (or (ov-field-list ov 'natives) '()))
  (define (parse-ov-deps ov)               ; override 的 (deps (name (git url) …) …) → dep records
    (let ([d (assq 'deps (cdr ov))])
      (if (and d (pair? (cdr d)) (pair? (cadr d)))
          (map (lambda (item) (parse-dep-item item)) (cdr d))
          '())))
  ;; 复用 manifest 的 dep 解析:构造成 (deps …) 交 parse
  (define (parse-dep-item item)
    (let ([m (parse-manifest `(manifest (name "x") (version "0") (deps ,item)))])
      (car (manifest-deps m))))

  ;; ── 小工具 ──
  (define (dep->rspec d depth scope root?)
    (make-rspec (dep-name d) (dep-source-kind d) (dep-source-loc d)
                (dep-pin-kind d) (dep-pin-val d) depth scope root?))

  (define (builtin? name) (builtin-prefix? name))

  (define (pin-str k v) (if k (format "~a:~a" k v) "?"))

  ;; 从 URL 抽 host(冲突裁决 R4);https://host/… 或 git@host:… 或本地路径
  (define (url-host url)
    (let ([norm (normalize-url url)])
      (let ([idx (string-search norm "://")])
        (cond
          [idx (let ([slash (char-index norm #\/ (+ idx 3))])
                 (substring norm (+ idx 3) (or slash (string-length norm))))]
          [(char-index norm #\@)
           => (lambda (at)
                (let ([colon (char-index norm #\: at)])
                  (substring norm (+ at 1) (or colon (string-length norm)))))]
          [else norm])))))                  ; 本地 path:整体为「host」,同路径才等
