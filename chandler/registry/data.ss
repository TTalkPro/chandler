#!chezscheme
;;; chandler/registry/data.ss --- 中心注册表数据类型(re-export)
;;;
;;; 这是 (chandler registry) 门面下的数据层。直接 re-export (chandler registered)
;;; 的全部公开 API,让 registry facade 不直接 import registered,避免循环依赖
;;; (registered 不应依赖任何 registry 子库)。
;;;
;;; 详见 chandler/registered.ss 的设计说明。

(library (chandler registry data)
  (export make-registered
          make-version-entry
          registered?
          version-entry?
          registered-name
          registered-kind
          registered-versions
          registered-active
          registered-has-version?
          version-entry-version
          version-entry-installed-at
          version-entry-source
          version-entry-installer
          registered-add-version
          registered-remove-version
          registered-set-active
          registered->datum
          datum->registered)
  (import (chandler registered)))
