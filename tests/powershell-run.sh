#!/usr/bin/env bash
# Acceptance runner for the WINDOWS (PowerShell) launcher — P series.
#
# The Windows launcher is generated as .ps1 (PowerShell replaced cmd), and
# because the generated text uses forward slashes and takes its path separator
# from [System.IO.Path]::PathSeparator, it runs unmodified under pwsh on ANY OS.
# So this suite renders the generator and actually EXECUTES the result here,
# instead of shipping Windows shell code nobody ever ran.
#
# Covered: syntax, runtime discovery, the capability probe, CHANDLER_RUNTIME /
# CHANDLER_SKIFF / CHANDLER_SCHEME overrides, exit-code propagation, argument
# passthrough, and a real end-to-end launch against a bake-installed prefix.
# NOT covered: Windows-only path semantics (drive letters, .exe resolution,
# execution policy) — those still need a Windows host.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
assert_contains() { case "$2" in *"$3"*) ok "$1";; *) bad "$1 (missing: $3)"; printf '    got: %s\n' "$2";; esac; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }

# pwsh is optional (a Windows-target concern); skip cleanly without it.
PWSH="$(command -v pwsh 2>/dev/null)"
if [ -z "$PWSH" ]; then
  for c in "$HOME/.local/share/mise/installs/powershell"/*/pwsh; do
    [ -x "$c" ] && { PWSH="$c"; break; }
  done
fi
if [ -z "$PWSH" ]; then
  echo "powershell-run: pwsh not found — skipping P series (install: mise use powershell)"
  exit 0
fi

SCHEME="${CHANDLER_SCHEME_BIN:-scheme}"
command -v "$SCHEME" >/dev/null 2>&1 || { echo "powershell-run: no scheme — skipping"; exit 0; }

W="${TMPDIR:-/tmp}/chandler-ps-$$"
rm -rf "$W"; mkdir -p "$W"
trap 'rm -rf "$W"' EXIT

# Render the launcher by importing the library and calling the generator
# (chandler only writes .ps1 when machine-type is Windows, which this host is not).
render() {  # render <prefix> <outfile>
  ( cd "$ROOT" && "$SCHEME" -q --libdirs . <<EOF > "$2"
(import (chandler cli selfinstall))
(display (launcher-ps1 "$1"))
EOF
  )
}

echo "P — PowerShell launcher ($("$PWSH" -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'))"

render "$W/prefix" "$W/chandler.ps1"

# P1 — it parses as valid PowerShell
OUT=$("$PWSH" -NoProfile -Command "
  \$e=\$null; \$t=\$null
  [System.Management.Automation.Language.Parser]::ParseFile('$W/chandler.ps1',[ref]\$t,[ref]\$e) > \$null
  if (\$e -and \$e.Count) { \$e | ForEach-Object { 'ERR: ' + \$_.Message } } else { 'parse-ok' }" 2>&1)
assert_contains "P1 parses as PowerShell" "$OUT" "parse-ok"

# P2 — invalid CHANDLER_RUNTIME is rejected with EX_USAGE (64)
OUT=$(CHANDLER_RUNTIME=bogus "$PWSH" -NoProfile -File "$W/chandler.ps1" 2>&1); CODE=$?
assert_eq "P2 invalid CHANDLER_RUNTIME exits 64" "$CODE" "64"
assert_contains "P2 invalid CHANDLER_RUNTIME explains" "$OUT" "want: skiff | chez"

# P3 — no runtime on PATH exits 127
env -i PATH=/nonexistent HOME="$HOME" "$PWSH" -NoProfile -File "$W/chandler.ps1" >/dev/null 2>&1
assert_eq "P3 no runtime exits 127" "$?" "127"

# ---- end-to-end against a real bake-installed prefix (needs bake) ----
if ! command -v "${CHANDLER_BAKE:-bake}" >/dev/null 2>&1; then
  echo "  (skipping P4+ — bake not available)"
else
  FAKE="$W/home"; mkdir -p "$FAKE"
  ( cd "$ROOT" && HOME="$FAKE" "${CHANDLER_BAKE:-bake}" install -q ) >/dev/null 2>&1
  PFX="$FAKE/.local/share/chez"
  render "$PFX" "$W/real.ps1"

  # `chandler --version` reports the runtime it is running on, e.g.
  #   chandler 0.1.2 (skiff 0.1.1) (chez 10.4.1)   <- selected skiff
  #   chandler 0.1.2 (chez 10.4.1)                 <- selected stock Chez
  # so these assertions verify WHICH runtime the launcher picked, not merely
  # that it launched.
  CVER=$("$SCHEME" -q --libdirs "$ROOT" --program "$ROOT/chandler/cli/main.sps" --version 2>/dev/null)

  # P4 — default discovery launches; prefers skiff when one passes the probe
  OUT=$("$PWSH" -NoProfile -File "$W/real.ps1" --version 2>&1)
  assert_contains "P4 default discovery launches" "$OUT" "chandler "
  if command -v skiff >/dev/null 2>&1; then
    assert_contains "P4b default discovery prefers skiff" "$OUT" "(skiff "
  fi

  # P5 — CHANDLER_RUNTIME actually forces the kind
  OUT=$(CHANDLER_RUNTIME=chez "$PWSH" -NoProfile -File "$W/real.ps1" --version 2>&1)
  assert_eq "P5a CHANDLER_RUNTIME=chez selects Chez" "$OUT" "$CVER"
  case "$OUT" in *"(skiff "*) bad "P5a must not land on skiff";; *) ok "P5a did not land on skiff";; esac
  if command -v skiff >/dev/null 2>&1; then
    OUT=$(CHANDLER_RUNTIME=skiff "$PWSH" -NoProfile -File "$W/real.ps1" --version 2>&1)
    assert_contains "P5b CHANDLER_RUNTIME=skiff selects skiff" "$OUT" "(skiff "
  fi

  # P6 — CHANDLER_SCHEME names an exact executable (absolute path)
  OUT=$(CHANDLER_RUNTIME=chez CHANDLER_SCHEME="$(command -v "$SCHEME")" \
        "$PWSH" -NoProfile -File "$W/real.ps1" --version 2>&1)
  assert_eq "P6 CHANDLER_SCHEME honoured verbatim" "$OUT" "$CVER"

  # P7 — an explicit override that does not exist FAILS (127) rather than
  #      silently falling back to another runtime, which would defeat it.
  CHANDLER_RUNTIME=chez CHANDLER_SCHEME="$W/no-such-scheme" \
    "$PWSH" -NoProfile -File "$W/real.ps1" --version >/dev/null 2>&1
  assert_eq "P7 missing forced runtime exits 127 (no silent fallback)" "$?" "127"

  # P8 — child exit code is propagated (unknown subcommand = EX_USAGE 64)
  "$PWSH" -NoProfile -File "$W/real.ps1" bogus-subcommand >/dev/null 2>&1
  assert_eq "P8 child exit code propagates" "$?" "64"

  # P9 — arguments reach the program
  OUT=$("$PWSH" -NoProfile -File "$W/real.ps1" help 2>&1 | head -1)
  assert_contains "P9 arguments pass through" "$OUT" "git-first library manager"
fi

echo
printf 'powershell-run: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
