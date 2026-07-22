#!/bin/sh
# install.sh — bootstrap installer for chandler (POSIX counterpart of install.ps1).
# Finds a Scheme runtime that can actually run R6RS programs (skiff preferred,
# then Chez scheme) and runs `chandler install-self`, passing extra arguments
# through (e.g. --global, --force).
#
# Self-install is BUILT ON `bake install`: the library tree is installed by bake
# (reading this repo's recipe.ss) into the Chez library prefix as a src/mt split;
# this script only adds the runtime-discovery launcher. So bake must be installed
# first (the ecosystem's build tool).
#
#   ./install.sh                 # install to ~/.local (libraries via bake)
#   ./install.sh --global        # /usr/local (needs root)
#   ./install.sh --uninstall [--global]
#                                # remove a self-install; works even when the
#                                # library is broken (no need for chandler to
#                                # be runnable — handles the bootstrap deadlock
#                                # where `chandler uninstall-self` can't load)
#
# Runtime selection (same contract as the installed launcher and run/exec/repl):
#   CHANDLER_RUNTIME=skiff|chez   force WHICH runtime; a forced runtime is used
#                                 verbatim (existence check only, no probe)
#   CHANDLER_SKIFF / CHANDLER_SCHEME   which executable (name or path)
#   CHANDLER_BAKE                 which bake executable
#
# Security: prefer `git clone` + reviewing this repo over piping to a shell.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export CHANDLER_SRC="$here"

