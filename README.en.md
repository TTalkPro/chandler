# Chandler

> A git-first Chez Scheme library manager — the **purveyor** of the **Skiff** runtime ecosystem. Reads `manifest.ss`, vendoring R6RS libraries from git repositories into a project's `lib/`, and a single `(activate)` mounts the whole dependency environment. Works with **both** stock Chez and Skiff runtimes.

**[中文](README.md) | English** — Design docs in [designs/](designs/) (in Chinese).

> **Note:** the design documents under [`designs/`](designs/) are written in Chinese — they are dense, internal design reasoning. This README is the English mirror of the user-facing [README.md](README.md); the Chinese version is the canonical source.

## Roles

- **Skiff** (light boat) = the runtime (Chez + libuv); **Chandler** (the ship's purveyor) = the package manager, in charge of **dependency acquisition and activation**; **bake** = the build tool (separate repo), in charge of **compilation**.
- git-first: dependency sources (URL + tag/rev/branch pin) live in `manifest.ss`; no central registry.
- A dependency = whole-repo checkout into `vendor/<name>/`, then `bake install` flattens it into `lib/{src,<mt>}` (src/mt split); `manifest.lock` pins the exact commit for reproducibility.

> **2026-07-22 alignment with bake install redesign**: `bake install` now writes to a **src/mt split** layout instead of a flat `lib/` — sources → `<prefix>/src/`, platform-bound artifacts (compiled `.so` + native) under `_build/<mt>/` → `<prefix>/<mt>/`. Consumers use a single Chez library directory **pair** `<prefix>/src::<prefix>/<mt>` (`::` = source::object) to resolve both source and object; native artifacts live with their owning library at `<prefix>/<mt>/<lib>/native/`.

## Installation

### Prerequisites

| Need | Notes |
|------|-------|
| **Scheme runtime** | **skiff** (preferred) or **Chez Scheme ≥ 10.0**. Either is fine; if both are present, skiff is the default. **Petite is not enough** — it lacks the compiler, and `bake install` needs to compile the library tree. |
| **git** | Required for dependency acquisition (`git` must be on PATH). |
| **bake** | The build tool of the ecosystem. **chandler's self-install is based on `bake install`**: the library tree is installed by bake into the Chez library prefix (reading this repo's `recipe.ss`); this repo's install script only adds a runtime-discovering launcher. **bake must be installed first.** |
| PowerShell | **Windows only** (launcher and install scripts are `.ps1`). Bundled with Windows 10/11; or `mise use powershell`. |

If you don't yet have a runtime before installing bake, install skiff or Chez first; `mise` users can `mise use chezscheme`.

### POSIX (Linux / macOS)

```sh
git clone <this-repo> chandler && cd chandler
./install.sh                      # libraries via bake → ~/.local/share/chez/{src,<mt>}; launcher → ~/.local/bin/chandler
./install.sh --global             # install to /usr/local (needs root)

export PATH="$HOME/.local/bin:$PATH"   # if not already on PATH (the script prints this hint)
chandler --version                     # → chandler 0.1.5 (skiff 0.1.1) (chez 10.4.1)
```

### Windows (PowerShell)

```powershell
git clone <this-repo> chandler; cd chandler
./install.ps1                     # launcher → %USERPROFILE%\.local\bin\chandler.ps1
./install.ps1 --global            # system-wide (needs admin)

$env:PATH = "$HOME\.local\bin;$env:PATH"
chandler --version
```

> A `.ps1` on PATH can be invoked by its **bare** name `chandler`, so commands read identically on both platforms.
> If PowerShell reports "running scripts is disabled", the execution policy is Restricted — pick one:
> `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` (one-time), or
> `pwsh -ExecutionPolicy Bypass -File ./install.ps1` (this run only).

### After installation

The installed launcher performs **runtime discovery**: prefer `skiff`, fall back to `scheme` / `chez` (see designs/06 dual-runtime), and mounts the `<prefix>/src::<prefix>/<mt>` pair to run `<prefix>/src/chandler/cli/main.sps`. On POSIX it's `chandler` (sh), on Windows it's `chandler.ps1` (PowerShell).

