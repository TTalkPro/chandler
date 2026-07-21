#!chezscheme
;;; chandler.ss --- umbrella facade:re-export 公共 API

(library (chandler)
  (export chandler-version)
  (import (chezscheme))

  ;; 后续阶段 re-export:activate / activate-natives / load-native / native-path
  ;; (来自 (chandler activate));现仅占位版本号,验证 umbrella 可解析。
  (define chandler-version "0.1.0-dev"))
