#!chezscheme
;;; chandler/cli/runtime-env.ss --- 共享运行时环境装配(解释器选择 / native preamble / .env)
;;;
;;; cmd-run / cmd-repl / cmd-exec / cmd-test 共用一套运行时环境装配逻辑,集中在此
;;; 避免 4 处各自 fork 后漂移(解释器选择优先级、preamble 临时文件名、.env 加载顺序)。
;;; 这些函数原本散在 (chandler cli commands);v3 抽出来新增 `chandler test` 时复用。
;;;
;;; collect-dotenv 在 v3 增加 `.env.tests` 覆盖:.env 是项目默认值,.env.tests 在
;;; 跑测试时按需覆盖个别键(如把 LOG_LEVEL 调到 debug,或换测试数据库 DSN)。
;;; 它是**按调用方索取**的(三参形 tests? = #t,只有 cmd-test 传),不是「文件在就读」
;;; —— 否则 cmd-run / cmd-repl / cmd-exec 会跟着吃到测试配置。

(library (chandler cli runtime-env)
  (export choose-interp interp-kind make-preamble collect-dotenv)
  (import (chezscheme)
          (chandler util)
          (chandler layout)
          (chandler manifest)
          (chandler env)
          (chandler runtime-detector)
          (chandler cli args))

  ;; 选解释器(designs/06 §3)。**优先级**(run/exec/repl/test/启动器一致):
  ;;   --runtime 旗标 > CHANDLER_RUNTIME 环境变量 > manifest 声明 > 默认
  ;; 「哪一种」由上式定;「哪个可执行文件」由 CHANDLER_SKIFF / CHANDLER_SCHEME 定(名或路径)。
  (define (choose-interp root flags)
    (case (interp-kind root flags)
      [(skiff) (skiff-exe)]
      [else    (chez-exe)]))

  (define (skiff-exe) (or (getenv* "CHANDLER_SKIFF") "skiff"))
  (define (chez-exe)  (or (getenv* "CHANDLER_SCHEME") "scheme"))

  ;; 选运行时**种类**(designs/06 §3)。优先级(run/exec/repl/test/启动器一致):
  ;;   --runtime > CHANDLER_RUNTIME > manifest(明确 chez-only→chez / skiff-only→skiff)
  ;;   > 默认:跟随 chandler 当前所在运行时
  ;;
  ;; **默认 skiff 就落在最后一条**:chandler 的启动器已 skiff 优先、无 skiff 才回退
  ;; chez,故"当前所在"天然就是"能用 skiff 就 skiff、否则 chez"——不用再单独探测
  ;; 可用性,也就不会"默认成一个没装的 skiff 然后 127"。**显式**(--runtime /
  ;; CHANDLER_RUNTIME / skiff-only manifest)则照单执行,找不到即 127,不回退。
  (define (interp-kind root flags)
    (let ([rt (flag flags 'runtime)])
      (cond
        [(equal? rt "skiff") 'skiff]
        [(equal? rt "chez") 'chez]
        [(preferred-runtime)]                          ; CHANDLER_RUNTIME=skiff|chez
        [else
         (let ([mpath (join-paths root "chandler-manifest.ss")])
           (if (file-exists? mpath)
               (let ([mf (read-manifest mpath)])
                 (cond
                   [(and (manifest-chez mf) (not (manifest-skiff mf))) 'chez]   ; 明确 chez-only
                   [(and (manifest-skiff mf) (not (manifest-chez mf))) 'skiff]  ; 明确 skiff-only
                   [else (current-runtime)]))           ; 双跑 / 未声明 → 跟随当前(默认 skiff)
               (current-runtime)))])))                  ; 无 manifest → 跟随当前

  ;; 生成 preamble 临时脚本:先 load 各 native,再 load 目标脚本
  (define (make-preamble root natives script-abs)
    (let ([tmp (string-append root "/.chandler-run.ss")])
      (call-with-output-file tmp
        (lambda (p)
          (for-each (lambda (so)
                      (when (file-exists? so)
                        (fprintf p "(load-shared-object ~s)~%" so)))
                    natives)
          (fprintf p "(load ~s)~%" script-abs))
        'truncate)
      tmp))

  ;; ── .env 收集(C3 + v3 .env.tests 覆盖)──
  ;; 加载顺序(后者覆盖前者):<root>/.env → <root>/.env.tests(仅 tests? 为真时)
  ;; → --env-file <path>(显式指定,后到者同键覆盖)。依赖树里的 .env 一概不读
  ;; (见 (chandler env) 头注:信任模型)。返回有序 alist;同名键多次出现时,后面的
  ;; 覆盖前面的(覆盖语义由调用方在 env-prefix / export 时实现 —— 这里只把覆盖项追加
  ;; 到末尾,shell `env KEY=a KEY=b cmd` 里后者生效)。
  ;;
  ;; **`.env.tests` 必须显式索取**(tests? = #t,只有 cmd-test 传):它是「跑测试时
  ;; 的覆盖层」(测试库 DSN、LOG_LEVEL=debug…)。先前本函数无条件读它,于是项目一旦
  ;; 建了 .env.tests,`chandler run` / `repl` / `exec` 会静默用上测试配置 —— 对着测试
  ;; 数据库跑生产脚本这种事,不该由一个约定文件的存在与否悄悄决定。
  ;; --env-file 仍可再覆盖 .env.tests(显式优先于约定)。
  (define collect-dotenv
    (case-lambda
      [(root flags) (collect-dotenv root flags #f)]
      [(root flags tests?)
       (let* ([base (read-dotenv (dotenv-file-path root))]
              [tests-extra (if tests?
                               (read-dotenv (join-paths root ".env.tests"))
                               '())]
              [cli-extra  (let ([f (flag flags 'env-file)])
                            (if (string? f)
                                (read-dotenv (if (string-prefix? "/" f) f (join-paths root f)))
                                '()))])
         (append base tests-extra cli-extra))]))

  )
