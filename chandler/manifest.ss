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
          dep-pin-kind dep-pin-val dep-srcdir
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
  ;; 它没有 URL、不需要 fetch,只需要「装的那份够不够新」(designs/12 §5)。
  (define-record-type manifest
    (fields format name version chez skiff chandler srcdir
            deps dev-deps native overrides scripts app
            resources runtime-subset))

  ;; app:这个包是**可分发的应用**时声明入口(designs/09 §CLI)。
  ;;   (app (entry (mdserver)) (main main))
  ;; `name` 是**包名**,未必等于入口库名 —— skiff-demo 的包名是 skiff-demo,入口库
  ;; 是 (mdserver)。声明了就不必每次 `chandler pack --entry …`,也不必靠推断。
  (define-record-type app
    (fields entry main))

  ;; dep:source-kind ∈ {git,path};pin-kind ∈ {tag,rev,branch,version,#f}
  (define-record-type dep
    (fields name source-kind source-loc pin-kind pin-val srcdir))

  (define-record-type native
    (fields name source-kind source-loc pin-kind pin-val build chez-api? produces))

  ;; ── 读文件 → 校验过的 manifest ──
  (define (read-manifest path)
    (validate-manifest (parse-manifest (read-datum-file path))))

  ;; ── 解析 datum → manifest record(结构性错误此处即抛)──
  (define (parse-manifest datum)
    (let ([body (expect-tag datum 'manifest 'parse-manifest)])
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
        (or (parse-resources (field-ref* body 'resources) (field-ref body 'name)) #f)
        (parse-runtime-subset (field-ref* body 'runtime-subset)))))

  ;; (resources "rel/path") 或 (resources ((lib) "path") ...) —— designs/11 §6
  ;; 字段缺省 → #f。simple 形按 package name 标准化为单条;multi-lib 形逐项校验。
  (define (parse-resources items pkg-name)
    (and (not (null? items))
         (let ([entries
                 (if (and (= 1 (length items)) (string? (car items)))
                     ;; simple 形:单字符串 → 标准化为 ((<pkg-sym>) . path)
                     ;; 包名为 #f 时(manifest 缺 (name …))让 string->symbol 自爆,
                     ;; validate-manifest 仍会在更早时报"name 缺失"。
                     (let ([path (car items)])
                       (check-resource-path path 'resources)
                       (list (cons (list (string->symbol pkg-name)) path)))
                     ;; multi-lib 形:((libref ...) "path") ...
                     (map (lambda (it)
                            (unless (and (pair? it) (= 2 (length it))
                                         (pair? (car it)) (string? (cadr it)))
                              (error 'parse-manifest
                                     "(resources …) entry must be ((libref …) \"path\")"
                                     it))
                            (let ([libref (car it)]
                                  [path   (cadr it)])
                              (unless (and (pair? libref) (for-all symbol? libref))
                                (error 'parse-manifest
                                       "(resources …) libref must be a non-empty symbol list"
                                       libref))
                              (check-resource-path path 'resources)
                              (cons libref path)))
                          items))])
           (check-unique-librefs entries)
           entries)))

  ;; 路径必须相对、不得含空段 / `.` / `..`
  (define (check-resource-path path who)
    (when (or (not (string? path)) (absolute-path? path))
      (error who "resource path must be a relative path" path))
    (when (string=? "" path)
      (error who "resource path must not be empty" path))
    (let loop ([segs (string-split path #\/)])
      (cond
        [(null? segs) (void)]
        [(member "" segs)
         (error who "resource path must not contain empty segments" path)]
        [(member "." segs)
         (error who "resource path must not contain `.` segments" path)]
        [(member ".." segs)
         (error who "resource path must not contain `..` segments" path)]
        [else (void)])))

  ;; multi-lib 形下,同 libref 只能声明一次(designs/11 §6 校验表)
  (define (check-unique-librefs entries)
    (let loop ([xs entries] [seen '()])
      (unless (null? xs)
        (let ([lr (caar xs)])
          (when (member lr seen)
            (error 'parse-manifest
                   "(resources …) declares the same libref more than once" lr))
          (loop (cdr xs) (cons lr seen))))))

  ;; (runtime-subset name1 name2 ...) —— designs/12 §6
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
        (make-dep name sk sl pk pv (extract-srcdir fs)))))

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
    (unless (and (integer? (manifest-format m)) (<= (manifest-format m) supported-format))
      (error 'validate-manifest
             (format "manifest format ~a is newer than the supported ~a; upgrade chandler"
                     (manifest-format m) supported-format)))
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
