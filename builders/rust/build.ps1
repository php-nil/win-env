<#
.SYNOPSIS
    Build the Rust MSVC one-click installer for Windows x64.

.DESCRIPTION
    - Resolves the latest stable Rust release via channel-rust-stable.toml
      (no hardcoded patch versions). A pinned version is resolved from its own
      immutable channel-rust-<version>.toml, never by rewriting stable URLs.
    - Downloads the official `default` profile components (rustc / cargo /
      rust-std / rust-docs / rustfmt-preview / clippy-preview) for
      x86_64-pc-windows-msvc and verifies every archive against the SHA-256
      published in the channel TOML before using it.
    - Uses the LLD linker bundled inside the rustc component (the rust-lld
      universal driver; the gcc-ld flavor wrappers are not used) — no separate
      LLVM download.
    - Downloads xwin and extracts Windows SDK / CRT headers and libraries.
    - Stages a unified tree at build/stage/rust (equals C:\pf\rust after install).
    - Runs mandatory smoke test: staged rustc/cargo/rustfmt must report exact
      versions, and a real `cargo build`, `cargo fmt --check` and `cargo clippy`
      must all succeed.
    - Compiles an Inno Setup installer which installs to C:\pf\rust by default,
      puts the install dir on the system PATH and mirrors official rustup's
      %USERPROFILE%\.cargo\bin entry on the user PATH.

.PARAMETER RustVersion
    Exact Rust version without leading 'v', e.g. 1.90.0.
    Empty = newest stable release in the official channel TOML.

.PARAMETER BuildDir
    Working directory for cache, staging and output. Default: <repo>\build.

.PARAMETER SkipCompile
    Only resolve/download/assemble; do not invoke the Inno Setup compiler.
