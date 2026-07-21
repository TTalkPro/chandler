#!chezscheme
;;; bootstrap.ss --- 自举:用解释执行的 Chandler 给自己走一遍正常安装(designs/08 §2)
;;;
;;; 由 install.sh 调:scheme --libdirs <repo> --script bootstrap.ss <repo> <libdir> <bindir>
;;; 复用 (chandler registry) 事务把 chandler.ss + chandler/ 装进用户级 libdir(installer=bootstrap),
;;; 装完的 Chandler 能用 `chandler uninstall --global --name=chandler` 卸掉自己,注册表自洽。

(import (chezscheme)
        (chandler registry))

(define argv (cdr (command-line)))
(define repo   (list-ref argv 0))
(define libdir (list-ref argv 1))
(define bindir (list-ref argv 2))

(define (now-iso)
  (let ([d (current-date)])
    (format "~a-~a-~aT~a:~a:~a" (date-year d) (p2 (date-month d)) (p2 (date-day d))
            (p2 (date-hour d)) (p2 (date-minute d)) (p2 (date-second d)))))
(define (p2 n) (if (< n 10) (format "0~a" n) (format "~a" n)))

;; 版本取自 umbrella(避免与 (chandler) 循环:直接读源里的字符串常量)
(define version "0.1.0")

(printf "bootstrap: 安装 chandler → ~a~%" libdir)
(install-global repo libdir
                (list "chandler" version `(path ,repo) (now-iso) 'bootstrap)
                '((force . #t)))

;; 装 bin/chandler wrapper 到 bindir,指向已装 libdir(CHANDLER_HOME)
(let ([wrapper (string-append bindir "/chandler")])
  (call-with-output-file wrapper
    (lambda (p)
      (fprintf p "#!/bin/sh~%")
      (fprintf p "# chandler 入口(bootstrap 生成)~%")
      (fprintf p "CHANDLER_HOME=~s~%" libdir)
      (fprintf p "export CHANDLER_HOME~%")
      (fprintf p "scheme=${CHANDLER_SCHEME:-scheme}~%")
      (fprintf p "exec \"$scheme\" -q --libdirs \"$CHANDLER_HOME\" --program \"$CHANDLER_HOME/chandler/cli/main.sps\" \"$@\"~%"))
    'truncate)
  (system (string-append "chmod +x " wrapper))
  (printf "bootstrap: 已装启动器 → ~a~%" wrapper))

(printf "bootstrap: 完成。确保 ~a 在 PATH 中,然后 `chandler --version` 验证。~%" bindir)
(exit 0)
