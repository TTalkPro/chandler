#!/usr/bin/env scheme-script
;;; bootstrap.ss — chandler installer (replaces install.sh / install.ps1)
;;;
;;; Self-contained: pure (chezscheme), zero chandler imports.
;;; Works even when chandler's libraries are broken (that's the point).
;;;
;;; Usage:
;;;   scheme --script bootstrap.ss              # install to ~/.local
;;;   skiff  --script bootstrap.ss              # install (skiff runtime)
;;;   scheme --script bootstrap.ss --global     # install to /usr/local (needs root)
;;;   scheme --script bootstrap.ss --force      # reinstall over existing
;;;   scheme --script bootstrap.ss --uninstall  # remove (--global matches install)
;;;
;;; The user chooses the runtime by invocation. No runtime discovery here —
;;; that lives in the GENERATED launcher (which this script writes).

(import (chezscheme))

;; ════════════════════════════════════════════════════════════════════
;; §1  Path helpers (minimal — no (chandler fs) dependency)
;; ════════════════════════════════════════════════════════════════════

(define (dirname path)
  (let loop ([i (- (string-length path) 1)])
    (cond [(< i 0) "."]
          [(char=? #\/ (string-ref path i)) (substring path 0 i)]
          [else (loop (- i 1))])))

(define (basename path)
  (let loop ([i (- (string-length path) 1)])
    (cond [(< i 0) path]
          [(char=? #\/ (string-ref path i)) (substring path (+ i 1) (string-length path))]
          [else (loop (- i 1))])))

(define (join-paths . parts)
  (fold-left (lambda (acc p)
               (cond [(or (string=? acc "") (string=? acc ".")) p]
                     [(char=? #\/ (string-ref acc (- (string-length acc) 1))) (string-append acc p)]
                     [else (string-append acc "/" p)]))
             ""
             parts))

(define (strip-prefix s pre)
  (let ([n (string-length pre)])
    (if (and (>= (string-length s) n) (string=? pre (substring s 0 n)))
        (substring s n (string-length s))
        s)))

(define (string-suffix? suf s)
  (let ([ls (string-length s)] [lf (string-length suf)])
    (and (>= ls lf) (string=? suf (substring s (- ls lf) ls)))))

(define (string-join lst sep)
  (if (null? lst) ""
      (fold-left (lambda (acc s) (string-append acc sep s)) (car lst) (cdr lst))))

(define (string-split s ch)
  (let loop ([i 0] [start 0] [acc '()])
    (cond [(= i (string-length s)) (reverse (if (> i start) (cons (substring s start i) acc) acc))]
          [(char=? (string-ref s i) ch) (loop (+ i 1) (+ i 1) (cons (substring s start i) acc))]
          [else (loop (+ i 1) start acc)])))

(define (string-contains? s sub)
  (let ([ls (string-length s)] [lsub (string-length sub)])
    (and (> lsub 0)
         (let loop ([i 0])
           (cond [(> (+ i lsub) ls) #f]
                 [(string=? sub (substring s i (+ i lsub))) #t]
                 [else (loop (+ i 1))])))))

;; ════════════════════════════════════════════════════════════════════
;; §2  File system helpers (minimal — no (chandler fs) dependency)
;; ════════════════════════════════════════════════════════════════════

(define (ensure-dir path)
  (unless (file-exists? path)
    (ensure-dir (dirname path))
    (mkdir path)))

(define (ensure-parent path) (ensure-dir (dirname path)))

(define (copy-file src dst)
  (ensure-parent dst)
  (when (file-exists? dst) (delete-file dst))
  (let ([in (open-file-input-port src)])
    (let ([out (open-file-output-port dst)])
      (let ([buf (make-bytevector 65536)])
        (let loop ()
          (let ([n (get-bytevector-n! in buf 0 (bytevector-length buf))])
            (unless (eof-object? n)
              (put-bytevector out buf 0 n)
              (loop)))))
      (close-port out))
    (close-port in)))

(define (write-text path content)
  (ensure-parent path)
  (call-with-output-file path
    (lambda (p) (put-string p content))
    'replace))

(define (files-under dir)
  (if (not (file-directory? dir))
      '()
      (let loop ([queue (list dir)] [acc '()])
        (if (null? queue)
            (reverse acc)
            (let* ([d (car queue)] [rest (cdr queue)])
              (let inner ([entries (directory-list d)] [q rest] [a acc])
                (if (null? entries)
                    (loop q a)
                    (let* ([e (car entries)] [p (join-paths d e)])
                      (if (file-directory? p)
                          (inner (cdr entries) (cons p q) a)
                          (inner (cdr entries) q (cons p a)))))))))))

(define (rm-rf path)
  (when (file-exists? path)
    (if (file-directory? path)
        (begin
          (for-each (lambda (e)
                      (unless (or (string=? e ".") (string=? e ".."))
                        (rm-rf (join-paths path e))))
                    (directory-list path))
          (delete-directory path))
        (delete-file path))))

(define (delete-if-exists p) (when (file-exists? p) (delete-file p)))

(define (sweep-empty-parents path)
  (let ([parent (dirname path)])
    (when (and (file-directory? parent)
               (not (string=? parent "/"))
               (null? (directory-list parent)))
      (delete-directory parent)
      (sweep-empty-parents parent))))

(define (mt-string) (symbol->string (machine-type)))

(define (so-ext)
  (let ([m (mt-string)])
    (cond [(string-suffix? "nt" m) "dll"]
          [(string-suffix? "osx" m) "dylib"]
          [else "so"])))

(define (win?) (string-suffix? "nt" (mt-string)))

;; ════════════════════════════════════════════════════════════════════
;; §3  Args + prefix resolution
;; ════════════════════════════════════════════════════════════════════

(define here (dirname (car (command-line))))
(define args (cdr (command-line)))
(define help? (and (member "--help" args) #t))
(define global? (and (member "--global" args) #t))
(define force? (and (member "--force" args) #t))
(define uninstall? (and (member "--uninstall" args) #t))

(define home (or (getenv "HOME") "."))
(define prefix
  (if global? "/usr/local/share/chez"
      (string-append home "/.local/share/chez")))
(define bindir
  (if global? "/usr/local/bin"
      (string-append home "/.local/bin")))
(define launcher-path
  (string-append bindir "/" (if (win?) "chandler.ps1" "chandler")))

;; ════════════════════════════════════════════════════════════════════
;; §4  Source install: chandler.ss + chandler/** → <prefix>/src/
;; ════════════════════════════════════════════════════════════════════

(define lib-extensions '(".chezscheme.sls" ".sls" ".ss" ".sc"))

(define (find-umbrella srcdir name)
  (let loop ([exts lib-extensions])
    (if (null? exts) #f
        (let ([p (join-paths srcdir (string-append name (car exts)))])
          (if (file-exists? p) p (loop (cdr exts)))))))

(define (install-sources!)
  (let ([src-dir (join-paths prefix "src")]
        [from-prefix (string-append here "/")])
    (ensure-dir src-dir)
    ;; umbrella
    (let ([umb (find-umbrella here "chandler")])
      (when umb
        (let ([dst (join-paths src-dir (basename umb))])
          (copy-file umb dst)
          (printf "install ~a~%" dst))))
    ;; subtree
    (let ([subtree (join-paths here "chandler")])
      (when (file-directory? subtree)
        (for-each
          (lambda (abs)
            (let* ([rel (strip-prefix abs from-prefix)]
                   [dst (join-paths src-dir rel)])
              (copy-file abs dst)))
          (files-under subtree))))))

;; ════════════════════════════════════════════════════════════════════
;; §4b  Manifest snapshot: manifest.ss → <prefix>/.chandler/chandler/
;;
;; Every library prefix records what it holds under .chandler/<name>/ (the same
;; shape a pack and a project's own lib/ use). For chandler this is load-bearing,
;; not decorative: a project declares `(chandler ">=X")` as a RUNTIME GATE — no
;; URL, nothing to fetch — and `chandler deps` answers "is the installed one new
;; enough?" by reading the version out of this snapshot.
;; ════════════════════════════════════════════════════════════════════

(define (install-manifest!)
  (let ([src (join-paths here "manifest.ss")]
        [dst (join-paths prefix ".chandler/chandler/manifest.ss")])
    (when (file-exists? src)
      (copy-file src dst)
      (printf "install ~a~%" dst))))

(define (uninstall-manifest!)
  (let ([d (join-paths prefix ".chandler/chandler")])
    (when (file-directory? d) (rm-rf d))))

;; ════════════════════════════════════════════════════════════════════
;; §5  Compiled objects: _build/<mt>/** → <prefix>/<mt>/
;; ════════════════════════════════════════════════════════════════════

(define (deliverable? rel)
  (and (not (string=? (basename rel) ".bake-manifest"))
       (not (string-suffix? ".wpo" rel))))

(define (install-objects!)
  (let* ([mt (mt-string)]
         [bdir (join-paths here "_build" mt)]
         [obj-dir (join-paths prefix mt)])
    (when (file-directory? bdir)
      (ensure-dir obj-dir)
      (let* ([bprefix (string-append bdir "/")]
             [nx (string-append "." (so-ext))])
        (for-each
          (lambda (abs)
            (let ([rel (strip-prefix abs bprefix)])
              (when (and (deliverable? rel)
                         (or (string-suffix? ".so" rel) (string-suffix? nx rel)))
                (let ([dst (join-paths obj-dir rel)])
                  (copy-file abs dst)
                  (printf "install ~a~%" dst)))))
          (files-under bdir))))))

;; ════════════════════════════════════════════════════════════════════
;; §6  Uninstall by namespace (no manifest needed)
;; ════════════════════════════════════════════════════════════════════

(define (uninstall-libraries!)
  (let* ([mt (mt-string)]
         [src-dir (join-paths prefix "src")]
         [obj-dir (join-paths prefix mt)])
    ;; src/chandler.{ext} + src/chandler/
    (let ([umb (find-umbrella src-dir "chandler")])
      (when (and umb (file-exists? umb))
        (delete-file umb) (sweep-empty-parents umb)))
    (let ([d (join-paths src-dir "chandler")])
      (when (file-directory? d) (rm-rf d)))
    ;; <mt>/chandler.so + <mt>/chandler/
    (delete-if-exists (join-paths obj-dir "chandler.so"))
    (let ([d (join-paths obj-dir "chandler")])
      (when (file-directory? d) (rm-rf d)))))

;; ════════════════════════════════════════════════════════════════════
;; §7  Launcher templates (runtime discovery: skiff → Chez)
;; ════════════════════════════════════════════════════════════════════

(define self-runtimes "skiff scheme chez chez-scheme chezscheme")
(define self-probe-token "CHANDLER_RT_OK")
(define chez-names '("scheme" "chez" "chez-scheme" "chezscheme"))

(define self-probe-src
  (string-append
    "(import (chezscheme))(display \"" self-probe-token ":\")"
    "(display (let ([s (string->symbol \"skiff-version\")])"
    " (if (top-level-bound? s)"
    " (let ([v (top-level-value s)]) (if (procedure? v) (v) v))"
    " \"\")))"))

(define (ps1-list names)
  (string-join (map (lambda (r) (string-append "'" r "'")) names) ","))

(define (launcher-sh)
  (string-append
    "#!/bin/sh\n"
    "# chandler launcher — generated by bootstrap.ss; do not edit.\n"
    "# Prefer skiff, fall back to Chez scheme. Non-Chez runtimes must pass a\n"
    "# capability probe. CHANDLER_RUNTIME=skiff|chez forces one.\n"
    "CHANDLER_PREFIX=\"" prefix "\"\n"
    "CHANDLER_MT=\"" (mt-string) "\"\n"
    "export CHANDLER_PREFIX CHANDLER_MT\n"
    "_main=\"$CHANDLER_PREFIX/src/chandler/cli/main.sps\"\n"
    "if [ ! -f \"$_main\" ]; then\n"
    "  echo \"chandler: install is broken — $_main is missing.\" 1>&2\n"
    "  echo \"  Reinstall from source:  scheme --script bootstrap.ss\" 1>&2\n"
    "  echo \"  Or remove this orphan launcher:  rm \\\"$0\\\"\" 1>&2\n"
    "  exit 70\n"
    "fi\n"
    "_prog_ok() {\n"
    "  printf '%s' '" self-probe-src "' \\\n"
    "    | \"$1\" -q --program /dev/stdin 2>/dev/null | grep -q '" self-probe-token ":[0-9]'\n"
    "}\n"
    "case \"${CHANDLER_RUNTIME:-}\" in\n"
    "  skiff) _cands=\"${CHANDLER_SKIFF:-skiff}\"; _forced=1 ;;\n"
    "  chez)  if [ -n \"${CHANDLER_SCHEME:-}\" ]; then _cands=\"$CHANDLER_SCHEME\";\n"
    "         else _cands=\"" (string-join chez-names " ") "\"; fi; _forced=1 ;;\n"
    "  \"\")   _cands=\"" self-runtimes "\"; _forced=0 ;;\n"
    "  *) echo \"chandler: invalid CHANDLER_RUNTIME=$CHANDLER_RUNTIME (want: skiff | chez)\" 1>&2; exit 64 ;;\n"
    "esac\n"
    "for rt in $_cands; do\n"
    "  command -v \"$rt\" >/dev/null 2>&1 || continue\n"
    "  if [ \"$_forced\" -eq 0 ]; then\n"
    "    case \"$rt\" in\n"
    "      " (string-join chez-names "|") ") : ;;\n"
    "      *) _prog_ok \"$rt\" || continue ;;\n"
    "    esac\n"
    "  fi\n"
    "  exec \"$rt\" -q --libdirs \"$CHANDLER_PREFIX/src::$CHANDLER_PREFIX/$CHANDLER_MT\" \\\n"
    "    --program \"$_main\" \"$@\"\n"
    "done\n"
    "echo \"chandler: no program-capable Scheme runtime found (need skiff or Chez Scheme).\" 1>&2\n"
    "exit 127\n"))

(define (launcher-ps1)
  (string-append
    "#!/usr/bin/env pwsh\n"
    "# chandler launcher — generated by bootstrap.ss; do not edit.\n"
    "$PSNativeCommandUseErrorActionPreference = $false\n"
    "$ErrorActionPreference = 'Continue'\n"
    "$ChandlerArgs = $args\n"
    "$Prefix = '" prefix "'\n"
    "$Mt = '" (mt-string) "'\n"
    "$env:CHANDLER_PREFIX = $Prefix\n"
    "$env:CHANDLER_MT = $Mt\n"
    "$Sep = [System.IO.Path]::PathSeparator\n"
    "$LibDirs = \"$Prefix/src$Sep$Sep$Prefix/$Mt\"\n"
    "$Program = \"$Prefix/src/chandler/cli/main.sps\"\n"
    "if (-not (Test-Path -LiteralPath $Program)) {\n"
    "  [Console]::Error.WriteLine(\"chandler: install is broken — $Program is missing.\")\n"
    "  [Console]::Error.WriteLine(\"  Reinstall from source:  scheme --script bootstrap.ss\")\n"
    "  exit 70\n"
    "}\n"
    "\n"
    "function Test-ChandlerRuntime([string]$Exe, [string]$Probe) {\n"
    "  if (-not $Probe) { return $true }\n"
    "  $out = $null | & $Exe -q --program $Probe 2>$null\n"
    "  if ($LASTEXITCODE -ne 0) { return $false }\n"
    "  return (($out -join ' ') -match '" self-probe-token ":\\d')\n"
    "}\n"
    "\n"
    "$Forced = $false\n"
    "switch ($env:CHANDLER_RUNTIME) {\n"
    "  'skiff' { $Cands = @($(if ($env:CHANDLER_SKIFF) { $env:CHANDLER_SKIFF } else { 'skiff' })); $Forced = $true }\n"
    "  'chez'  { $Cands = $(if ($env:CHANDLER_SCHEME) { @($env:CHANDLER_SCHEME) } else { @(" (ps1-list chez-names) ") }); $Forced = $true }\n"
    "  ''      { $Cands = @(" (ps1-list (string-split self-runtimes #\space)) ") }\n"
    "  $null   { $Cands = @(" (ps1-list (string-split self-runtimes #\space)) ") }\n"
    "  default {\n"
    "    [Console]::Error.WriteLine(\"chandler: invalid CHANDLER_RUNTIME=$($env:CHANDLER_RUNTIME) (want: skiff | chez)\")\n"
    "    exit 64\n"
    "  }\n"
    "}\n"
    "\n"
    "$probe = Join-Path ([System.IO.Path]::GetTempPath()) \"chandler-probe-$PID.ss\"\n"
    "try { Set-Content -LiteralPath $probe -Value '" self-probe-src "' -Encoding ascii }\n"
    "catch { $probe = $null }\n"
    "try {\n"
    "  foreach ($rt in $Cands) {\n"
    "    $exe = $null\n"
    "    $c = Get-Command $rt -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1\n"
    "    if ($c) { $exe = $c.Source }\n"
    "    elseif (Test-Path -LiteralPath $rt) { $exe = (Resolve-Path -LiteralPath $rt).Path }\n"
    "    if (-not $exe) { continue }\n"
    "    if (-not $Forced -and ($rt -notin @(" (ps1-list chez-names) "))) {\n"
    "      if (-not (Test-ChandlerRuntime $exe $probe)) { continue }\n"
    "    }\n"
    "    & $exe -q --libdirs $LibDirs --program $Program @ChandlerArgs\n"
    "    exit $LASTEXITCODE\n"
    "  }\n"
    "} finally {\n"
    "  if ($probe -and (Test-Path -LiteralPath $probe)) {\n"
    "    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue\n"
    "  }\n"
    "}\n"
    "[Console]::Error.WriteLine(\"chandler: no program-capable Scheme runtime found (need skiff or Chez Scheme).\")\n"
    "exit 127\n"))

;; ════════════════════════════════════════════════════════════════════
;; §8  Install / Uninstall
;; ════════════════════════════════════════════════════════════════════

(define (do-install!)
  (when force? (uninstall-libraries!))
  (install-sources!)
  (install-manifest!)
  (install-objects!)
  (write-text launcher-path (if (win?) (launcher-ps1) (launcher-sh)))
  (unless (win?)
    (let ([chmod-result (system (string-append "chmod +x " launcher-path))])
      (void)))
  (printf "install ~a~%" launcher-path)
  (printf "chandler installed to ~a~%" prefix)
  (let ([p (or (getenv "PATH") "")])
    (unless (string-contains? p bindir)  ; best-effort substring check
      (printf "  hint: add ~a to PATH: export PATH=\"~a:$PATH\"~%" bindir bindir)))
  (exit 0))

(define (do-uninstall!)
  (uninstall-libraries!)
  (uninstall-manifest!)
  (when (file-exists? launcher-path)
    (delete-file launcher-path) (sweep-empty-parents launcher-path)
    (printf "rm ~a~%" launcher-path))
  (printf "chandler uninstalled from ~a~%" prefix)
  (exit 0))

;; ════════════════════════════════════════════════════════════════════
;; §9  Help / Main
;; ════════════════════════════════════════════════════════════════════

(define (print-help)
  (display "chandler bootstrap — self-contained installer (replaces install.sh/ps1)\n\n")
  (display "Usage: scheme --script bootstrap.ss [options]\n")
  (display "       skiff  --script bootstrap.ss [options]\n\n")
  (display "Options:\n")
  (display "  (none)        Install chandler to ~/.local/share/chez + launcher to ~/.local/bin\n")
  (display "  --global      Install to /usr/local/share/chez + /usr/local/bin (needs root)\n")
  (display "  --force       Reinstall over existing (uninstall first, then install)\n")
  (display "  --uninstall   Remove chandler (use with --global if installed that way)\n")
  (display "  --help        Show this help and exit\n\n")
  (display "The user chooses the runtime by invocation (scheme vs skiff).\n")
  (display "The generated launcher does its own runtime discovery (skiff → Chez).\n\n")
  (display "Files installed:\n")
  (display "  <prefix>/src/chandler.ss + chandler/**   source\n")
  (display "  <prefix>/<mt>/chandler.so + chandler/**   compiled objects (if _build/ exists)\n")
  (display "  <bindir>/chandler[.ps1]                   runtime-discovery launcher\n"))

(cond
  [help? (print-help)]
  [uninstall? (do-uninstall!)]
  [else (do-install!)])
