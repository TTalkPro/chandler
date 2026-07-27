# Chandler

> A git-first Chez Scheme package manager **and build tool** — the **purveyor** of the **Skiff** runtime ecosystem. Reads `chandler-manifest.ss`, installs R6RS libraries from git repositories into your project, and a single `chandler run` mounts the whole dependency environment and runs it. Works with **both** stock Chez and Skiff runtimes.

**[中文](README.md) | English** — Design docs in [designs/](designs/) (in Chinese).

> **Note:** the design documents under [`designs/`](designs/) are written in Chinese — they are dense, internal design reasoning. This README is the English mirror of the user-facing [README.md](README.md); the Chinese version is the canonical source.

## Roles

> **New in v3**: multi-version coexistence + `chandler switch`; resources method B (co-located with library sources); a central `.registry/`; lock-driven `run.sps`. See [designs/06-installed-layout.md](designs/06-installed-layout.md).

- **Skiff** (light boat) = the runtime (Chez + libuv); **Chandler** (the ship's purveyor) = the package manager **and build tool**, in charge of **dependency acquisition, compilation, activation and packing**.
- git-first: dependency sources (URL + tag/rev/branch pin) live in `chandler-manifest.ss`; no central registry.
- A dependency = whole-repo checkout into `_vendor/<name>/`, each compiled **in place** (artifacts stay in its own `_build/<mt>/`); `chandler-manifest.lock` pins the exact commit for reproducibility.
- Consumers use a Chez library directory **pair** `<src>::<obj>` (`::` = source::object) to resolve source and object together; native artifacts live with their owning library at `<obj>/<lib>/native/`.

## Installation

### Prerequisites

| Need | Notes |
|------|-------|
| **Scheme runtime** | **skiff** (preferred) or **Chez Scheme ≥ 10.0**. Either is fine; if both are present, skiff is the default. **Petite is not enough** — it lacks the compiler, and `chandler build` / `chandler make` need to compile the library tree. |
| **git** | Required for dependency acquisition (`git` must be on PATH). |
| PowerShell | **Windows only** (launcher and install scripts are `.ps1`). Bundled with Windows 10/11; or `mise use powershell`. |

If you don't have a runtime yet, install skiff or Chez first; `mise` users can `mise use chezscheme`.

### POSIX (Linux / macOS)

```sh
git clone <this-repo> chandler && cd chandler
scheme --script bootstrap.ss               # libraries → ~/.local/share/chez/{src,<mt>}; launcher → ~/.local/bin/chandler
skiff --script bootstrap.ss --system       # install to /usr/local (needs root)

export PATH="$HOME/.local/bin:$PATH"   # if not already on PATH (the script prints this hint)
chandler --version                     # → chandler 0.1.5 (skiff 0.1.2) (chez 10.4.1)
```

### Windows (PowerShell)

```powershell
git clone <this-repo> chandler; cd chandler
scheme --script bootstrap.ss                 # launcher → %LOCALAPPDATA%\chez\bin\chandler.ps1
scheme --script bootstrap.ss --system        # system-wide (needs admin)

$env:PATH = "$HOME\.local\bin;$env:PATH"
chandler --version
```

> A `.ps1` on PATH can be invoked by its **bare** name `chandler`, so commands read identically on both platforms.
> If PowerShell reports "running scripts is disabled", the execution policy is Restricted — pick one:
> `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` (one-time), or
> `pwsh -ExecutionPolicy Bypass -File <script>` (this run only).

> `bootstrap.ss` is a self-contained **three-stage bootstrap installer** (pure `(chezscheme)`, zero chandler
> imports — so it still works when the chandler libraries themselves are broken):
> ① load the CLI straight from source and run `deps` + `build` + `install --prefix=./_bootstrap`, producing a
> `_bootstrap/` that is **structurally identical** to a normal `--user` install (library tree + `.registry/` +
> stable shim); ② re-`build` this repo using the chandler in `_bootstrap` (self-hosting check); ③ use that one
> to `install` into the final prefix and smoke-test the launcher. All install logic reuses chandler's own
> `cmd-install`; bootstrap only orchestrates.
> Usage: `scheme --script bootstrap.ss [--user|--system|--prefix=DIR] [--force] [--uninstall] [--bootstrap-only]`.
> `--user` (default) installs to `~/.local`; `--system` to `/usr/local`; `--prefix=DIR` to `DIR` + `DIR/bin`;
> `--bootstrap-only` runs stage ① only (for debugging the bootstrap). You pick the runtime by how you invoke it
> (`scheme` vs `skiff`).

### After installation

The installed launcher is a **stable shim** (D17): at run time it reads `<libdir>/.registry/chandler.ss` to find the active version, hands over to `<vroot>/.chandler/run.sps` (which mounts library paths from the lock, D18), and then performs **runtime discovery** (prefer `skiff`, fall back to `scheme` / `chez`). On POSIX it's `chandler` (sh), on Windows it's `chandler.ps1` (PowerShell). With several versions installed side by side, `chandler switch` picks the active one — the shim itself is never rewritten.

To pin a specific runtime, see [Pin a runtime](#pinning-a-runtime-skiff--chez) below — the install script and the launcher honor the same set of variables.

**Uninstall**: `scheme --script bootstrap.ss --uninstall` (registry-driven: removes `<vroot>`, updates `.registry/`, deletes the launcher, and clears `_bootstrap/`; it needs the source repo, because it loads the CLI to perform the uninstall).

**No install needed for development**: inside the repo, `./bin/chandler <command>` works directly (skiff preferred as well).

### Build and tasks (`chandler make`)

bake's compile engine has been absorbed into chandler wholesale; the standalone `bake` binary is gone. chandler ships its own `chandler-tasks.ss` (formerly `recipe.ss`), consumed by the `chandler make` subcommand:

```sh
chandler make            # = build, compile the (chandler) library tree to .so → _build/<mt>/
chandler make clean      # remove .so and other build artifacts
chandler make -T         # list tasks
```

> **Most projects need no `chandler-tasks.ss` at all**: `chandler build` derives what to compile straight from `(app (entry …))` in `chandler-manifest.ss`. Write one only for custom tasks (bespoke packaging, cleanup, …). It is a **program** (loading it evaluates it), paired with the **data** file `chandler-manifest.ss`.
>
> **Installation** is handled by the self-contained `bootstrap.ss` (installs the library tree + generates the CLI launcher), not by `chandler make`.
>
> **Run tests with `chandler test`** (see below), not via a `'test` task in `chandler-tasks.ss`.

### Testing (`chandler test`)

```sh
chandler test                       # run the full test suite (tests/run-tests.sps)
chandler test --runtime=chez        # force Chez (default follows the current runtime)
```

`chandler test` is the **canonical entry point** for running tests: it mounts the project library paths (`resolved-libdirs`'s per-dep `(src . obj)` pairs + the project library root + a global fallback) + the native pre-load fallback + selects a runtime + loads `.env` / `.env.tests`, then exits with the test process's exit code. Extra arguments pass through to `tests/run-tests.sps`. It replaces the previous `'test` task in `chandler-tasks.ss` — that task has been removed from the default template to avoid confusion with a same-named CLI subcommand.

`.env.tests` (project root, **optional**) overrides same-name keys in `.env`, but **only during `chandler test`** (it's **not** read by `run` / `repl` / `exec` / `env`). Use it to point tests at a stub database / mock API / disable side effects without polluting the development environment. If `.env.tests` is absent, only `.env` is read (same as `run` / `repl`).

## Quick start

```sh
chandler init --name=myapp                 # scaffold chandler-manifest.ss + chandler-tasks.ss (_vendor/ added to .gitignore)
chandler add http https://github.com/x/http --tag v1.2.0
chandler deps                              # resolve → write lock → whole-repo checkout of git deps into _vendor/
chandler build                             # in-process compile of the dependency closure → each _vendor/<dep>/_build/<mt>/
chandler deps --list                       # show locked dependencies (`chandler list` shows globally installed packages)
chandler verify                            # CI: check _vendor/ matches the lock
chandler repl                              # interactive shell (library paths auto-mounted)
```

## Dependency model (Bundler-style)

```
myapp/
  chandler-manifest.ss  chandler-manifest.lock
  _vendor/<name>/                    ← whole-repo checkout of git dependencies (sources live)
    <srcdir>/_build/<mt>/            ← `chandler build` artifacts, compiled in place and left there
  _vendor/chandler/                  ← the runtime gate (copied from CHANDLER_HOME by deps)
    chandler/<sub>.ss                ← runtime-subset sources
    _build/<mt>/chandler/<sub>.so    ← objects
  resources/<libpath>/               ← the project's own resources (co-located with library sources:
                                       method B, `<src>/<libpath>/resources/`)
```

- **`chandler deps`**: git dependencies are checked out whole-repo into `_vendor/<name>/` (sources live); the chandler runtime gate is copied from `CHANDLER_HOME` into `_vendor/chandler/`.
- **`chandler build`**: compiles dependencies **in place**, one at a time in the lock's topological order (cwd = that dependency's srcdir, artifacts land in `_vendor/<dep>/<srcdir>/_build/<mt>/`); already-built upstreams are mounted as **prebuilt roots** `(prebuilt src obj)`. Compilation happens in-process — no subprocess is spawned.
- **path dependencies** `(path "../x")`: do not enter `_vendor`; their source directory is mounted live (edit a line, it takes effect immediately).
- **Library search**: `resolved-libdirs` mounts one `(src . obj)` pair per dependency — sources at `_vendor/<dep>/<srcdir>`, objects in that dependency's own `_build/<mt>`. There is no aggregated `lib/` any more.

### Native loading: self-loader first, universal load as fallback

`chandler build` generates a `(<lib> native-loader)` for every library that has native artifacts (product at `<obj>/<lib>/native-loader.so`); when that library's FFI is referenced, the loader locates and `dlopen`s the `.so` **itself** — and one of its candidates is the **object side** of `(library-directories)`, which is exactly where the per-dependency pairs mounted by `resolved-libdirs` drop native artifacts. So **mounting the pair is enough**, and it's **lazy** (no `dlopen` until the FFI is touched).

The pre-loading in `activate` / `run` / `repl` is therefore demoted to a **fallback**: only third-party libraries that lack a generated loader get scanned and loaded; libraries with `native-loader.so` are always skipped.

### Launching: always `chandler run`

```sh
chandler run --script main.ss [args...]
```

It hands over exactly one thing: the **library search paths** (`resolved-libdirs`'s per-dependency
`(src . obj)` pairs + path-dependency source dirs + the project's own library root + a global fallback).
After that, `(import (dep))` just resolves in your script.

**Resource lookup needs no environment variable**: `resource-path` / `find-resource-path` in
`(chandler runtime-paths)` scan both the src and obj side of `(library-directories)`
(`<side>/<libpath>/resources/<file>` — method B, resources co-located with library sources). Whichever
prefixes the process is running against, that's where its resources are — `APP_ROOT` is gone.

`.env` (project root) is consumed by `run` / `repl` / `env` (`.env` overrides the process environment); it
is deliberately **not** read by `build` / `deps` / `install`, which keeps those reproducible.

> Under `chandler test`, if `.env.tests` exists at the project root, `.env` is read first and then
> `.env.tests` overrides same-name keys — for pointing tests at another database or disabling side effects
> without polluting the development environment. `.env.tests` is consumed **only** by `chandler test`;
> `run` / `repl` / `exec` / `env` do not read it.

> Earlier versions generated a `chandler-setup.ss` (Bundler's `bundler/setup` style, `(load)`ed by the main
> script) and an `APP_ROOT` environment variable. Both are gone: there is exactly one way to start a
> program, and resources live in the same prefix as the libraries.
> To mount the same paths in another process use `eval "$(chandler env)"`; a script that already has
> `(chandler)` can just call `(activate)`.

### Library search rules (shared by run / env / repl / activate)

- **Project** (has lock + deps): one `(src . obj)` pair per dependency + path source dirs + the project's own library root + a global fallback (project wins, highest priority).
- **Non-project**: just the global prefix pair `~/.local/share/chez/src::~/.local/share/chez/<mt>`.

The global fallback mounts **one version per installed package**: for an `app` the `(active …)` version
(what `chandler switch` controls), for a `lib` the highest semver present on disk (see designs/06 §9.5).

## Command reference

| Command | Effect |
|---------|--------|
| `init [--lib\|--app] [--name=N]` | Scaffold `chandler-manifest.ss` + `chandler-tasks.ss` (lib by default; `--app` writes `(app …)` so it can be packed) |
| `add <name> <url> [--tag/--rev/--branch/--path]` | Add a dependency |
| `remove <name>` | Remove a dependency |
| `deps [--production] [--offline] [--force] [--update]` | Resolve → write lock → check out git deps into `_vendor/` + put the chandler runtime gate in place; `--list` shows locked deps, `--tree` shows them as a tree |
| `build [--allow-build[=a,b]]` | In-process compile of the dependency closure + native → each `_vendor/<dep>/_build/<mt>/` |
| `verify` | Check `_vendor/` matches the `(files …)` in `chandler-manifest.lock` (CI, read-only); mismatched/missing/extra → exit 65 |
| `list` | List globally installed packages (multi-version; the active one is tagged `[active]`) |
| `tree` | Alias for `deps --tree`: locked dependencies as a tree |
| `run <script.ss> [args…]` | Run a script with library search paths mounted |
| `exec -- <cmd…>` | Run a command with `CHEZSCHEMELIBDIRS` + `.env` set; exit code = subprocess exit code |
| `env` | Print `export CHEZSCHEMELIBDIRS=…` plus each `.env` key, for `eval "$(chandler env)"` |
| `repl [--runtime skiff\|chez]` | Interactive shell with library paths auto-mounted (project first, global fallback) |
| `make [task]` | Run a task from `chandler-tasks.ss` (default `build`); with no tasks file, derive from the manifest |
| `test [args…]` | Run `tests/run-tests.sps` (mounts project library paths + loads `.env` / `.env.tests` + selects a runtime); exit code = test process exit code |
| `install [--user\|--system\|--prefix=DIR]` | Install the project's libraries + dependencies into the global prefix (recorded in the central `.registry/`). **An app also gets a CLI entry point**: `~/.local/bin/<app>` (POSIX, stable shim) / `%LOCALAPPDATA%\chez\bin\<app>.ps1` (Windows). The first install sets active; several versions of one name coexist |
| `uninstall --name=<n> [--version=<v>]` | Clean uninstall (`rm -rf <vroot>` + update `.registry/`); removing the active version clears active |
| `switch <name> <version>` | **Switch an app's active version** (D19); `--latest` picks the highest by numeric semver; `--list` shows all active versions |
| `doctor` | Health-check the global prefix: `missing-vroot` / `missing-active` / `missing-runner` / `malformed-registry` / `orphan-vroot` / `kind-mismatch` / `name-filename-mismatch` / `duplicate-version` / `stale-staging` |
| `pack [--runtime r] [--out dir] [--lib]` | Assemble a self-contained distribution into `dist/<name>-<ver>-<mt>/` (payload goes through the same pipeline as install → `share/chez/`; the envelope lives in `bin/` + `lib/chez/` and bundles a runtime; `--lib` packs the payload only) |
| `verify-pack [--target] <dir>` | Verify a distribution: strict schema (`(format …)` must not exceed supported, `(files …)` must exist with `sha256`/`size` on every entry) + full hash/size comparison + undeclared files are a fatal `EXTRA`; `--target` also checks machine-type / chez-version / skiff-version |

Global flags: `-C <dir>` `--offline` `--production` `--force` `--keep-extra` `--verbose`.

## Pinning a runtime (skiff / chez)

"Which runtime" and "which executable" are separate concerns:

| Variable | Effect |
|----------|--------|
| `CHANDLER_HOME=<dir>` | Where chandler itself is installed (a src/mt prefix); `deps` copies the chandler runtime from here, and it is the global fallback in the search path. The launcher sets it automatically — you normally never touch it |
| `CHANDLER_RUNTIME=skiff\|chez` | Choose **which kind**, default skiff; an illegal value is an error (exit code 64), never silently ignored |
| `CHANDLER_SKIFF=<exe>` | The skiff executable (name or path) |
| `CHANDLER_SCHEME=<exe>` | The Chez executable (name or path) |

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
CHANDLER_RUNTIME=chez scheme --script bootstrap.ss   # run the install with Chez
skiff --script bootstrap.ss                          # run the install with skiff (default)
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

- **Manifests are `read`, not eval'd**: `chandler-manifest.ss` / `chandler-manifest.lock` / `.registry/` are pure data, never `eval`'d / `load`'d.
- **Zero execution during git clone/checkout**: every git invocation carries `-c core.hooksPath=/dev/null`.
- **Native build = RCE, requires explicit authorization**: native builds of dependencies (someone else's code) require `--allow-build`, and the authorization is **bound to the build-description hash** written to `.chandler-approvals` — a swapped script (description change) invalidates it and re-prompts.
- **rev is full-length locked = content-addressed**: materialization only honors the exact commit from the lock; tampering/replay is caught by git's object hash.

## Development

```sh
chandler test                                       # canonical entry: mounts library paths + native fallback + runtime + .env/.env.tests
scheme --libdirs . --program tests/run-tests.sps    # same, pure Chez, no external deps (manual: you mount paths yourself, no native fallback)
petite  --libdirs . --program tests/run-tests.sps   # same (Petite-subset check)
skiff   --libdirs . --program tests/run-tests.sps   # same (Skiff runtime)
bash tests/powershell-run.sh                        # Windows launcher acceptance (needs pwsh; skipped if absent)
```

`tests/powershell-run.sh` **renders the generated `chandler.ps1` and actually runs it under pwsh** (syntax / runtime enforcement / overrides / exit codes / arg passing / end-to-end launch) — because the generated script uses forward slashes and `[System.IO.Path]::PathSeparator` as the separator, the same script works under Linux's pwsh too. Install pwsh with `mise use powershell`.

The library layout follows the [library layout spec](designs/13-library-source-layout.md): an umbrella `chandler.ss` + a same-named subtree `chandler/`, with the search root = the repo root. The core only `import (chezscheme)`, restricted to the Petite-runnable subset (portable across both runtimes).

### Language conventions

- **All user-visible output is English**: CLI help, runtime hints/warnings/errors (`printf` / `fprintf` / `error` messages), and the headers of **generated files** (the parallel-compile worker, a pack's `run.sps`) — the tool's audience is not limited to Chinese readers. Style follows Unix diagnostic conventions: lowercase, terse, no trailing period, e.g. ``chandler-manifest.ss not found; run `chandler init` first``.
- **Source comments (`;;` / `;;;`) and this repo's docs are in Chinese**, for the expressive density that helps design reasoning.
- Plurals use `(plural n "dependency" "dependencies")` (from `(chandler util)`), avoiding `1 dependencies`.
