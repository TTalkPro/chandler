#!/bin/sh
# install.sh --- Chandler 自举安装(designs/08 §2)
#
# 打破鸡生蛋:用解释执行的 Chandler(bootstrap.ss)把自己装进用户级 libdir。
# 安全:推荐先 `git clone` + 审阅本仓再执行本脚本(而非 curl|sh 盲跑)。
#
# 用法:  ./install.sh              # 从本仓库就地安装
#        CHANDLER_SCHEME=/path/scheme ./install.sh
set -eu

# 1) 定位 scheme,校验版本下界(>=10.0)
scheme=${CHANDLER_SCHEME:-scheme}
if ! command -v "$scheme" >/dev/null 2>&1; then
  echo "错误:未找到 Chez Scheme(scheme)。请先安装 Chez >=10.0,或设 CHANDLER_SCHEME。" >&2
  exit 1
fi
ver=$("$scheme" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
major=$(echo "$ver" | cut -d. -f1)
if [ "${major:-0}" -lt 10 ]; then
  echo "错误:需 Chez >=10.0,当前 $ver。" >&2
  exit 1
fi

# 2) 仓库根 = 本脚本所在目录
repo=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# 3) 落点
libdir=${CHANDLER_LIBDIR:-"${XDG_DATA_HOME:-$HOME/.local/share}/chez/lib"}
bindir=${CHANDLER_BINDIR:-"$HOME/.local/bin"}
mkdir -p "$libdir" "$bindir"

echo "install.sh: scheme=$scheme ($ver)"
echo "install.sh: repo=$repo"
echo "install.sh: libdir=$libdir  bindir=$bindir"

# 4) 用解释执行的 chandler 给自己走正常安装事务
"$scheme" -q --libdirs "$repo" --script "$repo/bootstrap.ss" "$repo" "$libdir" "$bindir"

# 5) PATH 提示
case ":$PATH:" in
  *":$bindir:"*) : ;;
  *) echo ""; echo "提示:把 $bindir 加入 PATH,例如:"; echo "  export PATH=\"$bindir:\$PATH\"" ;;
esac
