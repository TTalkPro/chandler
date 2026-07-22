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
