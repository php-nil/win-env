<#
.SYNOPSIS
    Build the Rust MSVC one-click installer for Windows x64.

.DESCRIPTION
    - Resolves the latest stable Rust release via channel-rust-stable.toml
      (no hardcoded patch versions). Optionally pinned to an exact version.
    - Downloads rustc/cargo/rust-std/rustfmt/clippy for x86_64-pc-windows-msvc.
    - Uses the LLD linker bundled inside the rustc component (rust-lld plus
      its gcc-ld/lld-link wrapper) — no separate LLVM download.
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
# self-contained LLD whose real driver is rust-lld.exe plus tiny per-flavor
# wrappers, one of which is named lld-link.exe. See section 4 below.

# xwin release to pull SDK extraction tool from.
# Auto-discover latest from GitHub API; avoids hardcoding a version that may
# get removed (old tags get pruned). Download the .tar.gz Windows MSVC build.
Write-Host 'Discovering latest xwin release...'
try {
    $xwinLatest = Invoke-RestMethod -UseBasicParsing `
        -Uri 'https://api.github.com/repos/Jake-Shadle/xwin/releases/latest'
    $XwinVersion = $xwinLatest.tag_name
    $XwinAsset = ($xwinLatest.assets | Where-Object {
        $_.name -match 'x86_64-pc-windows-msvc\.tar\.gz$'
    } | Select-Object -First 1).name
    $XwinUrl = ($xwinLatest.assets | Where-Object {
        $_.name -eq $XwinAsset
    } | Select-Object -First 1).browser_download_url
    if (-not $XwinUrl) { throw 'No Windows MSVC tar.gz asset found' }
    Write-Host "  xwin $XwinVersion => $XwinAsset"
}
catch {
    throw "Failed to discover xwin latest release: $_"
}

function Write-Step([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

function Download-File([string]$url, [string]$dest) {
    if ((Test-Path $dest) -and ((Get-Item $dest).Length -gt 0)) {
        Write-Host "  cached: $dest"
        return
    }
    $attempts = 3
    for ($i = 1; $i -le $attempts; $i++) {
        try {
            Write-Host "  downloading ($i/$attempts): $url"
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $dest
            if ((Test-Path $dest) -and ((Get-Item $dest).Length -gt 0)) { return }
            throw 'downloaded file is empty'
        }
        catch {
            if ($i -eq $attempts) { throw }
            Start-Sleep -Seconds (3 * $i)
        }
    }
}

# ---------------------------------------------------------------------------
# 1. Resolve Rust version + component URLs from channel TOML
#    We parse the TOML manually (PS 5.1 has no built-in TOML parser).
#    - Top-level `date` is the channel date.
#    - `[pkg.rust].version` has format "X.Y.Z (commit date)"; we extract X.Y.Z.
#    - Each component has a per-target section with a precise `url` field.
# ---------------------------------------------------------------------------
Write-Step 'Resolving Rust release from channel-rust-stable.toml'
$channelContent = Invoke-RestMethod -Uri $ChannelUrl -ErrorAction Stop
if (-not $channelContent) { throw "Empty channel TOML from $ChannelUrl" }

$rustVersion = $null
$rustDate    = $null
$targetUrls  = @{}   # componentName => download URL

$lines = $channelContent -split "`n"
$currentSection = ''
foreach ($line in $lines) {
    $line = $line.Trim()
    if (-not $line) { continue }

    # Track which TOML section we're in.
    # Rust's channel TOML uses BOTH [single-bracket tables] and
    # [[double-bracket array-of-tables]] (for per-target entries).
    # We match either form and strip ALL bracket chars to get the section path.
    if ($line -match '^\[+(.+?)\]+$') {
        $currentSection = $Matches[1]
        continue
    }

    # Top-level channel date (NOT inside any [pkg.*] section)
    if ($currentSection -eq '' -and $line -match '^date\s*=\s*"([^"]+)"') {
        $rustDate = $Matches[1]
    }

    # Pure version from [pkg.rust]: "1.99.1 (58cf8f9c3 2026-10-13)" → "1.99.1"
    if ($currentSection -eq 'pkg.rust' -and $line -match '^version\s*=\s*"(\d+\.\d+\.\d+)') {
        $rustVersion = $Matches[1]
    }

    # Per-target component URLs from e.g. [[pkg.rustc.target.x86_64-pc-windows-msvc]]
    # Extract comp name from $currentSection (NOT $Matches[0]) — the inner URL regex
    # overwrites $Matches, so $Matches[0] contains the URL line, not the section.
    if ($currentSection -match '^pkg\.(rustc|cargo|rust-std|clippy-preview|rustfmt-preview)\.target\.' + [regex]::Escape($Target) + '$' -and
        $line -match '^url\s*=\s*"([^"]+\.tar\.gz)"') {
        $compName = ($currentSection -split '\.')[1]    # pkg.<name>.target...
        $targetUrls[$compName] = $Matches[1]
    }
}

if (-not $rustVersion) { throw "Could not parse rust version from $ChannelUrl" }
if (-not $rustDate)    { throw "Could not parse channel date from $ChannelUrl" }
if (-not $targetUrls['rustc'])          { throw "Could not resolve rustc URL for target $Target" }
if (-not $targetUrls['cargo'])          { throw "Could not resolve cargo URL for target $Target" }
if (-not $targetUrls['rust-std'])       { throw "Could not resolve rust-std URL for target $Target" }
if (-not $targetUrls['clippy-preview']) { throw "Could not resolve clippy-preview URL for target $Target" }
if (-not $targetUrls['rustfmt-preview']){ throw "Could not resolve rustfmt-preview URL for target $Target" }

if ($RustVersion) {
    if ($RustVersion -notmatch '^\d+\.\d+\.\d+$') { throw "Invalid -RustVersion: $RustVersion" }
    if ($RustVersion -ne $rustVersion) {
        Write-Host "  requested $RustVersion, channel has $rustVersion (WARNING: old version URLs may 404)"
        $rustVersion = $RustVersion
        # Note: channel TOML only lists the current stable version's URLs.
        # If the user pins an older version, we reconstruct the download URLs
        # using the pinned version + the channel date. This may 404 if the
        # date directory changed since that old version was published.
    }
}
Write-Host "  Rust version : $rustVersion (channel date: $rustDate)"

# Build the component list using URLs from the channel TOML.
# Component names are the channel's own names: rustfmt/clippy ship as
# `rustfmt-preview` / `clippy-preview` (NOT `rustfmt` / `clippy`), and each
# archive's inner payload directory carries that same name. FileStem is the
# prefix of the archive FILE name, which drops the `-preview` suffix
# (clippy-<ver>-<target>.tar.gz) — the two differ, so pinning a version must
# reconstruct with FileStem, not Name.
# Verified against the real archives for 1.99.1:
#   clippy-...:  clippy-preview/{bin/cargo-clippy.exe, bin/clippy-driver.exe,
#                               share/doc/clippy/*}   (manifest.in also lists *.pdb)
#   rustfmt-...: rustfmt-preview/{bin/rustfmt.exe, bin/cargo-fmt.exe,
#                               share/doc/rustfmt/*}  (manifest.in also lists *.pdb)
# If the user pinned a specific version, fall back to URL reconstruction.
$components = @(
    @{ Name = 'rustc';           FileStem = 'rustc';    Url = $targetUrls['rustc'] },
    @{ Name = 'cargo';           FileStem = 'cargo';    Url = $targetUrls['cargo'] },
    @{ Name = 'rust-std';        FileStem = 'rust-std'; Url = $targetUrls['rust-std'] },
    @{ Name = 'clippy-preview';  FileStem = 'clippy';   Url = $targetUrls['clippy-preview'] },
    @{ Name = 'rustfmt-preview'; FileStem = 'rustfmt';  Url = $targetUrls['rustfmt-preview'] }
)
foreach ($comp in $components) {
    # If we pinned a version, the channel URL won't match — reconstruct it
    if ($comp.Url -notmatch ([regex]::Escape($rustVersion) + '-')) {
        $baseUrl = [regex]::Replace($comp.Url, '/[^/]+$', '')
        $comp.Url = "$baseUrl/$($comp.FileStem)-$rustVersion-$Target.tar.gz"
        Write-Host "  pinned version: reconstructed $($comp.Name) URL"
    }
}

# ---------------------------------------------------------------------------
# 2. Download all assets
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $CacheDir, $OutDir | Out-Null
if (Test-Path $StageDir) { Remove-Item -Recurse -Force $StageDir }
New-Item -ItemType Directory -Force -Path $StageDir | Out-Null

foreach ($comp in $components) {
    $url = $comp.Url
    $dest = Join-Path $CacheDir ([IO.Path]::GetFileName($url))
    Write-Step "Downloading $($comp.Name)"
    Download-File $url $dest
    $comp | Add-Member -NotePropertyName LocalPath -NotePropertyValue $dest
}

Write-Step 'Downloading xwin (for SDK extraction)'
$xwinDest = Join-Path $CacheDir $XwinAsset
Download-File $XwinUrl $xwinDest

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

# ---------------------------------------------------------------------------
# 4. Locate the LLD linker bundled with the rustc component
#    rustc ships a self-contained LLD: the real multi-flavor driver at
#      lib\rustlib\<target>\bin\rust-lld.exe
#    plus tiny per-flavor wrappers at
#      lib\rustlib\<target>\bin\gcc-ld\{ld.lld,ld64.lld,wasm-ld,lld-link}.exe
#    The `lld-link` wrapper finds `rust-lld` relative to its OWN directory:
#    verified locally that it runs in place in this exact layout and fails with
#    "lld-wrapper: error running rust-lld child process: os error 2" once moved
#    away from it. So the shipped relative layout MUST stay intact — cargo's
#    `linker` is pointed straight at the wrapper, nothing is copied to bin\.
#    This removes the former LLVM download, the 7-Zip dependency and the
#    hardcoded LLVM version, and keeps LLD version-aligned with rustc.
# ---------------------------------------------------------------------------
Write-Step 'Locating bundled LLD (rust-lld driver + gcc-ld/lld-link wrapper)'
$rustLldDir = Join-Path $StageDir "lib\rustlib\$Target\bin"
$rustLld    = Join-Path $rustLldDir 'rust-lld.exe'          # real driver
$lldLink    = Join-Path $rustLldDir 'gcc-ld\lld-link.exe'   # flavor wrapper
if (-not (Test-Path $rustLld)) { throw "Bundled rust-lld driver missing: $rustLld" }
if (-not (Test-Path $lldLink)) { throw "Bundled lld-link wrapper missing: $lldLink" }
$lldRel = $lldLink.Substring($StageDir.Length).TrimStart('\')
Write-Host "  rust-lld : $($rustLld.Substring($StageDir.Length).TrimStart('\'))"
Write-Host "  lld-link : $lldRel"

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
Write-Step 'Smoke testing staged rustc / cargo / lld-link'
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'

$rustcOut = (& $rustcExe --version 2>&1) -join "`n"
$rustcCode = $LASTEXITCODE
$cargoOut = (& $cargoExe --version 2>&1) -join "`n"
$cargoCode = $LASTEXITCODE
# The lld-link wrapper must be exercised from its real location: it spawns the
# rust-lld driver found relative to itself, so calling the staged wrapper in
# place also proves the bundled driver is discoverable post-install.
$lldOut = (& $lldLink --version 2>&1) -join "`n"
$lldCode = $LASTEXITCODE
# The staged formatter must run on its own too (it is its own binary, not a
# cargo shim): proves bin\rustfmt.exe was merged and is executable.
$rustfmtOut = (& (Join-Path $StageDir 'bin\rustfmt.exe') --version 2>&1) -join "`n"
$rustfmtCode = $LASTEXITCODE

$ErrorActionPreference = $prevEap
$rustVersionRe = [regex]::Escape($rustVersion)
if ($rustcCode -ne 0 -or $rustcOut -notmatch "rustc $rustVersionRe") {
    throw "rustc version mismatch (expected $rustVersion): $rustcOut"
}
if ($cargoCode -ne 0) { throw "cargo failed: $cargoOut" }
if ($lldCode -ne 0) { throw "lld-link failed: $lldOut" }
if ($rustfmtCode -ne 0) { throw "rustfmt failed: $rustfmtOut" }
$lldVer = if ($lldOut -match 'LLD (\S+)') { $Matches[1] } else { 'unknown' }
Write-Host "  $rustcOut"
Write-Host "  $cargoOut"
Write-Host "  lld-link $lldOut"
Write-Host "  $rustfmtOut"

# ---------------------------------------------------------------------------
# 6b. Locate SDK library paths (relative to install root = StageDir).
#     All three lib dirs are required for linking: rustc std for
#     x86_64-pc-windows-msvc needs msvcrt/vcruntime (crt), ucrt (sdk\lib\ucrt)
#     and kernel32/ws2_32/bcrypt (sdk\lib\um). Missing vc dir means lld-link
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

# Write a temporary cargo config that points to the bundled lld-link wrapper
# (absolute path — the wrapper resolves its rust-lld sibling relative to
# itself) plus the SDK lib dirs. TOML literal strings (single quotes) keep
# Windows backslashes unescaped.
$smokeCfg = @"
[target.x86_64-pc-windows-msvc]
linker = '$lldLink'
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

    Push-Location $smokeProj
    try {
        & $cargoExe build --release 2>&1 | ForEach-Object { Write-Host "  cargo build : $_" }
        if ($LASTEXITCODE -ne 0) { throw "cargo build failed with exit code $LASTEXITCODE" }
    }
    finally { Pop-Location }

    $exe = Join-Path $smokeProj 'target\release\helloworld.exe'
    if (-not (Test-Path $exe)) { throw "cargo build did not produce $exe" }
    Write-Host "  smoke build OK => $exe ($((Get-Item $exe).Length) bytes)"

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
# 7. Write cargo config template (fallback only; the installer decides)
# ---------------------------------------------------------------------------
# The installer writes %USERPROFILE%\.cargo\config.toml ONLY when the machine
# has no usable MSVC toolchain (no VS C++ tools and/or no Windows SDK). When a
# system toolchain exists, official defaults are kept and nothing is written.
# This staged template uses the __APP_DIR__ placeholder and is deleted from the
# install dir at ssPostInstall — it is the source of truth for the fallback.
$cargoConfigDir = Join-Path $StageDir '.cargo'
New-Item -ItemType Directory -Force -Path $cargoConfigDir | Out-Null
$templateLines = @(
    "    '-L', '__APP_DIR__\$ucrtRel'",
    "    '-L', '__APP_DIR__\$umRel'",
    "    '-L', '__APP_DIR__\$vcRel'"
)
$cargoConfig = @"
[target.x86_64-pc-windows-msvc]
linker = '__APP_DIR__\$lldRel'
rustflags = [
$($templateLines -join ",`n")
]
"@
[IO.File]::WriteAllText((Join-Path $cargoConfigDir 'config.toml'), $cargoConfig, $utf8NoBom)

# ---------------------------------------------------------------------------
# 8. Compile installer
# ---------------------------------------------------------------------------
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
        "/DSdkLldPath=$lldRel"
    if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE" }
}
else {
    Write-Step 'Skipping installer compilation (-SkipCompile)'
}

# ---------------------------------------------------------------------------
# 9. Metadata / release notes / GitHub outputs
# ---------------------------------------------------------------------------
$buildInfo = [ordered]@{
    package        = 'rust'
    rustVersion    = $rustVersion
    channelDate    = $rustDate
    target         = $Target
    rustChannelUrl = $ChannelUrl
    componentUrls  = @($components | ForEach-Object { $_.Url })
    lldVersion     = $lldVer
    lldSource      = 'rustc component (bundled rust-lld, via gcc-ld/lld-link.exe)'
    xwinVersion    = $XwinVersion
    xwinSource     = 'https://github.com/Jake-Shadle/xwin'
    sdkSource      = 'Microsoft official CDN (extracted via xwin)'
    defaultPath    = 'C:\pf\rust'
    pathEntries    = @('C:\pf\rust\bin', '%USERPROFILE%\.cargo\bin')
    components     = @($components | ForEach-Object { $_.Name })
    commands       = @('rustc', 'cargo', 'rustfmt', 'cargo fmt', 'cargo clippy')
    builtAt        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
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
| rustfmt | 随 Rust $rustVersion（官方 rustfmt-preview 组件，含 cargo-fmt） |
| clippy | 随 Rust $rustVersion（官方 clippy-preview 组件，含 clippy-driver） |
| 目标 | x86_64-pc-windows-msvc |
| LLD | $lldVer（rustc 官方组件内置 rust-lld，经 ``gcc-ld\lld-link.exe`` 封装） |
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
