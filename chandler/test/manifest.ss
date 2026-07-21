#!chezscheme
;;; chandler/test/manifest.ss --- (chandler manifest) 测试

(library (chandler test manifest)
  (export suite)
  (import (chezscheme)
          (chandler test harness)
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
      (assert-false (builtin-prefix? 'http)))))