#>
[CmdletBinding()]
param(
    [string]$RustVersion = '',
    [string]$BuildDir    = '',
    [switch]$SkipCompile
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path
if (-not $BuildDir) { $BuildDir = Join-Path $RepoRoot 'build' }

$CacheDir = Join-Path $BuildDir 'cache'
$StageDir = Join-Path $BuildDir 'stage\rust'
$OutDir   = Join-Path $BuildDir 'output'

$ChannelUrl = 'https://static.rust-lang.org/dist/channel-rust-stable.toml'
$Target     = 'x86_64-pc-windows-msvc'

# LLD comes from the rustc component itself (no LLVM download): rustc ships a
# self-contained LLD whose universal driver is rust-lld.exe (the gcc-ld\*.exe
# files are per-flavor wrappers around it). See section 4 below.

# xwin release to pull SDK extraction tool from.
# Auto-discover latest from GitHub API; avoids hardcoding a version that may
# get removed (old tags get pruned). Download the .tar.gz Windows MSVC build.
# The GitHub API requires a User-Agent and rate-limits anonymous calls to 60/h
# per IP; shared runner IPs routinely get 403. GITHUB_TOKEN (supplied by the
# workflow) is only used to raise that limit — it is never logged.
Write-Host 'Discovering latest xwin release...'
try {
    $ghHeaders = @{ 'User-Agent' = 'win-env-rust-builder' }
    if ($env:GITHUB_TOKEN) { $ghHeaders['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
    $xwinLatest = Invoke-RestMethod -UseBasicParsing -Headers $ghHeaders `
        -Uri 'https://api.github.com/repos/Jake-Shadle/xwin/releases/latest'
    $XwinVersion = $xwinLatest.tag_name
    $xwinAssetObj = $xwinLatest.assets | Where-Object {
        $_.name -match 'x86_64-pc-windows-msvc\.tar\.gz$'
    } | Select-Object -First 1
    if (-not $xwinAssetObj) { throw 'No Windows MSVC tar.gz asset found' }
    $XwinAsset = $xwinAssetObj.name
    $XwinUrl   = $xwinAssetObj.browser_download_url
    # Every xwin asset ships a sibling "<asset>.sha256" containing the digest.
    $xwinShaObj = $xwinLatest.assets | Where-Object { $_.name -eq "$XwinAsset.sha256" } | Select-Object -First 1
    $XwinSha256 = $null
    if ($xwinShaObj) {
        $rawSha = [string](Invoke-RestMethod -UseBasicParsing -Headers $ghHeaders -Uri $xwinShaObj.browser_download_url)
        $XwinSha256 = (($rawSha.Trim() -split '\s+')[0]).ToLower()
        if ($XwinSha256 -notmatch '^[0-9a-f]{64}$') { throw "Unexpected .sha256 asset payload: $rawSha" }
    }
    Write-Host "  xwin $XwinVersion => $XwinAsset (sha256 published: $([bool]$XwinSha256))"
}
catch {
    throw "Failed to discover xwin latest release: $_"
}

function Write-Step([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

function Test-FileSha256([string]$Path, [string]$Sha256) {
    if (-not $Sha256) { return $true }
    if (-not (Test-Path $Path)) { return $false }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLower()
    return ($actual -eq $Sha256.ToLower())
}

# Download with retries. When an expected SHA-256 is supplied both the cached
# file and every fresh download are verified: a truncated cache entry (e.g. an
# interrupted earlier run) is deleted and re-fetched instead of silently
# poisoning all later builds.
function Download-File([string]$url, [string]$dest, [string]$sha256 = '') {
    if ((Test-Path $dest) -and ((Get-Item $dest).Length -gt 0)) {
        if (Test-FileSha256 $dest $sha256) {
            Write-Host "  cached: $dest"
            return
        }
        Write-Host "  cached file failed SHA-256 check, discarding: $dest"
        Remove-Item -Force $dest
    }
    $attempts = 3
    for ($i = 1; $i -le $attempts; $i++) {
        try {
            Write-Host "  downloading ($i/$attempts): $url"
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $dest
            if (-not (Test-Path $dest) -or (Get-Item $dest).Length -eq 0) { throw 'downloaded file is empty' }
            if (-not (Test-FileSha256 $dest $sha256)) { throw "SHA-256 mismatch: $url" }
            return
        }
        catch {
            Remove-Item -Force $dest -ErrorAction SilentlyContinue
            if ($i -eq $attempts) { throw }
            Start-Sleep -Seconds (3 * $i)
        }
    }
}

# ---------------------------------------------------------------------------
# 1. Resolve Rust version + component URLs/hashes from the official channel TOML
#    PS 5.1 has no TOML parser, so the file is scanned line by line:
#      - top-level `date` = channel date
#      - `[pkg.rust].version` = "X.Y.Z (commit date)" → take X.Y.Z
#      - each component has a per-target section with `url` + `hash`
#    channel-rust-stable.toml only describes the CURRENT release, so a pinned
#    version is resolved from its own immutable channel-rust-<version>.toml
#    (which carries the matching date dir + hashes). The previous "rewrite the
#    stable URL with the pinned version number" trick produced a 404 for every
#    release that was not the current stable one.
# ---------------------------------------------------------------------------
function Get-ChannelInfo([string]$Url) {
    Write-Host "  reading $Url"
    $content = Invoke-RestMethod -Uri $Url -UseBasicParsing -ErrorAction Stop
    if (-not $content) { throw "Empty channel TOML from $Url" }

    $info = [ordered]@{ Version = $null; Date = $null; Urls = @{}; Hashes = @{} }
    $currentSection = ''
    foreach ($rawLine in ($content -split "`n")) {
        $line = $rawLine.Trim()
        if (-not $line) { continue }

        # Section headers. The live channel TOML (verified 2026-11-08) uses
        # plain [table] for per-target entries, but [[array-of-tables]] is
        # accepted too so an upstream serialization change cannot silently
        # break parsing.
        if ($line -match '^\[+(.+?)\]+$') {
            $currentSection = $Matches[1]
            continue
        }

        if ($currentSection -eq '' -and $line -match '^date\s*=\s*"([^"]+)"') {
            $info.Date = $Matches[1]
            continue
        }
        if ($currentSection -eq 'pkg.rust' -and $line -match '^version\s*=\s*"(\d+\.\d+\.\d+)') {
            $info.Version = $Matches[1]
            continue
        }

        if ($currentSection -match ('^pkg\.(?<comp>rustc|cargo|rust-std|rust-docs|clippy-preview|rustfmt-preview)\.target\.' + [regex]::Escape($Target) + '$')) {
            # Capture the component name NOW — the url/hash regexes below
            # overwrite $Matches.
            $comp = $Matches['comp']
            if ($line -match '^url\s*=\s*"([^"]+\.tar\.gz)"') {
                $info.Urls[$comp] = $Matches[1]
            }
            elseif ($line -match '^hash\s*=\s*"([0-9a-fA-F]{64})"') {
                $info.Hashes[$comp] = $Matches[1].ToLower()
            }
        }
    }
    return [pscustomobject]$info
}

Write-Step 'Resolving Rust release from the official channel TOML'
$channelUrlUsed = $ChannelUrl
$channel = Get-ChannelInfo $ChannelUrl
if (-not $channel.Version) { throw "Could not parse rust version from $ChannelUrl" }
if (-not $channel.Date)    { throw "Could not parse channel date from $ChannelUrl" }

if ($RustVersion) {
    if ($RustVersion -notmatch '^\d+\.\d+\.\d+$') { throw "Invalid -RustVersion: $RustVersion" }
    if ($RustVersion -ne $channel.Version) {
        $channelUrlUsed = "https://static.rust-lang.org/dist/channel-rust-$RustVersion.toml"
        try { $channel = Get-ChannelInfo $channelUrlUsed }
        catch { throw "Rust $RustVersion is not a released version ($channelUrlUsed): $($_.Exception.Message)" }
        if ($channel.Version -ne $RustVersion) {
            throw "Pinned channel TOML reports $($channel.Version), expected $RustVersion ($channelUrlUsed)"
        }
    }
}

$rustVersion = $channel.Version
$rustDate    = $channel.Date
Write-Host "  Rust version : $rustVersion (channel date: $rustDate)"

# Official `[profiles] default` for this target is rustc + cargo + rust-std +
# rust-docs + rustfmt-preview + clippy-preview. (rust-mingw is listed in every
# profile but has NO x86_64-pc-windows-msvc target section, so rustup cannot
# install it on an MSVC host either — verified against the live channel TOML.)
# Keep this list in lock-step with the official default profile: omitting
# rust-docs made the package diverge from `rustup default stable`.
$componentNames = @('rustc', 'cargo', 'rust-std', 'rust-docs', 'clippy-preview', 'rustfmt-preview')
$components = @()
foreach ($name in $componentNames) {
    $url  = $channel.Urls[$name]
    $hash = $channel.Hashes[$name]
    if (-not $url) { throw "Could not resolve $name URL for target $Target" }
    if (-not $hash) { Write-Host "  WARNING: $name has no hash in the channel TOML; download will be unverified" }
    # rustc MUST stay first: it seeds the stage tree with a mirroring copy
    # (/MIR), every following component overlays (/E).
    $components += @{ Name = $name; Url = $url; Sha256 = $hash }
}
# Channel component names are also the archive's inner payload directory name
# (verified for rustfmt-preview / clippy-preview), while the archive FILE names
# drop the "-preview" suffix — we never rebuild file names, the URL and its
# SHA-256 come straight from the channel TOML.

# ---------------------------------------------------------------------------
# 2. Download all assets
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $CacheDir, $OutDir | Out-Null
if (Test-Path $StageDir) { Remove-Item -Recurse -Force $StageDir }
New-Item -ItemType Directory -Force -Path $StageDir | Out-Null

foreach ($comp in $components) {
    $dest = Join-Path $CacheDir ([IO.Path]::GetFileName($comp.Url))
    Write-Step "Downloading $($comp.Name)"
    Download-File $comp.Url $dest $comp.Sha256
    $comp['LocalPath'] = $dest
}

Write-Step 'Downloading xwin (for SDK extraction)'
$xwinDest = Join-Path $CacheDir $XwinAsset
Download-File $XwinUrl $xwinDest $XwinSha256

# ---------------------------------------------------------------------------
# 3. Extract Rust components and merge into stage
# ---------------------------------------------------------------------------
Write-Step 'Extracting Rust components'
$tar = 'C:\Windows\System32\tar.exe'
if (-not (Test-Path $tar)) { throw "tar.exe not found at $tar (Windows 10+ ships it)" }
foreach ($comp in $components) {
    $tmpDir = Join-Path $CacheDir "extract-$($comp.Name)"
    if (Test-Path $tmpDir) { Remove-Item -Recurse -Force $tmpDir }
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    & $tar -xf $comp.LocalPath -C $tmpDir
    if ($LASTEXITCODE -ne 0) { throw "tar extraction failed for $($comp.Name)" }
    # Each archive contains a single inner directory like rustc-<ver>-<target>/
    # Inside THAT is the actual component subdirectory (rustc/, cargo/, rust-std/)
    # which holds bin/, lib/, etc. We need to merge the component dir itself,
    # not the version wrapper dir — otherwise StageDir ends up with nested
    # paths like StageDir\rustc\bin\rustc.exe instead of StageDir\bin\rustc.exe.
    $versionDir = Get-ChildItem -Directory $tmpDir | Select-Object -First 1
    if (-not $versionDir) { throw "No inner directory in $($comp.Name) archive" }
    # The payload lives in ONE subdirectory of the version dir. Its name equals
    # the component name for rustc/cargo, but is target-suffixed for rust-std
    # (rust-std-x86_64-pc-windows-msvc). Pick it generically: merging the version
    # dir itself nests the payload one level too deep, and rustc then cannot
    # find std (error E0463: can't find crate for `std`).
    $innerDir = Get-ChildItem -Directory $versionDir.FullName |
        Where-Object { $_.Name -eq $comp.Name -or $_.Name -like "$($comp.Name)-*" } |
        Select-Object -First 1
    if (-not $innerDir) {
        $innerDir = Get-ChildItem -Directory $versionDir.FullName | Select-Object -First 1
    }
    $compDir = if ($innerDir) { $innerDir.FullName } else { $versionDir.FullName }
    Write-Host "  merging from: $compDir"
    # First component mirrors (to clear stage), subsequent components overlay.
    $rcMode = if ($comp.Name -eq 'rustc') { '/MIR' } else { '/E' }
    $rcArgs = @($compDir, $StageDir, $rcMode, '/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NS')
    $rcProc = Start-Process -FilePath 'robocopy.exe' -ArgumentList $rcArgs -Wait -PassThru -NoNewWindow
    if ($rcProc.ExitCode -ge 8) { throw "robocopy merge failed for $($comp.Name) with exit code $($rcProc.ExitCode)" }
    Remove-Item -Recurse -Force $tmpDir
}

# Verify core binaries exist
$rustcExe = Join-Path $StageDir 'bin\rustc.exe'
$cargoExe = Join-Path $StageDir 'bin\cargo.exe'
if (-not (Test-Path $rustcExe)) { throw "rustc.exe missing after merge" }
if (-not (Test-Path $cargoExe)) { throw "cargo.exe missing after merge" }
# rustfmt / clippy land in bin\ exactly like official rustup installs them
# (verified against the real `-preview` archives; their manifest.in also lists
# the bundled .pdb files, so a full-copy merge matches official content). cargo's
# external-subcommand lookup finds bin\cargo-fmt.exe and bin\cargo-clippy.exe
# through PATH, so they must live in the same bin\ that goes onto the system PATH.
foreach ($rel in @('bin\rustfmt.exe', 'bin\cargo-fmt.exe', 'bin\cargo-clippy.exe', 'bin\clippy-driver.exe')) {
    $p = Join-Path $StageDir $rel
    if (-not (Test-Path $p)) { throw "$rel missing after merge (rustfmt/clippy component)" }
}
# Fail fast if rust-std landed at the wrong level. rustc's sysroot is the parent
# of bin\, so std must sit at lib\rustlib\<target>\lib. Checking here turns a
# cryptic `E0463: can't find crate for std` at cargo-build time into a clear error.
$stdLibDir = Join-Path $StageDir "lib\rustlib\$Target\lib"
if (-not (Test-Path $stdLibDir)) {
    $tree = (Get-ChildItem -Recurse -Depth 2 $StageDir -Directory | Select-Object -First 30 |
        ForEach-Object { $_.FullName.Replace($StageDir, '') }) -join "`n"
    throw "rust-std not staged at $stdLibDir - merge produced wrong layout. Dirs under stage:`n$tree"
}
# rust-docs is part of the official default profile; without it the local HTML
# books (the `rustup doc` equivalent) would be missing.
$docsHtmlDir = Join-Path $StageDir 'share\doc\rust\html'
if (-not (Test-Path $docsHtmlDir)) { throw "rust-docs payload missing: $docsHtmlDir" }

# ---------------------------------------------------------------------------
# 3b. Drop debug symbols for tools this package never invokes.
#     The rustc component ships per-flavor LLD PDBs (ld.lld / ld64.lld /
#     wasm-ld / lld-link) plus one for wasm-component-ld. This package only
#     runs the lld-link flavor, and an MSVC-only install cannot emit ELF /
#     Mach-O / wasm output at all, so those four PDBs are provably dead weight
#     (19,906,560 bytes / 18.98 MiB uncompressed at 1.99.1). Everything else in
#     the official
#     default profile is kept byte-for-byte — in particular rustc / rustdoc /
#     lld-link PDBs stay, so ICE backtraces and linker debugging keep working.
# ---------------------------------------------------------------------------
$deadPdb = @(
    "lib\rustlib\$Target\bin\gcc-ld\ld.lld.pdb",
    "lib\rustlib\$Target\bin\gcc-ld\ld64.lld.pdb",
    "lib\rustlib\$Target\bin\gcc-ld\wasm-ld.pdb",
    "lib\rustlib\$Target\bin\wasm-component-ld.pdb"
)
$prunedPdbBytes = 0
$prunedPdbCount = 0
foreach ($rel in $deadPdb) {
    $p = Join-Path $StageDir $rel
    if (Test-Path $p) {
        $prunedPdbBytes += (Get-Item $p).Length
        Remove-Item -Force $p
        $prunedPdbCount++
    }
}
Write-Host ("  pruned {0} unused linker/wasm PDB(s), {1:N0} bytes" -f $prunedPdbCount, $prunedPdbBytes)
if ($prunedPdbCount -ne $deadPdb.Count) {
    Write-Host "  WARNING: expected $($deadPdb.Count) prunable PDBs, found $prunedPdbCount — upstream layout may have changed"
}

# ---------------------------------------------------------------------------
# 4. Locate the LLD linker bundled with the rustc component
#    rustc ships a self-contained LLD at
#      lib\rustlib\<target>\bin\rust-lld.exe
#    (the universal driver; gcc-ld\{ld.lld,ld64.lld,wasm-ld,lld-link}.exe are
#    thin flavor wrappers around it).
#
#    The linker configured for cargo MUST be rust-lld.exe, NOT gcc-ld\lld-link.exe.
#    rustc detects LLD by the linker file name and prepends "-flavor link" itself;
#    the gcc-ld wrapper prepends its own "-flavor link" on top of the caller's
#    arguments, so rust-lld receives the flavor twice. The second pair is then
#    forwarded to the already-selected COFF driver, which warns
#    "ignoring unknown argument '-flavor'" and treats the bare word "link" as an
#    input file ("could not open 'link'"). Pointing at the universal driver is the
#    one layout where rustc's "-flavor link" (argv[1]) is consumed correctly.
#    Verified locally with rustc 1.99.1: wrapper => link failure, driver => OK.
#    This removes the former LLVM download, the 7-Zip dependency and the
#    hardcoded LLVM version, and keeps LLD version-aligned with rustc.
# ---------------------------------------------------------------------------
Write-Step 'Locating bundled LLD (rust-lld universal driver)'
$rustLldDir = Join-Path $StageDir "lib\rustlib\$Target\bin"
$rustLld    = Join-Path $rustLldDir 'rust-lld.exe'
if (-not (Test-Path $rustLld)) { throw "Bundled rust-lld driver missing: $rustLld" }
$rustLldRel = $rustLld.Substring($StageDir.Length).TrimStart('\')
Write-Host "  rust-lld : $rustLldRel"

# ---------------------------------------------------------------------------
# 5. Extract Windows SDK via xwin
# ---------------------------------------------------------------------------
Write-Step 'Extracting Windows SDK via xwin'
$xwinTmp = Join-Path $CacheDir 'extract-xwin'
if (Test-Path $xwinTmp) { Remove-Item -Recurse -Force $xwinTmp }
New-Item -ItemType Directory -Force -Path $xwinTmp | Out-Null
& tar -xzf $xwinDest -C $xwinTmp
if ($LASTEXITCODE -ne 0) { throw "tar failed to extract xwin archive (exit code $LASTEXITCODE)" }
$xwinExe = Get-ChildItem -Recurse -Filter 'xwin.exe' $xwinTmp | Select-Object -First 1
if (-not $xwinExe) { throw "xwin.exe not found in archive" }

# xwin writes its crt/ and sdk/ trees directly under the install root, so the
# final layout is {app}\crt\lib\<arch> and {app}\sdk\lib\{ucrt,um}\<arch>.
# This matches the default lib paths defined in setup.iss exactly.
$sdkRoot = $StageDir
# xwin CLI confirmed against 0.10.0 source: --accept-license is a global arg,
# `splat` is a subcommand with --output; splat auto-runs download + unpack.
# Cache/unpack/output MUST live on the same drive: splat moves files (rename)
# from the unpack dir to the output dir, and a cross-drive move fails with
# os error 17. Pointing --cache-dir at build\cache keeps everything on the
# same drive as the stage tree, stays inside the gitignored build dir, and
# survives re-runs (downloaded packages are reused). Do NOT use --temp: it
# unpacks to %TEMP% (C: drive on runners) and the move to D: fails.
# NOTE: on Windows xwin's `symlink()` helper is a no-op, BUT
# `symlink_on_windows_too` is not: it still creates `sdk\lib\<sdkversion>` and
# `sdk\include\<sdkversion>` as *directory* links pointing at their own parent
# (".\"). These survive --disable-symlinks (they are created outside that
# guard) and are stripped by the reparse-point pass right below, since Inno
# Setup cannot walk them (see section 5b).
$xwinCache = Join-Path $CacheDir 'xwin'
& $xwinExe.FullName --accept-license --cache-dir $xwinCache splat --output $sdkRoot
if ($LASTEXITCODE -ne 0) { throw "xwin SDK extraction failed with exit code $LASTEXITCODE" }
Remove-Item -Recurse -Force $xwinTmp

# Verify SDK structure. Layout confirmed from xwin 0.10.0 splat source:
#   <out>\crt\include\                VC/STL headers
#   <out>\crt\lib\<arch>\             VC CRT libs (msvcrt.lib, vcruntime.lib)
#   <out>\sdk\include\{um,shared}\    Windows SDK headers
#   <out>\sdk\include\ucrt\           UCRT headers
#   <out>\sdk\lib\um\<arch>\          Windows SDK import libs (kernel32.lib)
#   <out>\sdk\lib\ucrt\<arch>\        UCRT import libs (ucrt.lib)
$hasCrt = Test-Path (Join-Path $sdkRoot 'crt')
$hasSdk = Test-Path (Join-Path $sdkRoot 'sdk')
if (-not ($hasCrt -and $hasSdk)) {
    $tree = (Get-ChildItem -Recurse -Depth 2 $sdkRoot | Select-Object -First 40 | ForEach-Object { $_.FullName.Replace($sdkRoot, '') }) -join "`n"
    throw "xwin output structure unexpected. Top-level entries:`n$tree"
}

# ---------------------------------------------------------------------------
# 5b. Strip reparse points (xwin's versioned SDK alias links)
#     Guard against a hard-to-diagnose Inno Setup abort: ISCC's [Files]
#     recursion follows `sdk\lib\<sdkversion>` (`symlink_on_windows_too` points
#     it at its own parent directory "."), loops back into the parent, blows
#     past the path limit and dies with a line-less
#         Error in <setup.iss>: The system cannot find the path specified.
#     exit code 2 — reproduced locally with ISCC 6.7 against the same tree.
#     setup.iss only ever uses the unversioned sdk paths, so these aliases are
#     dead weight; drop every reparse point so the tree Inno sees is link-free.
#     Directory links are deleted *non-recursively* ([IO.Directory]::Delete with
#     recursive=$false) so the link target's contents are never touched.
# ---------------------------------------------------------------------------
Write-Step 'Stripping reparse points (symlinks/junctions) from the staged tree'
$reparse = @(Get-ChildItem -LiteralPath $StageDir -Recurse -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
    Sort-Object { $_.FullName.Length } -Descending)
foreach ($rp in $reparse) {
    Write-Host "  removing link: $($rp.FullName.Substring($StageDir.Length))"
    if ($rp.Attributes -band [IO.FileAttributes]::Directory) {
        [IO.Directory]::Delete($rp.FullName, $false)
    }
    else {
        [IO.File]::Delete($rp.FullName)
    }
}
Write-Host "  removed $($reparse.Count) reparse point(s)"
$left = @(Get-ChildItem -LiteralPath $StageDir -Recurse -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
if ($left.Count) {
    throw "Stage tree still contains reparse points after cleanup: $($left.FullName -join ', ')"
}

# ---------------------------------------------------------------------------
# 6. Smoke test (mandatory)
# ---------------------------------------------------------------------------
Write-Step 'Smoke testing staged rustc / cargo / rust-lld'
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'

$rustcOut = (& $rustcExe --version 2>&1) -join "`n"
$rustcCode = $LASTEXITCODE
$cargoOut = (& $cargoExe --version 2>&1) -join "`n"
$cargoCode = $LASTEXITCODE
# Exercise the driver exactly the way rustc will: the universal driver needs its
# flavor as argv[1] ("-flavor link"), which is also what proves the file is the
# multi-flavor rust-lld and not a single-flavor binary.
$lldOut = (& $rustLld -flavor link --version 2>&1) -join "`n"
$lldCode = $LASTEXITCODE
# The staged formatter must run on its own too (it is its own binary, not a
# cargo shim): proves bin\rustfmt.exe was merged and is executable.
$rustfmtOut = (& (Join-Path $StageDir 'bin\rustfmt.exe') --version 2>&1) -join "`n"
$rustfmtCode = $LASTEXITCODE
# `-vV` reports the host triple and `--print sysroot` the std/LLD root. Both
# come from rustc itself, so they catch a staged rustc that silently resolves
# its sysroot to some other toolchain on the machine.
$rustcVvOut     = (& $rustcExe -vV 2>&1) -join "`n"
$rustcVvCode    = $LASTEXITCODE
$rustcSysroot   = (& $rustcExe --print sysroot 2>&1) -join "`n"
$rustcSysrootCode = $LASTEXITCODE

$ErrorActionPreference = $prevEap
$rustVersionRe = [regex]::Escape($rustVersion)
if ($rustcCode -ne 0 -or $rustcOut -notmatch "rustc $rustVersionRe") {
    throw "rustc version mismatch (expected $rustVersion): $rustcOut"
}
if ($cargoCode -ne 0) { throw "cargo failed: $cargoOut" }
if ($lldCode -ne 0) { throw "rust-lld failed: $lldOut" }
if ($rustfmtCode -ne 0) { throw "rustfmt failed: $rustfmtOut" }
if ($rustcVvCode -ne 0 -or $rustcVvOut -notmatch ('(?m)^host: ' + [regex]::Escape($Target) + '$')) {
    throw "rustc -vV does not report host $Target :`n$rustcVvOut"
}
if ($rustcSysrootCode -ne 0) { throw "rustc --print sysroot failed: $rustcSysroot" }
$sysrootPath = $rustcSysroot.Trim()
if ($sysrootPath.TrimEnd('\') -ne $StageDir.TrimEnd('\')) {
    throw "rustc sysroot is '$sysrootPath' but the staged tree is '$StageDir' — std/LLD would be resolved from elsewhere"
}
$lldVer = if ($lldOut -match 'LLD (\S+)') { $Matches[1] } else { 'unknown' }
Write-Host "  $rustcOut"
Write-Host "  $cargoOut"
Write-Host "  rust-lld $lldOut"
Write-Host "  $rustfmtOut"

# ---------------------------------------------------------------------------
# 6b. Locate SDK library paths (relative to install root = StageDir).
#     All three lib dirs are required for linking: rustc std for
#     x86_64-pc-windows-msvc needs msvcrt/vcruntime (crt), ucrt (sdk\lib\ucrt)
#     and kernel32/ws2_32/bcrypt (sdk\lib\um). Missing vc dir means the linker
#     fails with unresolved symbols like __CxxFrameHandler3.
# ---------------------------------------------------------------------------
function Find-SdkLibDir([string]$directRel, [string]$fallbackRe) {
    $direct = Join-Path $sdkRoot $directRel
    if (Test-Path $direct) { return Get-Item $direct }
    Write-Host "  '$directRel' not found, falling back to recursive search"
    return (Get-ChildItem -Directory -Recurse -Filter 'x86_64' $sdkRoot |
        Where-Object { $_.FullName -match $fallbackRe } | Select-Object -First 1)
}

$vcLibDir   = Find-SdkLibDir 'crt\lib\x86_64'      '\\crt\\lib\\x86_64$'
$ucrtLibDir = Find-SdkLibDir 'sdk\lib\ucrt\x86_64' '\\lib\\ucrt\\x86_64$'
$umLibDir   = Find-SdkLibDir 'sdk\lib\um\x86_64'   '\\lib\\um\\x86_64$'

if (-not $ucrtLibDir) { throw 'Could not locate ucrt\x86_64 lib dir under sdk\ — xwin output may be malformed' }
if (-not $umLibDir)   { throw 'Could not locate um\x86_64 lib dir under sdk\ — xwin output may be malformed' }
if (-not $vcLibDir)   { throw 'Could not locate VC runtime lib dir (crt\lib\x86_64) — linking fails without vcruntime.lib' }

# Relative paths from StageDir (= install root); consumed by the smoke config,
# the staged template and the ISCC defines passed to setup.iss.
$ucrtRel = $ucrtLibDir.FullName.Substring($StageDir.Length).TrimStart('\')
$umRel   = $umLibDir.FullName.Substring($StageDir.Length).TrimStart('\')
$vcRel   = $vcLibDir.FullName.Substring($StageDir.Length).TrimStart('\')
Write-Host "  SDK ucrt lib : $ucrtRel"
Write-Host "  SDK um lib   : $umRel"
Write-Host "  SDK vc lib   : $vcRel"

# ---------------------------------------------------------------------------
# 6c. Smoke test: real cargo build (mandatory — proves SDK + LLD + rustc
#     work end-to-end on a clean machine without Visual Studio)
# ---------------------------------------------------------------------------
Write-Step 'Smoke testing real cargo build (cargo new + cargo build)'
$smokeTmp    = Join-Path $BuildDir 'smoke'
$smokeCargo  = Join-Path $smokeTmp '.cargo-home'
$smokeProj   = Join-Path $smokeTmp 'helloworld'
if (Test-Path $smokeTmp) { Remove-Item -Recurse -Force $smokeTmp }
New-Item -ItemType Directory -Force -Path $smokeCargo | Out-Null

# Build rustflags entries: ucrt + um + vc, all relative to StageDir.
$rustflagsLines = @(
    "    '-L', '$StageDir\$ucrtRel'",
    "    '-L', '$StageDir\$umRel'",
    "    '-L', '$StageDir\$vcRel'"
)
$rustflagsToml = ($rustflagsLines -join ",`n")

# Write a temporary cargo config that points at the bundled rust-lld driver
# (absolute path; see section 4 for why the universal driver is used instead of
# the gcc-ld wrapper) plus the SDK lib dirs. TOML literal strings (single
# quotes) keep Windows backslashes unescaped.
$smokeCfg = @"
[target.x86_64-pc-windows-msvc]
linker = '$rustLld'
rustflags = [
$rustflagsToml
]
"@
[IO.File]::WriteAllText((Join-Path $smokeCargo 'config.toml'), $smokeCfg, $utf8NoBom)

# Clear rustup env vars — windows-latest runner has rustup preinstalled.
# RUSTC/RUSTUP_TOOLCHAIN/RUSTUP_HOME would make cargo invoke the wrong rustc
# through rustup shims instead of our staged binaries.
$savedRustEnv = @{}
foreach ($var in @('RUSTC', 'RUSTUP_TOOLCHAIN', 'RUSTUP_HOME', 'RUSTUP_INIT_SKIP_PATH_CHECK')) {
    if (Test-Path "Env:\$var") { $savedRustEnv[$var] = (Get-Item "Env:\$var").Value }
    Remove-Item "Env:\$var" -ErrorAction SilentlyContinue
}

$env:PATH       = "$StageDir\bin;" + $env:PATH
$env:CARGO_HOME = $smokeCargo

# cargo writes ALL human-readable progress (e.g. "Creating binary ...") to
# stderr. Piping stderr through `2>&1` while $ErrorActionPreference='Stop' makes
# PowerShell 5.1 raise a terminating NativeCommandError on the very first
# stderr line, even when cargo actually succeeded. Switch to 'Continue' for this
# block, exactly like the rustc/cargo --version checks above do.
$prevSmokeEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'

Push-Location $smokeTmp
try {
    & $cargoExe new --bin --vcs none helloworld 2>&1 | ForEach-Object { Write-Host "  cargo new : $_" }
    if ($LASTEXITCODE -ne 0) { throw "cargo new failed with exit code $LASTEXITCODE" }

    # Replace the generated hello-world with a crate that calls a Win32 API
    # through an import library std never links (iphlpapi.lib). The explicit
    # `#[link]` forces the linker to resolve it from the staged sdk\lib\um dir, so
    # a wrong/missing UM lib path fails HERE instead of in the user's first
    # project. The source is rustfmt-clean because `cargo fmt --check` runs below.
    $mainRs = @'
#[link(name = "iphlpapi")]
unsafe extern "system" {
    fn GetNumberOfInterfaces(num_if: *mut u32) -> u32;
}

fn main() {
    let mut num_if: u32 = 0;
    let rc = unsafe { GetNumberOfInterfaces(&mut num_if) };
    println!("ifaces={num_if} rc={rc}");
}
'@
    # Here-strings drop the newline before the closing '@; rustfmt requires a
    # trailing newline, so add it explicitly (otherwise cargo fmt --check fails).
    [IO.File]::WriteAllText((Join-Path $smokeProj 'src\main.rs'), $mainRs + "`n", $utf8NoBom)

    Push-Location $smokeProj
    try {
        $buildLog = New-Object System.Collections.Generic.List[string]
        & $cargoExe build --release -v 2>&1 | ForEach-Object {
            $buildLog.Add([string]$_)
            Write-Host "  cargo build : $_"
        }
        if ($LASTEXITCODE -ne 0) { throw "cargo build failed with exit code $LASTEXITCODE" }

        # -v echoes rustc's command line; it must carry OUR rust-lld as the
        # linker. This is the only check that proves the CARGO_HOME config was
        # applied (cargo silently ignoring it would still link on a runner that
        # happens to have Visual Studio installed).
        if (($buildLog -join "`n") -notmatch [regex]::Escape($rustLld)) {
            throw "cargo did not pass the bundled rust-lld to rustc (cargo config not applied): $rustLld"
        }
    }
    finally { Pop-Location }

    $exe = Join-Path $smokeProj 'target\release\helloworld.exe'
    if (-not (Test-Path $exe)) { throw "cargo build did not produce $exe" }
    Write-Host "  smoke build OK => $exe ($((Get-Item $exe).Length) bytes)"

    # Run the produced PE: proves the binary actually resolves its imports.
    $exeOut = (& $exe 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "smoke binary exited with $LASTEXITCODE : $exeOut" }
    if ($exeOut -notmatch 'ifaces=\d+') { throw "smoke binary produced unexpected output: $exeOut" }
    Write-Host "  smoke run OK => $exeOut"

    # rustfmt / clippy through cargo's external-subcommand resolution: this
    # proves bin\cargo-fmt.exe and bin\cargo-clippy.exe are reachable via PATH
    # and that both tools really run (clippy lints the crate, fmt verifies it).
    & $cargoExe fmt --check 2>&1 | ForEach-Object { Write-Host "  cargo fmt : $_" }
    if ($LASTEXITCODE -ne 0) { throw "cargo fmt --check failed with exit code $LASTEXITCODE" }

    & $cargoExe clippy 2>&1 | ForEach-Object { Write-Host "  cargo clippy : $_" }
    if ($LASTEXITCODE -ne 0) { throw "cargo clippy failed with exit code $LASTEXITCODE" }
    Write-Host "  smoke rustfmt/clippy OK"
}
finally {
    Pop-Location
    $ErrorActionPreference = $prevSmokeEap
    Remove-Item -Recurse -Force $smokeTmp
    # Restore PATH and rustup env vars
    $originalPath = ($env:PATH -split ';' | Where-Object {
        $_ -and $_ -notmatch [regex]::Escape("$StageDir")
    }) -join ';'
    $env:PATH = $originalPath
    Remove-Item Env:\CARGO_HOME -ErrorAction SilentlyContinue
    foreach ($var in @('RUSTC', 'RUSTUP_TOOLCHAIN', 'RUSTUP_HOME', 'RUSTUP_INIT_SKIP_PATH_CHECK')) {
        Remove-Item "Env:\$var" -ErrorAction SilentlyContinue
        if ($savedRustEnv.ContainsKey($var)) { Set-Item "Env:\$var" $savedRustEnv[$var] }
    }
}

# ---------------------------------------------------------------------------
# 7. Compile installer
# ---------------------------------------------------------------------------
# The fallback %USERPROFILE%\.cargo\config.toml is generated by the installer
# itself (setup.iss) from the /DSdk*Path + /DSdkLldPath defines below, only when
# the machine has no usable MSVC toolchain. Nothing is staged into the install
# tree for it: the old staged .cargo\config.toml placeholder was never read by
# setup.iss and only left an empty .cargo\ directory behind after install.
$SetupName = "rust-$rustVersion-msvc-setup-x64"
$SetupExe  = Join-Path $OutDir "$SetupName.exe"

if (-not $SkipCompile) {
    Write-Step 'Locating Inno Setup compiler (ISCC.exe)'
    $iscc = @(
        $(if ($env:ISCC) { $env:ISCC }),
        'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
        'C:\Program Files\Inno Setup 6\ISCC.exe'
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $iscc) {
        $cmd = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
        if ($cmd) { $iscc = $cmd.Source }
    }
    if (-not $iscc) { throw 'ISCC.exe not found. Install Inno Setup 6 or use -SkipCompile.' }
    Write-Host "  $iscc"

    Write-Step 'Compiling installer'
    & $iscc (Join-Path $ScriptDir 'setup.iss') /Q `
        "/DMyAppVersion=$rustVersion" `
        "/DStageDir=$StageDir" `
        "/DOutputDir=$OutDir" `
        "/DOutputBaseFilename=$SetupName" `
        "/DSdkUcrtPath=$ucrtRel" `
        "/DSdkUmPath=$umRel" `
        "/DSdkVcPath=$vcRel" `
        "/DSdkLldPath=$rustLldRel"
    if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE" }
}
else {
    Write-Step 'Skipping installer compilation (-SkipCompile)'
}

# ---------------------------------------------------------------------------
# 8. Metadata / release notes / GitHub outputs
# ---------------------------------------------------------------------------
$stageBytes = [int64](Get-ChildItem -LiteralPath $StageDir -Recurse -File | Measure-Object Length -Sum).Sum
$buildInfo = [ordered]@{
    package         = 'rust'
    rustVersion     = $rustVersion
    channelDate     = $rustDate
    target          = $Target
    rustChannelUrl  = $channelUrlUsed
    componentUrls   = @($components | ForEach-Object { $_.Url })
    componentHashes = @($components | ForEach-Object { $_.Sha256 })
    lldVersion      = $lldVer
    lldSource       = 'rustc component (bundled rust-lld universal driver)'
    xwinVersion     = $XwinVersion
    xwinSource      = 'https://github.com/Jake-Shadle/xwin'
    sdkSource       = 'Microsoft official CDN (extracted via xwin)'
    defaultPath     = 'C:\pf\rust'
    pathEntries     = @('C:\pf\rust\bin', '%USERPROFILE%\.cargo\bin')
    components      = @($components | ForEach-Object { $_.Name })
    commands        = @('rustc', 'cargo', 'rustfmt', 'cargo fmt', 'cargo clippy')
    prunedPdbBytes  = $prunedPdbBytes
    stageBytes      = $stageBytes
    builtAt         = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}
if (-not $SkipCompile) {
    $hash = (Get-FileHash -Algorithm SHA256 $SetupExe).Hash.ToLower()
    $buildInfo['file'] = "$SetupName.exe"
    $buildInfo['size'] = (Get-Item $SetupExe).Length
    $buildInfo['sha256'] = $hash
    "$hash  $SetupName.exe" | Out-File -Encoding ascii (Join-Path $OutDir "$SetupName.exe.sha256.txt")
}
$buildInfo | ConvertTo-Json -Depth 4 |
    ForEach-Object { [IO.File]::WriteAllText((Join-Path $OutDir 'build-info.json'), $_, $utf8NoBom) }

if (-not $SkipCompile) {
    $notes = @"
# Rust $rustVersion MSVC Windows x64 一键安装包

## 组件版本

| 组件 | 版本 / 来源 |
| --- | --- |
| Rust | $rustVersion（stable channel，$rustDate） |
| rust-docs | 随 Rust $rustVersion（官方 rust-docs 组件，HTML 文档位于 ``<安装目录>\share\doc\rust\html``） |
| rustfmt | 随 Rust $rustVersion（官方 rustfmt-preview 组件，含 cargo-fmt） |
| clippy | 随 Rust $rustVersion（官方 clippy-preview 组件，含 clippy-driver） |
| 目标 | x86_64-pc-windows-msvc |
| LLD | $lldVer（rustc 官方组件内置 rust-lld 通用驱动，经 ``-flavor link`` 运行） |
| xwin | $XwinVersion（提取 Windows SDK / CRT） |

## 默认行为

- 默认安装目录：``C:\pf\rust``（安装向导中可修改）
- 安装后自动将 ``C:\pf\rust\bin`` 加入系统 PATH，新开命令行可直接使用 ``rustc``、``cargo``、``rustfmt``、``cargo fmt``、``cargo clippy``
- 同时把 ``%USERPROFILE%\.cargo\bin`` 加入用户 PATH（与官方 rustup 的做法一致），使 ``cargo install`` 装出的子命令可直接按名调用；卸载时仅回收由本安装器新增的条目
- 安装器在安装时探测系统 MSVC 工具链（VS C++ 工具 + Windows SDK）：
  - 探测到：完全按官方默认，**不写任何 cargo 配置**，rustc 自行发现 ``link.exe`` 与 SDK 库
  - 探测不到：启用包内 LLD（rustc 自带 rust-lld）与内置 Windows SDK / CRT 库（经 xwin 从微软官方 CDN 提取），并写入 ``%USERPROFILE%\.cargo\config.toml`` 配置链接器与库路径（卸载时回收该配置段）
- 安装/卸载对系统 PATH 均为幂等精确操作，不改动其他条目

## 重要说明

- 本包包含从微软官方 CDN 提取的 CRT/SDK 文件，用户需确认符合微软许可条款
- 链接器为 LLD（rustc 自带 rust-lld）：官方文档声明其 PDB 与原生 link.exe 同级，仅不支持已废弃的 /DEBUG:FASTLINK；超大 PDB 场景下 LLD 反而更稳
- 含 C 依赖的 crate 需自行配置 ``CC=clang-cl`` 及头文件路径

## 校验

SHA-256（$SetupName.exe）：

``$hash``
"@
    [IO.File]::WriteAllText((Join-Path $OutDir 'release-notes.md'), $notes, $utf8NoBom)
}

if ($env:GITHUB_OUTPUT) {
    "rust_version=$rustVersion"   | Out-File -Encoding ascii -Append $env:GITHUB_OUTPUT
    "setup_name=$SetupName.exe"   | Out-File -Encoding ascii -Append $env:GITHUB_OUTPUT
}

Write-Step 'Done'
if (-not $SkipCompile) {
    Write-Host "  Installer : $SetupExe"
    Write-Host "  SHA-256   : $hash"
}
else {
    Write-Host "  Staging   : $StageDir"
}
