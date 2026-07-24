#!chezscheme
;;; chandler/base.ss --- runtime 公共基础设施 umbrella(designs/12 §4.3)
;;;
;;; 所有 chandler 管理的 lib/app 通过 (import (chandler base)) 一行拿到全部 runtime
;;; 公共能力:资源定位、hash、版本匹配、路径操作、运行时探测等。dev-time 工具
;;; (chandler.ss) 也 import base,统一公共能力来源。export 列表 = 各子库 export 的并集。

(library (chandler base)
  (export
    ;; runtime-paths(designs/11)
    app-root app-name resource-path find-resource-path
    ;; hash
    sha256-bytevector sha256-string sha256-file
    ;; version
    parse-version version-compare version<? version=? version-match? select-highest strip-v
    ;; util
    string-split split-lines string-trim
    string-prefix? string-suffix? string-search string-contains?
    char-index strip-prefix strip-suffix string-join
    alist-ref getenv* ignore-errors plural chandler-version
    format-object eprintf datum->string string-subst strip-leading
    ;; fs
    parent-dir base-name path-join*
    ensure-dir ensure-parent
    dir-entries files-under dir-empty?
    rm-rf copy-file move-file
    read-file-string read-lines write-text
    sweep-empty-parents home-dir
    write-text-if-changed file-byte-size mtime
    path-swap-ext
    ;; sexp
    read-datum-file read-datum-string write-canonical-file canonical-string
    tagged-list? expect-tag
    field field-ref field-ref*
    alist->sorted
    ;; layout
    current-machine-type machine-type-string so-ext
    windows-mt?
    join-paths path-join
    path-sep split-pair entry->arg libdirs->arg
    resources-dirname prefix-resource-dir src-resource-dir
    native-so? lib-native-dir lib-native-path native-so-name
    library-name->path srcdir-join
    lib-root rel-to
    ;; runtime-detector(designs/06 §3-4)
    current-runtime runtime-version chez-version-string verify-runtime!
    runtime-env-var preferred-runtime parse-runtime-kind
    ;; proc
    run-capture run-check run-status run-foreground shell-quote
    proc-result-code proc-result-out proc-result-err)
  (import (chezscheme)
          (chandler runtime-paths)
          (chandler hash)
          (chandler version)
          (chandler util)
          (chandler fs)
          (chandler sexp)
          (chandler layout)
          (chandler runtime-detector)
          (chandler proc)))
