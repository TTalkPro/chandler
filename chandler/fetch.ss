#!chezscheme
;;; chandler/fetch.ss --- git 镜像缓存 / 解析原语 / 物化(designs/04)
;;;
;;; 网络操作全走缓存间接层:先镜像 clone 到 <cache>/git/<url-key>,解析/物化都从本地缓存。
;;; 安全:所有 git 调用带 -c core.hooksPath=/dev/null(clone/checkout 零执行,designs/08 §3)。
;;; 不内嵌 git,shell out 到系统 git(凭证/代理由用户既有 git 配置接管)。

(library (chandler fetch)
  (export cache-root offline? default-cache-root
          normalize-url url-key mirror-path
          ensure-mirror update-mirror
          resolve-branch resolve-tag list-tags has-rev? resolve-pin
          materialize checkout-detach dirty? head-rev show-file)
  (import (chezscheme)
          (chandler util)
          (chandler fs)
          (chandler proc)
          (chandler layout)
          (chandler hash))

  (define offline? (make-parameter #f))
  (define cache-root (make-parameter #f))   ; #f → 惰性取默认

  (define (default-cache-root)
    (join-paths (or (getenv "XDG_CACHE_HOME") (join-paths (home-dir) ".cache")) "chandler"))

  (define (root) (or (cache-root) (default-cache-root)))

  ;; ── git 调用:统一禁 hooks ──
  (define no-hooks '("-c" "core.hooksPath=/dev/null"))
  (define (git args . opt) (run-check "git" (append no-hooks args) (opt0 opt)))
  (define (git-status args . opt) (run-status "git" (append no-hooks args) (opt0 opt)))
  (define (opt0 opt) (if (null? opt) '() (car opt)))

  ;; ── URL 规范化 + key ──
  ;; 规范化只为 key 归并同库不同写法(https/ssh、带不带 .git、尾斜杠、大小写 host)
  (define (normalize-url url)
    (let* ([s (string-downcase-scheme-host url)]
           [s (strip-suffix s ".git")]
           [s (strip-trailing-slash s)])
      s))

  (define (url-key url)
    (let* ([norm (normalize-url url)]
           [h (substring (sha256-string norm) 0 16)]
           [tail (readable-tail norm)])
      (string-append tail "-" h)))

  (define (mirror-path url)
    (join-paths (join-paths (root) "git") (url-key url)))

  ;; ── 镜像获取 ──
  (define (ensure-mirror url)
    (let ([p (mirror-path url)])
      (cond
        [(file-directory? p) p]
        [(offline?)
         (error 'ensure-mirror
                (format "离线模式,缓存缺该仓库镜像:~a~%  ~a" url p))]
        [else
         (ensure-parent p)
         (git (list "clone" "--mirror" url p))
         p])))

  (define (update-mirror url)
    (let ([p (ensure-mirror url)])
      (when (offline?)
        (error 'update-mirror "离线模式不可 fetch" url))
      (git (list "-C" p "fetch" "--prune" "--tags"))
      p))

  ;; ── 解析原语(尽量缓存零网络;缺失且非离线才 fetch)──
  (define (rev-parse mirror ref)
    ;; 解引用到 commit;失败返回 #f
    (let ([r (run-capture "git"
               (append no-hooks (list "-C" mirror "rev-parse" "--verify" "-q"
                                      (string-append ref "^{commit}"))) '())])
      (if (= 0 (proc-result-code r))
          (string-trim (proc-result-out r))
          #f)))

  (define (resolve-branch url branch)
    (let ([m (ensure-mirror url)])
      (or (rev-parse m branch)
          (and (not (offline?))
               (begin (update-mirror url) (rev-parse m branch)))
          (error 'resolve-branch "分支不存在" url branch))))

  (define (resolve-tag url tag)
    (let ([m (ensure-mirror url)])
      (or (rev-parse m tag)
          (and (not (offline?))
               (begin (update-mirror url) (rev-parse m tag)))
          (error 'resolve-tag "tag 不存在" url tag))))

  (define (list-tags url)
    (let ([m (ensure-mirror url)])
      (filter (lambda (s) (> (string-length s) 0))
              (split-lines (run-check "git" (append no-hooks (list "-C" m "tag" "--list")) '())))))

  (define (has-rev? url rev)
    (let ([m (ensure-mirror url)])
      (= 0 (git-status (list "-C" m "cat-file" "-e" (string-append rev "^{commit}"))))))

  ;; resolve-pin:(kind . val) → 全长 rev。kind ∈ tag/rev/branch/version(version 交解析层预处理)
  (define (resolve-pin url pin-kind pin-val)
    (case pin-kind
      [(tag) (resolve-tag url pin-val)]
      [(branch) (resolve-branch url pin-val)]
      [(rev)
       (let ([m (ensure-mirror url)])
         (or (rev-parse m pin-val)
             (and (not (offline?)) (begin (update-mirror url) (rev-parse m pin-val)))
             (error 'resolve-pin "rev 在仓库中不存在" url pin-val)))]
      [else (error 'resolve-pin "未知 pin 类型" pin-kind)]))

  ;; ── 物化:--shared clone(借缓存对象库)+ detached checkout,保留 .git ──
  (define (materialize url rev dest)
    (let ([m (ensure-mirror url)])
      (unless (has-rev? url rev)
        (unless (offline?) (update-mirror url)))
      (ensure-parent dest)
      (when (file-directory? dest)
        (error 'materialize "目标已存在" dest))
      (git (list "clone" "--shared" "--no-checkout" m dest))
      (git (list "-C" dest "checkout" "--detach" rev))
      dest))

  ;; 从镜像按 rev 读某文件内容(不 checkout);缺失返回 #f。resolve 读上游 manifest 用。
  (define (show-file url rev path)
    (let ([m (ensure-mirror url)])
      (let ([r (run-capture "git"
                 (append no-hooks (list "-C" m "show" (string-append rev ":" path))) '())])
        (if (= 0 (proc-result-code r)) (proc-result-out r) #f))))

  ;; 在已物化的 lib/<name> 中切到另一 rev(install 同步用);rev 须已在共享镜像中
  (define (checkout-detach dir rev)
    (git (list "-C" dir "checkout" "--detach" rev))
    dir)

  ;; lib/<name> 的当前 HEAD rev(verify 用)
  (define (head-rev dir)
    (string-trim (git (list "-C" dir "rev-parse" "HEAD"))))

  ;; 工作区是否有脏改动(verify / install 拒动用)
  (define (dirty? dir)
    (> (string-length
         (string-trim (git (list "-C" dir "status" "--porcelain")))) 0))

  ;; ── URL key 专用助手(通用字符串/FS 工具来自 util/fs)──
  (define (readable-tail norm)
    ;; 取末两段路径,非字母数字换 -
    (let* ([segs (filter (lambda (s) (> (string-length s) 0)) (string-split norm #\/))]
           [n (length segs)]
           [pick (if (>= n 2) (list (list-ref segs (- n 2)) (list-ref segs (- n 1))) segs)])
      (sanitize (string-join pick "-"))))

  (define (sanitize s)
    (list->string
      (map (lambda (c)
             (if (or (char-alphabetic? c) (char-numeric? c) (char=? c #\-) (char=? c #\.))
                 c #\-))
           (string->list s))))

  ;; downcase scheme + host(host 大小写不敏感、path 敏感);scp 式 git@host:path → 全 downcase
  (define (string-downcase-scheme-host url)
    (let ([idx (string-search url "://")])
      (if idx
          (let* ([hostend (or (char-index url #\/ (+ idx 3)) (string-length url))])
            (string-append (string-downcase (substring url 0 hostend))
                           (substring url hostend (string-length url))))
          (string-downcase url))))

  (define (strip-trailing-slash s)
    (let loop ([n (string-length s)])
      (if (and (> n 0) (char=? #\/ (string-ref s (- n 1)))) (loop (- n 1)) (substring s 0 n)))))
