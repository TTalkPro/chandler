#!chezscheme
;;; tests/chandler/fetch.ss --- (chandler fetch) 测试:对本地临时 git 仓,不依赖外网

(library (tests chandler fetch)
  (export suite)
  (import (chezscheme)
          (tests chandler harness)
          (tests chandler fixtures)
          (chandler fetch))

  ;; 造一个本地 git 源仓:2 提交 + tag v1.0.0;返回 (path rev1 rev2)。git 原语来自 fixtures
  (define (make-source-repo)
    (let ([dir (mktmp)])
      (git-init! dir)
      (write-file (string-append dir "/a.txt") "one")
      (git-commit! dir "c1")
      (let ([rev1 (trim (git-in dir "rev-parse" "HEAD"))])
        (git-in dir "tag" "v1.0.0")
        (write-file (string-append dir "/a.txt") "two")
        (git-commit! dir "c2")
        (let ([rev2 (trim (git-in dir "rev-parse" "HEAD"))])
          (list dir rev1 rev2)))))

  (define (with-cache thunk)
    (parameterize ([cache-root (mktmp)])
      (thunk)))

  (define-suite suite
    (normalize
      (assert-string= "https://github.com/x/http"
                      (normalize-url "https://github.com/x/http.git"))
      (assert-string= "https://github.com/x/http"
                      (normalize-url "https://github.com/x/http/"))
      ;; host 大小写归一,path 保留
      (assert-string= "https://github.com/X/Http"
                      (normalize-url "https://GitHub.COM/X/Http.git")))

    (url-key-stable
      ;; 不同写法归并同 key
      (assert-string= (url-key "https://github.com/x/http.git")
                      (url-key "https://github.com/x/http/"))
      ;; 不同库不同 key
      (assert-false (string=? (url-key "https://x/a") (url-key "https://x/b"))))

    (clone-and-resolve
      (with-cache
        (lambda ()
          (let* ([repo (make-source-repo)]
                 [url (car repo)] [rev1 (cadr repo)] [rev2 (caddr repo)])
            ;; tag 解析到 rev1(annotated? 轻量 tag → 指 commit)
            (assert-string= rev1 (resolve-tag url "v1.0.0"))
            ;; branch main 解析到 rev2
            (assert-string= rev2 (resolve-branch url "main"))
            ;; list-tags 含 v1.0.0
            (assert-true (member "v1.0.0" (list-tags url)))
            ;; has-rev?
            (assert-true (has-rev? url rev1))
            (assert-false (has-rev? url "0000000000000000000000000000000000000000"))
            ;; resolve-pin 各类
            (assert-string= rev1 (resolve-pin url 'tag "v1.0.0"))
            (assert-string= rev2 (resolve-pin url 'rev rev2))))))

    (materialize-checkout
      (with-cache
        (lambda ()
          (let* ([repo (make-source-repo)]
                 [url (car repo)] [rev1 (cadr repo)]
                 [dest (string-append (mktmp) "/http")])
            (materialize url rev1 dest)
            ;; checkout 到 rev1
            (assert-string= rev1 (head-rev dest))
            ;; a.txt 内容为 "one"(rev1)
            (assert-string= "one" (read-file (string-append dest "/a.txt")))
            ;; 干净工作区
            (assert-false (dirty? dest))
            ;; 改文件 → dirty
            (write-file (string-append dest "/a.txt") "dirty")
            (assert-true (dirty? dest))))))

    (offline-miss-errors
      (parameterize ([cache-root (mktmp)] [offline? #t])
        (assert-raises (lambda () (ensure-mirror "https://never/cached"))))))

  )   ; helpers(mktmp/write-file/read-file/trim/git-*)来自 (tests chandler fixtures)
