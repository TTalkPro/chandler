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

  ;; 缓存根。Windows 上走 `%LOCALAPPDATA%`,与 (chandler registry) 的
  ;; default-user-libdir 同一套判别 —— 先前无条件落到 `~/.cache/chandler`,
  ;; 能用但不合 Windows 惯例(那里 `~/.cache` 不是任何工具会去看的地方)。
  ;; `XDG_CACHE_HOME` 显式设置时仍然优先,两个平台一致。
  (define (default-cache-root)
    (cond
      [(getenv* "XDG_CACHE_HOME") => (lambda (d) (join-paths d "chandler"))]
      [(windows-mt? (current-machine-type))
       (join-paths (or (getenv* "LOCALAPPDATA") (home-dir)) "chandler" "cache")]
      [else (join-paths (join-paths (home-dir) ".cache") "chandler")]))

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
                (format "offline mode: no cached mirror for ~a~%  ~a" url p))]
        [else
         (ensure-parent p)
         (git (list "clone" "--mirror" url p))
         p])))

  (define (update-mirror url)
    (let ([p (ensure-mirror url)])
      (when (offline?)
        (error 'update-mirror "cannot fetch in offline mode" url))
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
          (error 'resolve-branch "branch not found" url branch))))

  (define (resolve-tag url tag)
    (let ([m (ensure-mirror url)])
      (or (rev-parse m tag)
          (and (not (offline?))
               (begin (update-mirror url) (rev-parse m tag)))
          (error 'resolve-tag "tag not found" url tag))))

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
             (error 'resolve-pin "rev not found in repository" url pin-val)))]
      [else (error 'resolve-pin "unknown pin kind" pin-kind)]))

  ;; ── 物化:--shared clone(借缓存对象库)+ detached checkout,保留 .git ──
  (define (materialize url rev dest)
    (let ([m (ensure-mirror url)])
      (unless (has-rev? url rev)
        (unless (offline?) (update-mirror url)))
      (ensure-parent dest)
      (when (file-directory? dest)
        (error 'materialize "destination already exists" dest))
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
  ;;
  ;; **忽略 chandler 自己的产物**:`chandler build` 就地把对象编进
  ;; `_vendor/<dep>/<srcdir>/_build/<mt>/` —— 那棵树在依赖仓库里没被 track,`git status`
  ;; 照单报成 untracked。若把它算作「本地改动」,正常工作流会两处被卡住:
  ;;   · `chandler deps` 在 build 之后报「has local changes; refusing to overwrite」;
  ;;   · `chandler verify` 在 build 之后恒失败。
  ;; 而那是**我们生成的**东西,不是用户的改动;它的一致性由 lock 的 `(files …)` 之外
  ;; 那条规则管(生产与校验两侧都排除 `_build/`,见 install 的 vendor-unmanaged-path?)。
  (define (dirty? dir)
    (exists (lambda (line) (not (generated-status-line? line)))
            (filter (lambda (l) (> (string-length l) 0))
                    (split-lines (git (list "-C" dir "status" "--porcelain"))))))

  ;; porcelain 行形如 "?? _build/ta6le/x.so" / " M src/a.ss":前 2 列是状态码,
  ;; 第 3 列起是路径(rename 形 "old -> new",取前一个即可判归属)。
  (define (generated-status-line? line)
    (and (> (string-length line) 3)
         (let ([p (substring line 3 (string-length line))])
           (path-has-segment? (car (string-split p #\space)) '("_build")))))

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
