#!chezscheme
;;; chandler/manifest.ss --- 解析 + 校验 manifest.ss(designs/02)
;;;
;;; manifest.ss 是纯数据(sexp read,不求值)。本库把它 record 化并按 designs/02 §4
;;; 校验规则表逐条校验。name=目录名 的校验属上下文,交 CLI(见 designs/05 §3)。

(library (chandler manifest)
  (export read-manifest parse-manifest validate-manifest
          manifest? manifest-format manifest-name manifest-version
          manifest-chez manifest-skiff manifest-chandler manifest-srcdir
          manifest-deps manifest-dev-deps manifest-native
          manifest-overrides manifest-scripts
          manifest-resources manifest-runtime-subset
          manifest-app app? app-entry app-main
          dep? dep-name dep-source-kind dep-source-loc
          dep-pin-kind dep-pin-val
          native? native-name native-source-kind native-source-loc
          native-pin-kind native-pin-val native-build native-chez-api? native-produces
          supported-format builtin-prefix?)
  (import (chezscheme)
          (chandler sexp)
          (chandler util)
          (chandler version))

  (define supported-format 1)

  ;; ── records ──
  ;; chez / skiff / chandler 三个字段是**运行时门**,不是依赖:声明的是版本区间,
  ;; 实体由环境提供(chez/skiff 是解释器本身;chandler 是全局库前缀
  ;; ~/.local/share/chez 里装好的那一份)。故 chandler **不写进 (deps …)** ——
  ;; 它没有 URL、不需要 fetch,只需要「装的那份够不够新」(designs/06 §5)。
  ;;
  ;; v3(D13)取消 (resources ...) 字段:资源靠约定 `<src>/<libpath>/resources/`
  ;; 与库源码同居。manifest-resources 保留为 export 但恒返回 #f(向后兼容)。
  (define-record-type manifest
    (fields format name version chez skiff chandler srcdir
            deps dev-deps native overrides scripts app
            runtime-subset))

  ;; manifest-resources:向后兼容,恒返回 #f
  ;; (旧代码可能调用它,如 resolve;现在资源靠约定,不需要 manifest 声明)
  (define (manifest-resources m) #f)

  ;; app:这个包是**可分发的应用**时声明入口(designs/09 §CLI)。
  ;;   (app (entry (mdserver)) (main main))
  ;; `name` 是**包名**,未必等于入口库名 —— skiff-demo 的包名是 skiff-demo,入口库
  ;; 是 (mdserver)。声明了就不必每次 `chandler pack --entry …`,也不必靠推断。
  (define-record-type app
    (fields entry main))

  ;; dep:source-kind ∈ {git,path};pin-kind ∈ {tag,rev,branch,version,#f}
  (define-record-type dep
    (fields name source-kind source-loc pin-kind pin-val))

  (define-record-type native
    (fields name source-kind source-loc pin-kind pin-val build chez-api? produces))

  ;; ── 读文件 → 校验过的 manifest ──
  (define (read-manifest path)
    (validate-manifest (parse-manifest (read-datum-file path))))

  ;; ── 解析 datum → manifest record(结构性错误此处即抛)──
  (define (parse-manifest datum)
    (let ([body (expect-tag datum 'manifest 'parse-manifest)])
      ;; v3:静默忽略 (resources ...) 字段 —— 资源靠约定,不靠声明(D13)。
      ;; 旧 manifest 含此字段不报错,但解析器不再消费它。
      (make-manifest
        (or (field-ref body 'format) 1)
        (field-ref body 'name)
        (field-ref body 'version)
        (field-ref body 'chez)
        (field-ref body 'skiff)
        (field-ref body 'chandler)
        (or (field-ref body 'srcdir) ".")
        (parse-deps (field-ref* body 'deps))
        (parse-deps (field-ref* body 'dev-deps))
        (map parse-native (field-ref* body 'native))
        (parse-overrides (field-ref* body 'overrides))
        (field-ref* body 'scripts)
        (parse-app (field-ref* body 'app))
        (parse-runtime-subset (field-ref* body 'runtime-subset)))))

  ;; v3(D13):资源 method B —— 删 manifest (resources ...) 字段。
  ;; 旧 parse-resources / check-resource-path / check-unique-librefs 全部作废。
  ;; 资源约定:<src>/<libpath>/resources/<file>(见 layout.ss:lib-resource-dir)。

  ;; (runtime-subset name1 name2 ...) —— designs/06 §6.3(chandler 自身用)
  ;; 字段缺省 → #f。每一项必须是 symbol。
  (define (parse-runtime-subset items)
    (and (not (null? items))
         (begin
           (for-each
             (lambda (it)
               (unless (symbol? it)
                 (error 'parse-manifest
                        "(runtime-subset …) entries must be symbols" it)))
             items)
           items)))

  ;; (app (entry (a b)) (main main)) → app record;缺省 main = `main`
  (define (parse-app body)
    (and (pair? body)
         (let ([entry (let ([c (assq 'entry body)]) (and c (cadr c)))]
               [main  (let ([c (assq 'main body)]) (and c (cadr c)))])
           (unless (and (pair? entry) (for-all symbol? entry))
             (error 'parse-manifest
                    "(app …) needs (entry (<lib> …)) naming the entry library" entry))
           (make-app entry (or main 'main)))))

  ;; deps body = ((name source pin? opt*) ...)
  (define (parse-deps items)
    (map parse-dep items))

  (define (parse-dep item)
    (unless (and (pair? item) (symbol? (car item)))
      (error 'parse-dep "dependency entry must have the form (name ...)" item))
    (let ([name (car item)]
          [fs   (cdr item)])
      (let-values ([(sk sl) (extract-source fs name)]
                   [(pk pv) (extract-pin fs name)])
        (make-dep name sk sl pk pv))))

  (define (extract-source forms who)
    (let ([git       (find-tagged forms 'git)]
          [path      (find-tagged forms 'path)]
          [prebuilt  (find-tagged forms 'prebuilt)])
      (cond
        [(and git path) (error 'parse-dep "git and path sources are mutually exclusive" who)]
        [(and git prebuilt) (error 'parse-dep "git and prebuilt sources are mutually exclusive" who)]
        [(and path prebuilt) (error 'parse-dep "path and prebuilt sources are mutually exclusive" who)]
        [git       (values 'git (cadr git))]
        [path      (values 'path (cadr path))]
        [prebuilt  (values 'prebuilt (cdr prebuilt))]  ; 整个 (mt ...) 列表
        [else (error 'parse-dep "dependency has no (git ...) / (path ...) / (prebuilt ...) source" who)])))

  (define (extract-pin forms who)
    (let ([pins (filter (lambda (f) (memq (and (pair? f) (car f))
                                          '(tag rev branch version)))
                        forms)])
      (cond
        [(null? pins) (values #f #f)]
        [(> (length pins) 1)
         (error 'parse-dep "pin must be exactly one of tag/rev/branch/version" who pins)]
        [else (values (caar pins) (cadar pins))])))

  (define (extract-srcdir forms)
    (let ([s (find-tagged forms 'srcdir)])
      (if s (cadr s) #f)))

  (define (parse-native item)
    (let ([name (car item)]
          [fs   (cdr item)])
      (let-values ([(sk sl) (extract-source fs name)]
                   [(pk pv) (extract-pin fs name)])
        (make-native name sk sl pk pv
                     (let ([b (find-tagged fs 'build)]) (if b (cadr b) 'make))
                     (let ([c (find-tagged fs 'chez-api)]) (and c (cadr c) #t))
                     (let ([p (find-tagged fs 'produces)]) (if p (cdr p) '()))))))

  ;; overrides body = ((name field ...) ...) —— 原样保留为 alist(resolve 消费)
  (define (parse-overrides items)
    (map (lambda (o) (cons (car o) (cdr o))) items))

  (define (find-tagged forms tag)
    (cond
      [(null? forms) #f]
      [(tagged-list? (car forms) tag) (car forms)]
      [else (find-tagged (cdr forms) tag)]))

  ;; ── 校验(designs/02 §4)──
  (define (validate-manifest m)
    ;; format 门
    (let ([fmt (manifest-format m)])
      (unless (integer? fmt)
        (error 'validate-manifest "manifest has invalid (format N)" fmt))
      (check-format! 'validate-manifest fmt supported-format))
    ;; 必选字段
    (unless (string? (manifest-name m))
      (error 'validate-manifest "manifest has no (name \"...\")"))
    (unless (string? (manifest-version m))
      (error 'validate-manifest "manifest has no (version \"...\")"))
    ;; 版本区间可解析
    (for-each (lambda (pair)
                (when (cdr pair)
                  (guard (e [#t (error 'validate-manifest
                                       (format "~a version range is not parseable" (car pair)) (cdr pair))])
                    (version-match? (cdr pair) "0.0.0"))))
              (list (cons 'chez (manifest-chez m)) (cons 'skiff (manifest-skiff m))
                    (cons 'chandler (manifest-chandler m))))
    ;; chandler 是运行时门,不是依赖 —— 两处都写会让人以为它会被 fetch
    (when (and (manifest-chandler m)
               (exists (lambda (d) (eq? 'chandler (dep-name d)))
                       (append (manifest-deps m) (manifest-dev-deps m))))
      (error 'validate-manifest
             "chandler is declared both as (chandler \"<range>\") and as a dependency; it is a runtime gate, not a dependency -- drop the deps entry"))
    ;; dep 校验:名唯一、不撞内建、path 相对存在性延后(resolve/install 时)
    (let ([all (append (manifest-deps m) (manifest-dev-deps m))])
      (check-unique-names all)
      (for-each check-dep all))
    (for-each check-dep-native (manifest-native m))
    m)

  (define (check-unique-names deps)
    (let loop ([ds deps] [seen '()])
      (unless (null? ds)
        (let ([n (dep-name (car ds))])
          (when (memq n seen)
            (error 'validate-manifest "duplicate dependency name" n))
          (loop (cdr ds) (cons n seen))))))

  (define (check-dep d)
    (when (builtin-prefix? (dep-name d))
      (error 'validate-manifest "dependency name conflicts with a builtin library prefix" (dep-name d)))
    (when (and (eq? 'path (dep-source-kind d)) (absolute-path? (dep-source-loc d)))
      (error 'validate-manifest "path dependency must use a relative path" (dep-source-loc d)))
    (when (and (eq? 'path (dep-source-kind d)) (dep-pin-kind d))
      (error 'validate-manifest "path dependency cannot have a pin" (dep-name d))))

  (define (check-dep-native n)
    (when (and (eq? 'path (native-source-kind n)) (absolute-path? (native-source-loc n)))
      (error 'validate-manifest "path native must use a relative path" (native-source-loc n))))

  ;; 内建库前缀:chezscheme / rnrs / skiff(designs/06 §3)
  (define (builtin-prefix? name)
    (memq name '(chezscheme rnrs scheme skiff)))

  (define (absolute-path? p)
    (and (string? p) (> (string-length p) 0)
         (or (char=? #\/ (string-ref p 0))
             (and (> (string-length p) 1) (char=? #\: (string-ref p 1)))))))  ; C:
