#!/bin/sh
# mock bake —— 记录每次调用到 $MOCK_BAKE_LOG,供 (chandler build) 排单测试断言。
# 不做真实编译;仅证明 chandler 以正确顺序/参数调用 bake。
printf '%s\n' "$*" >> "${MOCK_BAKE_LOG:-/dev/null}"
exit 0
