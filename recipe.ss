#!chezscheme
;;; recipe.ss --- bake 构建描述(占位)
;;;
;;; bake 在【另一仓库】实现;本文件由该 bake 消费,描述如何编译/安装 Chandler。
;;; 当前占位,阶段 10.3 补全。Chandler 自身无外部依赖,开发期以解释执行为主:
;;;   scheme --program tests/run-tests.sps        # 跑测试
;;;   bin/chandler --version                      # 入口
;;;
;;; 预期最终形态(示意,非最终 API):
;;;   (default-task 'build)
;;;   (task 'build '(compile-libs))               ; 编译 chandler.ss + chandler/**
;;;   (task 'test  '(build) (lambda () (run "scheme" "--program" "tests/run-tests.sps")))
;;;   (task 'install '(build) ...)                ; 复用 (chandler registry) 事务
