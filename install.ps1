#!/usr/bin/env pwsh
# install.ps1 — bootstrap installer for chandler, the PowerShell counterpart of
# install.sh. Finds a Scheme runtime that can actually run R6RS programs (skiff
# preferred, then Chez scheme) and runs `chandler install-self`, passing extra
# arguments through (e.g. --global, --force).
#
# Self-install is BUILT ON `bake install`: the library tree is installed by bake
# (reading this repo's recipe.ss) into the Chez library prefix as a src/mt split;
# this script only adds the runtime-discovery launcher (chandler.ps1). So bake
# must be installed first.
#
#   ./install.ps1                  # install to ~/.local (libraries via bake)
#   ./install.ps1 --global         # system-wide (needs admin)
#
# Runtime selection (same contract as the installed launcher and run/exec/repl):
#   $env:CHANDLER_RUNTIME = 'skiff'|'chez'   force WHICH runtime; a forced runtime
#                                            is used verbatim (no probe)
#   $env:CHANDLER_SKIFF / $env:CHANDLER_SCHEME   which executable (name or path)
#   $env:CHANDLER_BAKE                       which bake executable
#
# If PowerShell refuses to run this ("running scripts is disabled"), the machine
# is on the Restricted execution policy — either
#   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
# once, or invoke it directly:  pwsh -ExecutionPolicy Bypass -File ./install.ps1

# A native command exiting nonzero must not throw: the probe below decides by
# reading exit codes (PowerShell 7.3+ would otherwise turn them into terminating
# errors whenever ErrorActionPreference is Stop).
$PSNativeCommandUseErrorActionPreference = $false
$ErrorActionPreference = 'Continue'

$InstallArgs = $args
$Here = $PSScriptRoot
$env:CHANDLER_SRC = $Here
$Program = "$Here/chandler/cli/main.sps"
$Token = 'CHANDLER_RT_OK'

# Prerequisite: bake must be available (self-install delegates the library tree to it).
$BakeCmd = if ($env:CHANDLER_BAKE) { $env:CHANDLER_BAKE } else { 'bake' }
if (-not (Get-Command $BakeCmd -ErrorAction SilentlyContinue) -and
    -not (Test-Path -LiteralPath $BakeCmd)) {
  [Console]::Error.WriteLine("install.ps1: bake not found (self-install delegates the library tree to ``bake install``).")
  [Console]::Error.WriteLine('  Install bake first, or set $env:CHANDLER_BAKE to point at it, then re-run.')
  exit 127
}

# Capability probe. Keep in sync with self-probe-src / self-probe-token in
# chandler/cli/selfinstall.ss -- this script is standalone (chandler is not
# installed yet), so the text is necessarily duplicated here.
#
# Prints "<token>:<skiff version>"; a non-Chez candidate must yield the token AND
# a version starting with a digit, i.e. it must self-identify as skiff.
# skiff-version is read by REFLECTION: writing (skiff-version) directly is an
# unbound identifier at expand time under --program, which is the mode used here.
$ProbeSrc = '(import (chezscheme))(display "CHANDLER_RT_OK:")(display (let ([s (string->symbol "skiff-version")]) (if (top-level-bound? s) (let ([v (top-level-value s)]) (if (procedure? v) (v) v)) "")))'

$ChezNames = @('scheme','chez','chez-scheme','chezscheme')

function Test-ChandlerRuntime([string]$Exe, [string]$Probe) {
  if (-not $Probe) { return $true }
  # $null | … closes the child's stdin so a REPL-ish runtime cannot sit waiting
  # for input during discovery.
  $out = $null | & $Exe -q --program $Probe 2>$null
  if ($LASTEXITCODE -ne 0) { return $false }
  return (($out -join ' ') -match "${Token}:\d")
}

# A forced runtime is honoured verbatim: probing an explicit override would
# defeat it, and a missing one must fail loudly rather than silently fall back.
$Forced = $false
switch ($env:CHANDLER_RUNTIME) {
  'skiff' { $Cands = @($(if ($env:CHANDLER_SKIFF) { $env:CHANDLER_SKIFF } else { 'skiff' })); $Forced = $true }
  'chez'  { $Cands = $(if ($env:CHANDLER_SCHEME) { @($env:CHANDLER_SCHEME) } else { $ChezNames }); $Forced = $true }
  ''      { $Cands = @('skiff') + $ChezNames }
  $null   { $Cands = @('skiff') + $ChezNames }
  default {
    [Console]::Error.WriteLine("install.ps1: invalid CHANDLER_RUNTIME=$($env:CHANDLER_RUNTIME) (want: skiff | chez)")
    exit 64
  }
}

$probe = Join-Path ([System.IO.Path]::GetTempPath()) "chandler-probe-$PID.ss"
try { Set-Content -LiteralPath $probe -Value $ProbeSrc -Encoding ascii }
catch { $probe = $null }
try {
  foreach ($rt in $Cands) {
    $exe = $null
    $c = Get-Command $rt -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { $exe = $c.Source }
    elseif (Test-Path -LiteralPath $rt) { $exe = (Resolve-Path -LiteralPath $rt).Path }
    if (-not $exe) { continue }
    if (-not $Forced -and ($rt -notin $ChezNames)) {
      if (-not (Test-ChandlerRuntime $exe $probe)) { continue }
    }
    & $exe -q --libdirs $Here --program $Program install-self @InstallArgs
    exit $LASTEXITCODE
  }
} finally {
  if ($probe -and (Test-Path -LiteralPath $probe)) {
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
  }
}

[Console]::Error.WriteLine('install.ps1: no program-capable Scheme runtime found (need skiff or Chez Scheme).')
[Console]::Error.WriteLine('  Install skiff (preferred) or Chez Scheme, then re-run ./install.ps1')
[Console]::Error.WriteLine('  or force one: $env:CHANDLER_RUNTIME=''chez''; $env:CHANDLER_SCHEME=''<path>''; ./install.ps1')
exit 127
