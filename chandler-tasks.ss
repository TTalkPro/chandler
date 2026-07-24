#!chezscheme
;;; chandler-tasks.ss --- chandler 自己的构建/任务描述(自举)
;;;
;;; 本文件是**程序**(task/file/rule/default-task,加载即求值),与数据文件
;;; manifest.ss 配对;由 `chandler bake`(吸收自 bake 的任务运行器)消费。
;;; 2026-07-24:原名 `recipe.ss`(bake 术语)—— bake 全吸收进 chandler 后改此名。
;;;
;;;   chandler bake            # = build,编译 (chandler) 库树为 .so → _build/<mt>/
;;;   chandler bake test       # 跑全测试套件
;;;   chandler bake test-ps    # PowerShell 启动器验收(需 pwsh,缺则跳过)
;;;   chandler bake -T         # 列任务
;;;
;;; **为什么 chandler 自己还留着这个文件**:多数项目不需要它(`chandler build`
;;; 从 manifest 推导构建);chandler 留着,只为多出 `test` / `test-ps` 两个自定义
;;; 任务 —— build 段本身其实也能从 manifest 推出来。
;;;
;;; **安装不在这里**:chandler 的安装由自含的 `bootstrap.ss` 负责(拷源码 →
;;; <prefix>/src/、拷 _build/<mt>/ → <prefix>/<mt>/,并写运行时发现启动器)。
;;; 故顺序是先 `chandler bake` 编译,再 `scheme --script bootstrap.ss [--force]`
;;; —— 否则装进前缀的是上一轮的旧对象。

(define-lib-roots ".")                       ; 库搜索根 = 仓库根(布局规范:umbrella 在根)

;; ── build(默认):编译 (chandler) umbrella + 其 import 闭包为 .so ──
(library-task 'build '(chandler))

;; ── test:跑测试套件(解释执行,无需先编译)──
(task 'test "跑全测试套件"
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
