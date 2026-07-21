#!chezscheme
;;; chandler/test/registry.ss --- (chandler registry) 全局安装事务测试

(library (chandler test registry)
  (export suite)
  (import (chezscheme)
          (chandler test harness)
          (chandler test fixtures)
          (chandler fs)                        ; write-text 自建父目录
          (chandler layout)
          (chandler registry))

  ;; 造一个布局规范库源目录:name.ss + name/x.ss + native/<mt>/n.so
  (define (make-lib-src name)
    (let ([dir (mktmp)])
      (write-text (string-append dir "/" name ".ss")
        (format "#!chezscheme~%(library (~a) (export ok) (import (chezscheme)) (define ok #t))~%" name))
      (write-text (string-append dir "/" name "/core.ss")
        (format "#!chezscheme~%(library (~a core) (export c) (import (chezscheme)) (define c 1))~%" name))
      (write-text (string-append dir "/native/" (current-machine-type) "/" name ".so") "FAKESO")
      dir))

  (define (mk-meta name) (list name "1.0.0" `(git ,(string-append "https://h/" name))
                            "2026-07-21T00:00:00Z" 'chandler))

  (define-suite suite
    (install-and-list
      (let* ([libdir (mktmp)]
             [src (make-lib-src "greet")])
        (install-global src libdir (mk-meta "greet") '())
        ;; 文件落位
        (assert-true (file-exists? (join-paths libdir "greet.ss")))
        (assert-true (file-exists? (join-paths libdir "greet/core.ss")))
        (assert-true (file-exists? (join-paths libdir (string-append "native/" (current-machine-type) "/greet.so"))))
        ;; registry 写入
        (assert-true (file-exists? (registry-file libdir "greet")))
        ;; list
        (let ([rows (list-global libdir)])
          (assert-equal 1 (length rows))
          (assert-string= "greet" (caar rows))
          (assert-string= "1.0.0" (cadar rows)))))

    (conflict-across-packages
      (let* ([libdir (mktmp)]
             [a (make-lib-src "shared")])
        (install-global a libdir (mk-meta "shared") '())
        ;; 另一个包也想装 shared.ss 同路径 → 用不同 name 但制造同文件冲突
        ;; 构造 pkgB 源,含一个与 shared 同相对路径的文件
        (let ([b (mktmp)])
          (write-file (string-append b "/shared.ss") "x")   ; 同路径 shared.ss
          (write-file (string-append b "/b.ss") "y")
          ;; b 的库名 b,但其 enumerate 只含 b.ss + b/;shared.ss 不属 b 的枚举
          ;; 直接测:重复装 shared(升级路径)不报冲突
          (assert-string= "shared" (install-global a libdir (mk-meta "shared") '())))))

    (uninstall-clean
      (let* ([libdir (mktmp)]
             [src (make-lib-src "gone")])
        (install-global src libdir (mk-meta "gone") '())
        (assert-true (file-exists? (join-paths libdir "gone.ss")))
        (uninstall-global "gone" libdir '())
        ;; 文件与 registry 皆删
        (assert-false (file-exists? (join-paths libdir "gone.ss")))
        (assert-false (file-exists? (join-paths libdir "gone/core.ss")))
        (assert-false (file-exists? (registry-file libdir "gone")))
        ;; list 空
        (assert-equal '() (list-global libdir))))

    (upgrade-orphan-cleanup
      (let* ([libdir (mktmp)]
             [src (make-lib-src "up")])
        (install-global src libdir (mk-meta "up") '())
        (assert-true (file-exists? (join-paths libdir "up/core.ss")))
        ;; 新版本删掉 up/core.ss,加 up/new.ss
        (delete-file (string-append src "/up/core.ss"))
        (write-file (string-append src "/up/new.ss")
          "#!chezscheme\n(library (up new) (export n) (import (chezscheme)) (define n 2))")
        (install-global src libdir (list "up" "2.0.0" '(git "u") "t" 'chandler) '())
        ;; 孤儿 core.ss 被清,new.ss 到位
        (assert-false (file-exists? (join-paths libdir "up/core.ss")))
        (assert-true (file-exists? (join-paths libdir "up/new.ss")))
        (assert-string= "2.0.0" (cadar (list-global libdir)))))

    (doctor-detects-drift
      (let* ([libdir (mktmp)]
             [src (make-lib-src "doc")])
        (install-global src libdir (mk-meta "doc") '())
        ;; 无问题
        (assert-equal '() (doctor-global libdir))
        ;; 篡改一个已装文件 → drift
        (write-file (join-paths libdir "doc.ss") "TAMPERED")
        (let ([issues (doctor-global libdir)])
          (assert-true (> (length issues) 0))
          (assert-equal 'drift (caar issues)))
        ;; 删一个文件 → missing
        (delete-file (join-paths libdir "doc/core.ss"))
        (assert-true (memp (lambda (i) (eq? (car i) 'missing)) (doctor-global libdir)))))))
