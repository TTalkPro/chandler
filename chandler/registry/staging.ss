#!chezscheme
;;; chandler/registry/staging.ss --- install 事务暂存目录
;;;
;;; staging 是 install/uninstall 的"半成品区",不在 version root 里:
;;; v3 把它从 v2 的 <vroot>/.chandler/staging/ 挪到 <libdir>/.registry/staging/,
;;; 让 <vroot> 真正自包含(I1:rm -rf <name>/<version>/ 不留残痕)。
;;;
;;; 路径:<libdir>/.registry/staging/<name>-<version>/
;;;
;;; 典型用法:
;;;   (with-staging! libdir name version
;;;     (lambda (staging-path)
;;;       ;; 把文件拷到 staging-path
;;;       ...
;;;       ;; 成功返回 → promote:逐文件 move 到目标,清 staging
;;;       ;; 失败(抛异常)→ abort:逐文件反向删除 staging,清 staging
;;;       success-value))

(library (chandler registry staging)
  (export staging-dir
          staging-path
          with-staging!
          clear-staging!
          clear-stale-staging
          stale-staging-list)
  (import (chezscheme)
          (chandler fs)
          (chandler layout))

  ;; <libdir>/.registry/staging
  (define (staging-dir libdir)
    (join-paths libdir ".registry" "staging"))

  ;; <libdir>/.registry/staging/<name>-<version>
  ;; name: symbol | string;version: string
  (define (staging-path libdir name version)
    (let ([name-str (if (symbol? name) (symbol->string name) name)])
      (join-paths (staging-dir libdir) (string-append name-str "-" version))))

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
        (lambda () (rm-rf p)))))

  ;; clear-staging! : libdir name version → void
  ;; 显式删某个 staging 目录(幂等)。
  (define (clear-staging! libdir name version)
    (rm-rf (staging-path libdir name version)))

  ;; stale-staging-list : libdir → list of staging path strings
  ;; 列出所有残留 staging 目录(doctor 用)。
  (define (stale-staging-list libdir)
    (let ([d (staging-dir libdir)])
      (if (file-directory? d)
          (map (lambda (e) (join-paths d e)) (dir-entries d))
          '())))

  ;; clear-stale-staging : libdir → void
  ;; 清掉所有残留 staging(force install 时用)。
  (define (clear-stale-staging libdir)
    (for-each rm-rf (stale-staging-list libdir)))
  )
