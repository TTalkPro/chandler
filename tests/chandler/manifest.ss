#!chezscheme
;;; tests/chandler/manifest.ss --- (chandler manifest) 测试

(library (tests chandler manifest)
  (export suite)
  (import (chezscheme)
          (tests chandler harness)
          (chandler manifest))

  (define (m datum) (validate-manifest (parse-manifest datum)))

  (define full
    '(manifest
       (format 1)
       (name "my-app") (version "0.1.0")
       (chez ">=10.0") (skiff ">=0.3")
       (srcdir "src")
       (deps
         (http (git "https://github.com/x/http") (tag "v1.2.0"))
         (json (git "https://github.com/x/json") (rev "a1b2c3d"))
         (mylib (path "../mylib")))
       (dev-deps
         (test (git "https://github.com/x/test") (tag "v0.5.0")))
       (native
         (sqlite (git "https://github.com/x/sqlite") (rev "deadbeef") (build make))
         (osi (path "native/osi") (build (cmake (targets "osi"))) (chez-api #t)))
       (overrides
         (thunderchez (srcdir ".") (deps ())))))

  (define-suite suite
    (parse-fields
      (let ([x (m full)])
        (assert-string= "my-app" (manifest-name x))
        (assert-string= "0.1.0" (manifest-version x))
        (assert-string= ">=10.0" (manifest-chez x))
        (assert-string= ">=0.3" (manifest-skiff x))
        (assert-string= "src" (manifest-srcdir x))
        (assert-equal 3 (length (manifest-deps x)))
        (assert-equal 1 (length (manifest-dev-deps x)))
        (assert-equal 2 (length (manifest-native x)))
        (assert-equal 1 (length (manifest-overrides x)))))

    (dep-git-tag
      (let ([d (car (manifest-deps (m full)))])
        (assert-equal 'http (dep-name d))
        (assert-equal 'git (dep-source-kind d))
        (assert-string= "https://github.com/x/http" (dep-source-loc d))
        (assert-equal 'tag (dep-pin-kind d))
        (assert-string= "v1.2.0" (dep-pin-val d))))

    (dep-path
      (let ([d (caddr (manifest-deps (m full)))])
        (assert-equal 'mylib (dep-name d))
        (assert-equal 'path (dep-source-kind d))
        (assert-equal #f (dep-pin-kind d))))

    (native-cmake
      (let ([n (cadr (manifest-native (m full)))])
        (assert-equal 'osi (native-name n))
        (assert-equal 'path (native-source-kind n))
        (assert-true (native-chez-api? n))
        (assert-equal '(cmake (targets "osi")) (native-build n))))

    (defaults
      (let ([x (m '(manifest (name "a") (version "0.1.0")))])
        (assert-string= "." (manifest-srcdir x))
        (assert-equal 1 (manifest-format x))
        (assert-equal '() (manifest-deps x))))

    ;; ── 校验拒绝 ──
    (reject-not-manifest
      (assert-raises (lambda () (m '(project (name "a"))))))

    (reject-missing-name
      (assert-raises (lambda () (m '(manifest (version "0.1.0"))))))

    (reject-future-format
      (assert-raises (lambda () (m '(manifest (format 99) (name "a") (version "0.1.0"))))))

    (reject-dup-dep
      (assert-raises
        (lambda () (m '(manifest (name "a") (version "0.1.0")
                        (deps (x (git "u")) (x (git "v"))))))))

    (reject-builtin-name
      (assert-raises
        (lambda () (m '(manifest (name "a") (version "0.1.0")
                        (deps (rnrs (git "u"))))))))

    (reject-two-pins
      (assert-raises
        (lambda () (m '(manifest (name "a") (version "0.1.0")
                        (deps (x (git "u") (tag "v1") (rev "abc"))))))))

    (reject-path-pin
      (assert-raises
        (lambda () (m '(manifest (name "a") (version "0.1.0")
                        (deps (x (path "../x") (tag "v1"))))))))

    (reject-abs-path
      (assert-raises
        (lambda () (m '(manifest (name "a") (version "0.1.0")
                        (deps (x (path "/abs/x"))))))))

    (reject-no-source
      (assert-raises
        (lambda () (m '(manifest (name "a") (version "0.1.0")
                        (deps (x (tag "v1"))))))))

    (builtin-prefix-pred
      (assert-true (builtin-prefix? 'chezscheme))
      (assert-true (builtin-prefix? 'skiff))
      (assert-false (builtin-prefix? 'http)))

    ;; ── v3 (resources ...) 字段:静默忽略(D13)──
    ;; v3 取消 manifest 的 (resources ...) 声明;资源靠约定 <src>/<libpath>/resources/。
    ;; 契约是**旧 manifest 含此字段仍解析成功**(不报错、不影响其余字段);
    ;; 访问器 manifest-resources 已删 —— 它恒返回 #f,而 resolve 还把这个 #f
    ;; 一路传进 lock,是条不产出任何东西的死管道。

    (resources-silently-ignored-simple
      ;; 旧 simple 形("data" 字符串)→ 解析成功,其余字段照常
      (let ([x (m '(manifest (name "mylib") (version "0.1.0")
                      (resources "data")))])
        (assert-string= "mylib" (manifest-name x))
        (assert-string= "0.1.0" (manifest-version x))))

    (resources-silently-ignored-multi-lib
      ;; 旧 multi-lib 形 → 同样静默忽略
      (let ([x (m '(manifest (name "suite") (version "0.1.0")
                      (deps (http (git "https://x/http")))
                      (resources ((mylib) "resources")
                                 ((mylib parser) "resources/parser"))))])
        (assert-string= "suite" (manifest-name x))
        (assert-equal 1 (length (manifest-deps x)))))

    (resources-v3-no-validation
      ;; v3 不再校验路径:abs path / .. / // / dup 全部静默接受
      ;; (因为这些字段的"非法性"已无意义,不再被消费)
      (assert-true
        (manifest? (m '(manifest (name "a") (version "0.1.0")
                         (resources "/abs/x")))))
      (assert-true
        (manifest? (m '(manifest (name "a") (version "0.1.0")
                         (resources "a/../b")))))
      (assert-true
        (manifest? (m '(manifest (name "a") (version "0.1.0")
                         (resources "a//b")))))
      (assert-true
        (manifest? (m '(manifest (name "a") (version "0.1.0")
                         (resources ((mylib) "p1") ((mylib) "p2")))))))

    ;; ── (runtime-subset ...) 字段:已删,旧 manifest 仍须解析成功 ──
    ;; 消费侧读的一直是 (chandler install) 里硬编码的 chandler-runtime-sublibs,
    ;; manifest 那个字段零引用。这里只钉「写了也不报错」。
    (runtime-subset-silently-ignored
      (let ([x (m '(manifest (name "chandler") (version "0.2.0")
                      (runtime-subset hash util fs)))])
        (assert-string= "chandler" (manifest-name x))
        (assert-string= "0.2.0" (manifest-version x))))

    ;; 该字段不再被解析,故其内容也不再被校验 —— 非 symbol 项不再报错
    (runtime-subset-no-longer-validated
      (assert-true
        (manifest? (m '(manifest (name "a") (version "0.1.0")
                         (runtime-subset hash "util"))))))))
