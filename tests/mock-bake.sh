#!/bin/sh
# mock bake —— 记录每次调用到 $MOCK_BAKE_LOG,供 (chandler build) 排单测试断言。
# 不做真实编译;仅证明 chandler 以正确参数/内容调用 bake。
printf '%s\n' "$*" >> "${MOCK_BAKE_LOG:-/dev/null}"
# 若经 -f 传入了生成的 recipe(chandler build 的排单描述),把其内容也记进日志,
# 便于断言 library-task / native-task 等真实 bake 任务已正确生成。
prev=
for a in "$@"; do
  if [ "$prev" = "-f" ] && [ -f "$a" ]; then
    cat "$a" >> "${MOCK_BAKE_LOG:-/dev/null}"
  fi
  prev=$a
done
exit 0
