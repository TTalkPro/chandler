#!chezscheme
;;; chandler/pack.ss --- facade: re-export pack / verify-pack / run-sps-content
;;;
;;; 实现拆入 chandler/pack/ 子目录(详见 designs/05):
;;;   paths / runtime / snapshot / natives / launchers / run-sps / manifest-writer / core / verify

(library (chandler pack)
  (export pack verify-pack run-sps-content)
  (import (chandler pack core)
          (chandler pack verify)
          (chandler pack run-sps)))
