#!chezscheme
;;; chandler.ss --- umbrella facade:re-export 公共 API
;;;
;;; 应用一行激活:(import (chandler)) (activate) 之后即可 import lib/ 下各依赖(脚本顶层)。

(library (chandler)
  (export chandler-version
          activate activate-natives load-native native-path native-root
          current-runtime runtime-version verify-runtime!)
  (import (chezscheme)
          (chandler activate)
          (chandler runtime))

  (define chandler-version "0.1.0-dev"))
