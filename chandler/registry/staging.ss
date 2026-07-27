#!chezscheme
;;; chandler/registry/staging.ss --- install 事务暂存目录
;;;
;;; staging 是 install/uninstall 的"半成品区",不在 version root 里:
;;; v3 把它从 v2 的 <vroot>/.chandler/staging/ 挪到 <libdir>/.registry/staging/,
;;; 让 <vroot> 真正自包含(I1:rm -rf <name>/<version>/ 不留残痕)。
;;;
;;; 路径:<libdir>/.registry/staging/<name>/<version>/(两段式;
;;; 旧版 "<name>-<version>" 单段拼接在 name/version 含 "-" 时会撞路径)。
;;;
;;; 典型用法:
;;;   (with-staging! libdir name version
;;;     (lambda ()
;;;       ;; 把文件拷到 (staging-path libdir name version)
;;;       ...
;;;       ;; 成功 → promote-staging! 整目录单次 rename 到 vroot
;;;       ;; 失败(抛异常)→ dynamic-wind 清 staging,重抛
;;;       success-value))

(library (chandler registry staging)
  (export staging-dir
          staging-path
          with-staging!
          promote-staging!
          stale-staging-list)
  (import (chezscheme)
          (chandler fs)
          (chandler layout))

  ;; <libdir>/.registry/staging
  (define (staging-dir libdir)
    (join-paths libdir ".registry" "staging"))

  ;; <libdir>/.registry/staging/<name>/<version>
  ;; name: symbol | string;version: string
  (define (staging-path libdir name version)
    (let ([name-str (if (symbol? name) (symbol->string name) name)])
      (join-paths (staging-dir libdir) name-str version)))

  ;; with-staging! : libdir name version thunk → thunk 结果
  ;;   成功(thunk 正常返回)→ 清 staging,返回 thunk 的值
  ;;   失败(thunk 抛异常)→ 清 staging,重抛异常
  ;; 不做 promote(facade 决定 staging → 最终位置的策略)。
  (define (with-staging! libdir name version thunk)
    (let ([p (staging-path libdir name version)])
      (rm-rf p)
      (dynamic-wind
        (lambda () (void))
        thunk
        (lambda ()
          (rm-rf p)
          ;; version 层清掉后 name 层若空,顺手收掉,不留空壳
          (guard (e (#t (void))) (delete-directory (parent-dir p)))))))

  ;; promote-staging! : libdir name version vroot → void
  ;; staging 整目录**单次 rename** 到 vroot(POSIX rename 原子:
  ;; vroot 要么旧版本要么完整新版本,绝不半截)。
  ;; vroot 已存在(覆盖装):先 rename vroot → <vroot>.old.<pid>(backup),
  ;; 再 rename staging → vroot,最后 rm-rf backup。
  ;; 任一步失败:回滚(backup 还在且 vroot 缺失 → rename 回去)
  ;;            + 清 staging 残留 + 重抛原始错。
  (define (promote-staging! libdir name version vroot)
    (let ([sp (staging-path libdir name version)]
          [backup (string-append vroot ".old." (number->string (get-process-id)))])
      (guard (e [else
                 (when (and (file-exists? backup) (not (file-exists? vroot)))
                   (guard (e2 (#t (void)))
                     (rename-file backup vroot)))
                 (rm-rf sp)
                 (raise e)])
        (ensure-parent vroot)          ; rename 不建父目录,先补上
        (when (file-exists? vroot)
          (rename-file vroot backup))
        (rename-file sp vroot)
        (when (file-exists? backup)
          (rm-rf backup)))))

  ;; stale-staging-list : libdir → list of staging path strings
  ;; 列出所有残留 staging 目录(doctor 用)。两段式:扫 <name>/<version> 两层。
  (define (stale-staging-list libdir)
    (let ([d (staging-dir libdir)])
      (if (file-directory? d)
          (fold-left
            (lambda (acc name-entry)
              (let ([nd (join-paths d name-entry)])
                (if (file-directory? nd)
                    (append acc (map (lambda (v) (join-paths nd v)) (dir-entries nd)))
                    acc)))
            '() (dir-entries d))
          '())))
  )