# ── --uninstall:remove a self-install WITHOUT needing chandler to be runnable ──
# Mirror of cmd-uninstall-self in chandler/cli/selfinstall.ss, kept here so a
# broken install (library deleted but launcher still present — exactly the state
# where `chandler uninstall-self` self-deadlocks) still has a recovery path.
case "${1:-}" in
  --uninstall|--uninstall-self)
    shift
    _prefix="$HOME/.local/share/chez"
    _bindir="$HOME/.local/bin"
    for _a in "$@"; do
      case "$_a" in
        --global) _prefix="/usr/local/share/chez"; _bindir="/usr/local/bin" ;;
        *) echo "install.sh --uninstall: unknown arg: $_a" 1>&2; exit 64 ;;
      esac
    done
    # 1) bake manifest (precise):逐行删清单上的文件 + 清空父目录
    #    兼容两种布局:新 src/mt 拆分(manifest 在 <prefix>/.bake-install/)与
    #    旧扁平 lib/(manifest 在 <prefix>/lib/.bake-install/)。
    _mf=""
    for _candidate in "$_prefix/.bake-install/chandler.files" "$_prefix/lib/.bake-install/chandler.files"; do
      [ -f "$_candidate" ] && _mf="$_candidate" && break
    done
    if [ -n "$_mf" ]; then
      while IFS= read -r _f || [ -n "$_f" ]; do
        [ -n "$_f" ] || continue
        rm -f "$_f" 2>/dev/null || true
        # sweep empty parents up to _prefix
        _d=$(dirname -- "$_f")
        while [ "$_d" != "$_prefix" ] && [ "$_d" != "/" ] && [ -d "$_d" ] && [ -z "$(ls -A "$_d" 2>/dev/null)" ]; do
          rmdir "$_d" 2>/dev/null || break
          _d=$(dirname -- "$_d")
        done
      done < "$_mf"
      rm -f "$_mf"
      # sweep 从 manifest 父目录(.bake-install)一路向上直至 _prefix,
      # 否则旧布局的 <prefix>/lib/.bake-install 删后 <prefix>/lib/ 仍残留。
      _d=$(dirname -- "$_mf")
      while [ "$_d" != "$_prefix" ] && [ "$_d" != "/" ] && [ -d "$_d" ] && [ -z "$(ls -A "$_d" 2>/dev/null)" ]; do
        rmdir "$_d" 2>/dev/null || break
        _d=$(dirname -- "$_d")
      done
    else
      # 2) best-effort scan:清单不在(库已被部分删除等损坏态)
      #    新布局:src/chandler/ + src/chandler.ss + 各 <mt>/chandler*
      #    旧布局:lib/chandler/ + lib/chandler.ss
      rm -rf "$_prefix/src/chandler" "$_prefix/lib/chandler" 2>/dev/null || true
      rm -f  "$_prefix/src/chandler.ss" "$_prefix/lib/chandler.ss" 2>/dev/null || true
      for _mt_dir in "$_prefix"/*/; do
        [ -d "$_mt_dir" ] || continue
        _mt=$(basename -- "$_mt_dir")
        case "$_mt" in src|lib|.bake-install) continue ;; esac
        rm -f  "$_mt_dir/chandler.so" 2>/dev/null || true
        rm -rf "$_mt_dir/chandler" 2>/dev/null || true
      done
    fi
    # 3) launcher(sh + ps1)
    rm -f "$_bindir/chandler" "$_bindir/chandler.ps1" 2>/dev/null || true
    echo "uninstalled chandler from $_prefix"
    exit 0
    ;;
esac

# Prerequisite: bake must be available (self-install delegates the library tree to it).
if ! command -v "${CHANDLER_BAKE:-bake}" >/dev/null 2>&1; then
  echo "install.sh: bake not found (self-install delegates the library tree to \`bake install\`)." 1>&2
  echo "  Install bake first, or set CHANDLER_BAKE to point at it, then re-run." 1>&2
  exit 127
fi

# Capability probe. Keep in sync with self-probe-src / self-probe-token in
# chandler/cli/selfinstall.ss -- this script is standalone (chandler is not
# installed yet), so the text is necessarily duplicated here.
#
# Prints "<token>:<skiff version>"; a non-Chez candidate must yield the token
# AND a version starting with a digit, i.e. it must self-identify as skiff.
# skiff-version is read by REFLECTION: writing (skiff-version) directly is an
# unbound identifier at expand time under --program, which is the mode used here.
_probe='(import (chezscheme))(display "CHANDLER_RT_OK:")(display (let ([s (string->symbol "skiff-version")]) (if (top-level-bound? s) (let ([v (top-level-value s)]) (if (procedure? v) (v) v)) "")))'

_prog_ok() {
  printf '%s' "$_probe" | "$1" -q --program /dev/stdin 2>/dev/null \
    | grep -q 'CHANDLER_RT_OK:[0-9]'
}

# A forced runtime is honoured verbatim: probing an explicit override would
# defeat it, and a missing one must fail loudly rather than silently fall back.
case "${CHANDLER_RUNTIME:-}" in
  skiff) _cands="${CHANDLER_SKIFF:-skiff}"; _forced=1 ;;
  chez)  if [ -n "${CHANDLER_SCHEME:-}" ]; then _cands="$CHANDLER_SCHEME";
         else _cands="scheme chez chez-scheme chezscheme"; fi; _forced=1 ;;
  "")    _cands="skiff scheme chez chez-scheme chezscheme"; _forced=0 ;;
  *) echo "install.sh: invalid CHANDLER_RUNTIME=$CHANDLER_RUNTIME (want: skiff | chez)" 1>&2
     exit 64 ;;
esac

for rt in $_cands; do
  command -v "$rt" >/dev/null 2>&1 || continue
  if [ "$_forced" -eq 0 ]; then
    case "$rt" in
      scheme|chez|chez-scheme|chezscheme) : ;;
      *) _prog_ok "$rt" || continue ;;
    esac
  fi
  exec "$rt" -q --libdirs "$here" \
    --program "$here/chandler/cli/main.sps" install-self "$@"
done

echo "install.sh: no program-capable Scheme runtime found (need skiff or Chez Scheme)." 1>&2
echo "  Install skiff (preferred) or Chez Scheme, then re-run ./install.sh" 1>&2
echo "  or force one: CHANDLER_RUNTIME=chez CHANDLER_SCHEME=<path> ./install.sh" 1>&2
exit 127
