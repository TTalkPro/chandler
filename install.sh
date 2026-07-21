#!/bin/sh
# install.sh — bootstrap installer for chandler(对齐 bake/install.sh)。
# 找一个能运行 R6RS 程序的 Scheme 运行时(skiff 优先,其次 Chez scheme),跑
# `chandler install-self`,把额外参数透传过去(如 --global / --force)。
#
# 自安装**基于 bake install**:库树由 `bake install`(读本仓 recipe.ss)装进 Chez lib dir,
# 本脚本再补一个运行时发现启动器。故需先装好 bake(生态里的构建工具)。
#
#   ./install.sh                 # 源码安装到 ~/.local(库经 bake)
#   ./install.sh --global        # /usr/local(需 root)
#
# 安全:推荐先 git clone + 审阅本仓再执行(而非 curl|sh 盲跑)。
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export CHANDLER_SRC="$here"

# 前置:bake 必须可用(自安装委托 bake install 装库)
if ! command -v "${CHANDLER_BAKE:-bake}" >/dev/null 2>&1; then
  echo "install.sh: 未找到 bake(自安装基于 bake install)。" 1>&2
  echo "  请先安装 bake(生态构建工具),或设 CHANDLER_BAKE 指向它,再重跑。" 1>&2
  exit 127
fi

# 能否运行 R6RS 程序?(跳过只会打印 demo 的早期 skiff stub;Chez 各名已知可用)
_prog_ok() {
  printf '(import (chezscheme))(display "CHANDLER_RT_OK")' \
    | "$1" -q --program /dev/stdin 2>/dev/null | grep -q CHANDLER_RT_OK
}

for rt in skiff scheme chez chez-scheme chezscheme; do
  command -v "$rt" >/dev/null 2>&1 || continue
  case "$rt" in
    scheme|chez|chez-scheme|chezscheme) : ;;
    *) _prog_ok "$rt" || continue ;;
  esac
  exec "$rt" -q --libdirs "$here" \
    --program "$here/chandler/cli/main.sps" install-self "$@"
done

echo "install.sh: 未找到可运行程序的 Scheme 运行时(需 skiff 或 Chez Scheme)。" 1>&2
echo "  请安装 skiff(优先)或 Chez Scheme 后重跑 ./install.sh" 1>&2
exit 127
