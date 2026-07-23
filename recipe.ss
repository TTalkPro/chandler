#!chezscheme
;;; recipe.ss --- bake 构建/安装描述(生态闭环:skiff 跑 · chandler 管依赖 · bake 装库)
;;;
;;; 有了本文件,chandler 可直接被 bake 构建与安装,补上整个体系的最后一环:
;;;   • skiff  —— 运行时,跑上面所有工具
;;;   • chandler —— 包管理器,拉取/激活依赖
;;;   • bake   —— 构建工具,编译库树、装进 Chez lib dir(本 recipe 消费方)
;;; 且 bake 自身依赖 (chandler lock/registry/layout/sexp/util/fs),故「bake 装 chandler 库」
;;; 正是闭环所在。
;;;
;;;   bake            # = bake build,编译 (chandler) 库树为 .so
;;;   bake test       # 跑全测试套件
;;;   bake test-ps    # PowerShell 启动器验收(需 pwsh,缺则跳过)
;;;   bake -T         # 列任务
;;;
;;; **安装不在这里**(2026-07-23):bake 0.1.5 已删除 install-task / uninstall-task
;;; (bake designs/26:install 归 chandler),recipe 里再留着会导致**整份 recipe 加载
;;; 失败**(`variable build is not bound`),连 `bake build` 都跑不了。chandler 的安装
;;; 由自含的 `bootstrap.ss` 负责:它拷源码 → <prefix>/src/、拷 _build/<mt>/ →
;;; <prefix>/<mt>/,并写运行时发现启动器。故顺序是 `bake` 先编译,再
;;; `scheme --script bootstrap.ss [--force]`——否则装进前缀的是上一轮的旧对象。

(define-lib-roots ".")                       ; 库搜索根 = 仓库根(布局规范:umbrella 在根)

;; ── build(默认):编译 (chandler) umbrella + 其 import 闭包为 .so ──
(library-task 'build '(chandler))

;; ── test:跑测试套件(解释执行,无需先编译)──
(task 'test "跑全测试套件(220 用例)"
  '()
  (lambda ()
    (run "scheme" "--libdirs" "." "--program" "tests/run-tests.sps")))

;; ── test-ps:Windows(PowerShell)启动器验收 —— 渲染 .ps1 后用 pwsh 实跑 ──
;;   正斜杠 + [System.IO.Path]::PathSeparator 使同一份脚本跨 OS 可跑,故非 Windows
;;   亦能端到端验证;无 pwsh 则干净跳过(`mise use powershell` 可装)。
(task 'test-ps "跑 PowerShell 启动器验收(需 pwsh,缺则跳过)"
  '()
  (lambda ()
    (run "bash" "tests/powershell-run.sh")))

(default-task 'build)