To pin a specific runtime, see [Pin a runtime](#pinning-a-runtime-skiff--chez) below — the install script and the launcher honor the same set of variables.

**Uninstall**: `chandler uninstall-self` (reads bake's `<prefix>/.bake-install/chandler.files` manifest to delete libraries + the launcher; **does not need the source repo**, so you can delete the clone after install and uninstall still works cleanly).

**No install needed for development**: inside the repo, `./bin/chandler <command>` works directly (skiff preferred as well).

### Build / install via bake (closing the ecosystem loop)

chandler ships a `recipe.ss`, so the ecosystem build tool **bake** can build and install it directly — placing the `(chandler …)` library tree into the Chez lib dir so `(import (chandler …))` resolves globally (bake itself depends on `(chandler lock/registry/…)`, which is the closure point of **skiff runs · chandler manages deps · bake installs libs**):

```sh
bake            # = bake build, compile the (chandler) library tree to .so
bake test       # run the full test suite
bake test-ps    # PowerShell launcher acceptance (needs pwsh; skipped if absent)
bake install    # install the (chandler) library tree → ~/.local/share/chez/{src,<mt>} (--global installs to /usr/local)
bake uninstall  # clean uninstall using the file manifest
```

> `bake install` installs **libraries** (for `import`, src/mt split, `(needs build)` always installs compiled content); the `chandler` **CLI launcher** is provided by `chandler install-self` / `install.sh`.

## Quick start

```sh
chandler init --name=myapp                 # scaffold manifest.ss (vendor/ lib/ setup added to .gitignore)
chandler add http https://github.com/x/http --tag v1.2.0
chandler install                           # resolve → write lock → git deps to vendor/ → bake install into lib/{src,<mt>}
chandler list                              # show locked dependencies
chandler verify                            # CI: check vendor/ matches the lock
chandler repl                              # interactive shell (library paths auto-mounted)
```

## Dependency model (Bundler-style)

```
myapp/
  manifest.ss  manifest.lock
  vendor/<name>/           ← raw whole-repo checkout of git dependencies
  lib/                     ← the project's own Chez library **prefix** (same shape as ~/.local/share/chez and an unpacked pack)
    src/<name>.ss  src/<name>/…       ← each dependency's sources, co-located (flattened by install)
    <mt>/<name>.so  <mt>/<name>/…  <mt>/<name>/native/…   ← compiled artifacts + native (filled in by `chandler build`)
    share/<name>/resources/…          ← resources (declared by dependencies + synced from the project's own resources/)
    .chandler/<name>/manifest.ss      ← manifest snapshot (this is how the app name is known)
```

- **`chandler install`**: git dependencies are checked out whole-repo into `vendor/`, then **bake install** places them into `lib/{src,<mt>}` (sources only). Library search mounts the **pair** `lib/src::lib/<mt>`, same shape as the global prefix `~/.local/share/chez` (install depends on bake).
- **`chandler build`**: generates a recipe at the project root (`define-lib-roots "lib/src"` + per-dependency `library-task` / authorized `native-task`), then runs **real bake** to compile into `_build/<mt>/`, and copies the result into `lib/<mt>/` to complete the src/object pair (compiled artifacts + native).
- **path dependencies** `(path "../x")`: do not enter vendor/lib; their source directory is mounted live (edit a line, it takes effect immediately).

### Native loading: self-loader first, universal load as fallback

bake generates a `(<lib> native-loader)` for every library that has native artifacts (product at `lib/<mt>/<lib>/native-loader.so`); when that library's FFI is referenced, the loader locates and `dlopen`s the `.so` **itself** — and one of its candidates is the **object side** of `library-directories`, which is exactly where chandler's `lib/src::lib/<mt>` pair drops native artifacts. So **mounting the pair is enough**, and it's **lazy** (no `dlopen` until the FFI is touched).

The pre-loading in `activate` / `run` / `repl` is therefore demoted to a **fallback**: only third-party libraries that lack a generated loader (not built by bake) get scanned and loaded; libraries with `native-loader.so` are always skipped.

### Launching: always `chandler run`

```sh
chandler run --script main.ss [args...]
```

It hands over two things, after which `(import (dep))` just resolves in your script:

- **library search paths** — the `lib/src::lib/<mt>` pair (+ path-dependency sources + the project's own
  library root + a global fallback pair);
- **`APP_ROOT`** — the project's library prefix `<project>/lib`. Resources and native artifacts hang off it
  at fixed paths: `$APP_ROOT/share/<app>/resources/` (application data — see `app-resource-path` in
  `(chandler runtime-paths)`) and `$APP_ROOT/<mt>/<lib>/native/` (what a bake-generated native-loader builds).

The point is that **all three states have the same shape**: the project's `lib/`, the global prefix
`~/.local/share/chez`, and an unpacked pack are the same kind of prefix — whichever one `APP_ROOT` points
at, application code stays byte-for-byte identical.

The project's own `resources/` is synced into `lib/share/<name>/resources/` by `chandler deps` / `run` /
`repl` (incrementally, by mtime), so editing a resource during development takes effect on the next
`chandler run`.

> Earlier versions generated a `chandler-setup.ss` (Bundler's `bundler/setup` style, `(load)`ed by the main
> script). It is gone: there is exactly one way to start a program, which removes a whole class of
> "generated file drifted from the real rules" problems. To mount the same paths in another process use
> `eval "$(chandler env)"` (it exports both `CHEZSCHEMELIBDIRS` and `APP_ROOT`); a script that already has
> `(chandler)` can just call `(activate)`.

### Library search rules (shared by run / env / repl / activate)

- **Project** (has lock + deps): the `lib/src::lib/<mt>` pair + path source dirs + the project's own library root + a global fallback pair (project wins, highest priority).
- **Non-project**: just the global prefix pair `~/.local/share/chez/src::~/.local/share/chez/<mt>`.

## Command reference

| Command | Effect |
|---------|--------|
| `init [--lib\|--app] [--name=N]` | Scaffold `manifest.ss` (lib by default; `--app` writes `(app …)` so it can be packed) |
| `add <name> <url> [--tag/--rev/--branch/--path]` | Add a dependency |
| `remove <name>` | Remove a dependency |
| `install [--production] [--offline] [--force]` | Resolve and materialize into `lib/{src,<mt>}` |
| `update` | Ignore the existing lock and re-resolve |
| `build [--allow-build[=a,b]]` | Generate a recipe → real bake compiles the dependency closure + native → `lib/<mt>/` |
| `verify` | Check `vendor/` matches the lock + `lib/src` exists (for CI) |
| `list` / `tree` | Show locked dependencies |
| `run <script.ss> [args…]` | Run a script with the dependency environment activated |
| `exec -- <cmd…>` | Run a command with `CHEZSCHEMELIBDIRS` set |
| `repl [--runtime skiff\|chez]` | Interactive shell with library paths auto-mounted: **project with lock+deps → project `lib/` (highest priority) + global fallback; otherwise → global only** |
| `install --global[=dir]` | Install the current project's libraries into the global libdir (registry transaction) |
| `uninstall --global --name=<n>` | Clean uninstall using the file manifest |
| `list --global` / `doctor --global` | List / health-check globally installed packages |
| `install-self [--prefix D] [--global]` | Self-install chandler to `~/.local` (bake-style, skiff-preferred launcher) |
| `uninstall-self [--prefix D]` | Uninstall a self-installed chandler |
| `self-update` | Tells you to re-run `install.sh` |

Global flags: `-C <dir>` `--offline` `--production` `--force` `--keep-extra` `--verbose`.

## Pinning a runtime (skiff / chez)

"Which runtime" and "which executable" are separate concerns:

| Variable | Effect |
|----------|--------|
| `CHANDLER_RUNTIME=skiff\|chez` | Choose **which kind**; an illegal value is an error (exit code 64), never silently ignored |
| `CHANDLER_SKIFF=<exe>` | The skiff executable (name or path) |
| `CHANDLER_SCHEME=<exe>` | The Chez executable (name or path) |
| `CHANDLER_BAKE=<exe>` | The bake executable (install/build delegate to it) |

**Priority** (shared by `run` / `exec` / `repl`, **launchers**, and **install scripts**):

```
--runtime flag  >  CHANDLER_RUNTIME  >  manifest declaration (only `(skiff …)` → skiff)  >  default
```

```sh
CHANDLER_RUNTIME=skiff chandler run app.ss        # force skiff
CHANDLER_RUNTIME=chez  chandler repl              # force Chez
chandler run --runtime=chez app.ss                # flag wins
CHANDLER_RUNTIME=chez CHANDLER_SCHEME=/opt/chez/bin/scheme chandler run app.ss
```

**Honored at install time too** (which runtime runs the installer itself):

```sh
CHANDLER_RUNTIME=chez ./install.sh                # POSIX
```
```powershell
$env:CHANDLER_RUNTIME='chez'; ./install.ps1       # Windows
```

**Confirm which one is in use** — `--version` reports the hosting runtime (skiff self-identifies via built-in `(skiff-version)` since 0.1.1):

```sh
$ chandler --version
chandler 0.1.5 (skiff 0.1.1) (chez 10.4.1)   # running on skiff
$ CHANDLER_RUNTIME=chez chandler --version
chandler 0.1.5 (chez 10.4.1)                 # running on stock Chez
```

> **Explicit overrides are taken literally**: if you set `CHANDLER_SKIFF` / `CHANDLER_SCHEME`, only that one is used — if missing, it fails (exit code 127), **never** silently falling back to another runtime (silent fallback would defeat the override). Likewise, an explicitly chosen runtime skips capability probing.
>
> **Under auto-discovery**, the opposite holds: a candidate named `skiff` must pass a capability probe — actually run an R6RS program and self-identify as skiff via `(skiff-version)` — before being selected. So a same-named executable that runs programs but isn't skiff is correctly skipped, falling back to Chez.

## Security model (designs/08)

- **Manifests are `read`, not eval'd**: `manifest.ss` / `manifest.lock` / registry are pure data, never `eval`'d / `load`'d.
- **Zero execution during git clone/checkout**: every git invocation carries `-c core.hooksPath=/dev/null`.
- **Native build = RCE, requires explicit authorization**: native builds of dependencies (someone else's code) require `--allow-build`, and the authorization is **bound to the build-description hash** written to `.chandler-approvals` — a swapped script (description change) invalidates it and re-prompts.
- **rev is full-length locked = content-addressed**: materialization only honors the exact commit from the lock; tampering/replay is caught by git's object hash.

## Development

```sh
scheme --libdirs . --program tests/run-tests.sps    # full test suite (pure Chez, no external deps)
petite  --libdirs . --program tests/run-tests.sps   # same (Petite-subset check)
skiff   --libdirs . --program tests/run-tests.sps   # same (Skiff runtime)
bash tests/powershell-run.sh                        # Windows launcher acceptance (needs pwsh; skipped if absent)
```

`tests/powershell-run.sh` **renders the generated `chandler.ps1` and actually runs it under pwsh** (syntax / runtime enforcement / overrides / exit codes / arg passing / end-to-end launch) — because the generated script uses forward slashes and `[System.IO.Path]::PathSeparator` as the separator, the same script works under Linux's pwsh too. Install pwsh with `mise use powershell`.

The library layout follows the [library layout spec](designs/13-library-source-layout.md): an umbrella `chandler.ss` + a same-named subtree `chandler/`, with the search root = the repo root. The core only `import (chezscheme)`, restricted to the Petite-runnable subset (portable across both runtimes).

### Language conventions

- **All user-visible output is English**: CLI help, runtime hints/warnings/errors (`printf` / `fprintf` / `error` messages), and the headers of **generated files** (`.chandler-build.ss`, a pack's `bootstrap.ss`) — the tool's audience is not limited to Chinese readers. Style follows Unix diagnostic conventions: lowercase, terse, no trailing period, e.g. ``manifest.ss not found; run `chandler init` first``.
- **Source comments (`;;` / `;;;`) and this repo's docs are in Chinese**, for the expressive density that helps design reasoning.
- Plurals use `(plural n "dependency" "dependencies")` (from `(chandler util)`), avoiding `1 dependencies`.
