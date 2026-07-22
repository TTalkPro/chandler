;;; manifest.ss --- Chandler 自身的 Chandler 清单
;;; 自举目标:Chandler 核心零外部依赖(只用 (chezscheme))。故 deps 为空。

(manifest
  (format 1)
  (name    "chandler")
  (version "0.1.4")
  (chez    ">=10.0")            ; 标准 Chez 即可,不要求 Skiff
  (srcdir  "."))               ; 搜索根 = 仓库根(库布局规范默认)
