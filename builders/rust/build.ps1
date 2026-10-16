<#
.SYNOPSIS
    Build the Rust MSVC one-click installer for Windows x64.

.DESCRIPTION
    - Resolves the latest stable Rust release via channel-rust-stable.toml
      (no hardcoded patch versions). Optionally pinned to an exact version.
    - Downloads rustc/cargo/rust-std for x86_64-pc-windows-msvc.
    - Downloads LLVM Clang for Windows (to extract lld-link.exe).
    - Downloads xwin and extracts Windows SDK / CRT headers and libraries.
    - Stages a unified tree at build/stage/rust (equals C:\pf\rust after install).
    - Runs mandatory smoke test: staged rustc/cargo must report exact versions.
    - Compiles an Inno Setup installer which installs to C:\pf\rust by default
      and appends the install dir to the system PATH.

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

# LLVM release to pull lld-link.exe from. Fixed version for reproducibility;
# bump when a new LLVM major is proven to work.
# NOTE: LLVM Windows releases are .tar.xz which Windows tar.exe cannot handle.
# We use the "LLVM-18.1.8-win64.exe" NSIS installer instead, extract with 7z.
$LlvmVersion = '18.1.8'
$LlvmAsset   = "LLVM-$LlvmVersion-win64.exe"
$LlvmUrl     = "https://github.com/llvm/llvm-project/releases/download/llvmorg-$LlvmVersion/$LlvmAsset"

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
    if ($currentSection -match '^pkg\.(rustc|cargo|rust-std)\.target\.' + [regex]::Escape($Target) + '$' -and
        $line -match '^url\s*=\s*"([^"]+\.tar\.gz)"') {
        $compName = ($currentSection -split '\.')[1]    # pkg.<name>.target...
        $targetUrls[$compName] = $Matches[1]
    }
}

if (-not $rustVersion) { throw "Could not parse rust version from $ChannelUrl" }
if (-not $rustDate)    { throw "Could not parse channel date from $ChannelUrl" }
if (-not $targetUrls['rustc'])    { throw "Could not resolve rustc URL for target $Target" }
if (-not $targetUrls['cargo'])    { throw "Could not resolve cargo URL for target $Target" }
if (-not $targetUrls['rust-std']) { throw "Could not resolve rust-std URL for target $Target" }

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
# If the user pinned a specific version, fall back to URL reconstruction.
$components = @(
    @{ Name = 'rustc';    Url = $targetUrls['rustc'] },
    @{ Name = 'cargo';    Url = $targetUrls['cargo'] },
    @{ Name = 'rust-std'; Url = $targetUrls['rust-std'] }
)
foreach ($comp in $components) {
    # If we pinned a version, the channel URL won't match — reconstruct it
    if ($comp.Url -notmatch ([regex]::Escape($rustVersion) + '-')) {
        $baseUrl = [regex]::Replace($comp.Url, '/[^/]+$', '')
        $comp.Url = "$baseUrl/$($comp.Name)-$rustVersion-$Target.tar.gz"
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

Write-Step 'Downloading LLVM (for lld-link.exe)'
$llvmDest = Join-Path $CacheDir $LlvmAsset
Download-File $LlvmUrl $llvmDest

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
# 4. Extract lld-link.exe from LLVM
# ---------------------------------------------------------------------------
Write-Step 'Extracting lld-link.exe from LLVM'
$llvmTmp = Join-Path $CacheDir 'extract-llvm'
if (Test-Path $llvmTmp) { Remove-Item -Recurse -Force $llvmTmp }
New-Item -ItemType Directory -Force -Path $llvmTmp | Out-Null

# LLVM Windows release is a NSIS installer. Extract with 7-Zip.
$7zCandidates = @(
    'C:\Program Files\7-Zip\7z.exe',
    'C:\Program Files (x86)\7-Zip\7z.exe'
)
$7z = $7zCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $7z) { throw "7-Zip not found (expected at one of: $($7zCandidates -join ', '))" }

& $7z x -o"$llvmTmp" -y $llvmDest | Out-Null
if ($LASTEXITCODE -ne 0) { throw "7z extraction failed for LLVM with exit code $LASTEXITCODE" }

$lldLink = Get-ChildItem -Recurse -Filter 'lld-link.exe' $llvmTmp | Select-Object -First 1
if (-not $lldLink) { throw "lld-link.exe not found in LLVM archive" }
Copy-Item -Force $lldLink.FullName (Join-Path $StageDir 'bin\')
Remove-Item -Recurse -Force $llvmTmp

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
# Windows symlink creation is a no-op in xwin, so no admin/developer-mode risk.
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
# 6. Smoke test (mandatory)
# ---------------------------------------------------------------------------
Write-Step 'Smoke testing staged rustc / cargo / lld-link'
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'

$rustcOut = (& $rustcExe --version 2>&1) -join "`n"
$rustcCode = $LASTEXITCODE
$cargoOut = (& $cargoExe --version 2>&1) -join "`n"
$cargoCode = $LASTEXITCODE
$lldOut = (& (Join-Path $StageDir 'bin\lld-link.exe') --version 2>&1) -join "`n"
$lldCode = $LASTEXITCODE

$ErrorActionPreference = $prevEap
$rustVersionRe = [regex]::Escape($rustVersion)
if ($rustcCode -ne 0 -or $rustcOut -notmatch "rustc $rustVersionRe") {
    throw "rustc version mismatch (expected $rustVersion): $rustcOut"
}
if ($cargoCode -ne 0) { throw "cargo failed: $cargoOut" }
if ($lldCode -ne 0) { throw "lld-link failed: $lldOut" }
Write-Host "  $rustcOut"
Write-Host "  $cargoOut"
Write-Host "  lld-link $lldOut"

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

# Write a temporary cargo config that points to lld-link + SDK libs.
# Use TOML literal strings (single quotes) so backslashes need no escaping.
$smokeCfg = @"
[target.x86_64-pc-windows-msvc]
linker = "lld-link"
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
# 7. Write cargo config template (informational; installer writes the real one)
# ---------------------------------------------------------------------------
# The installer writes %USERPROFILE%\.cargo\config.toml at ssPostInstall.
# We stage a template with __APP_DIR__ placeholder for reference / manual use.
$cargoConfigDir = Join-Path $StageDir '.cargo'
New-Item -ItemType Directory -Force -Path $cargoConfigDir | Out-Null
$templateLines = @(
    "    '-L', '__APP_DIR__\$ucrtRel'",
    "    '-L', '__APP_DIR__\$umRel'",
    "    '-L', '__APP_DIR__\$vcRel'"
)
$cargoConfig = @"
[target.x86_64-pc-windows-msvc]
linker = "lld-link"
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
        "/DSdkVcPath=$vcRel"
    if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE" }
}
else {
    Write-Step 'Skipping installer compilation (-SkipCompile)'
}

# ---------------------------------------------------------------------------
# 9. Metadata / release notes / GitHub outputs
# ---------------------------------------------------------------------------
$buildInfo = [ordered]@{
    package     = 'rust'
    rustVersion = $rustVersion
    channelDate = $rustDate
    target      = $Target
    llvmVersion = $LlvmVersion
    xwinVersion = $XwinVersion
    defaultPath = 'C:\pf\rust'
    pathEntries = @('C:\pf\rust\bin')
    commands    = @('rustc', 'cargo')
    builtAt     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
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
| 目标 | x86_64-pc-windows-msvc |
| LLD | $LlvmVersion（LLVM 官方 Release 提取 lld-link.exe） |
| xwin | $XwinVersion（提取 Windows SDK / CRT） |

## 默认行为

- 默认安装目录：``C:\pf\rust``（安装向导中可修改）
- 安装后自动将 ``C:\pf\rust\bin`` 加入系统 PATH，新开命令行可直接使用 ``rustc``、``cargo``
- 内置 lld-link.exe 作为链接器，无需 Visual Studio
- 内置 Windows SDK / CRT 头文件与库（经 xwin 从微软官方 CDN 提取）
- 安装器写 ``%USERPROFILE%\.cargo\config.toml`` 配置链接器与库路径
- 安装/卸载对系统 PATH 均为幂等精确操作，不改动其他条目

## 重要说明

- 本包包含从微软官方 CDN 提取的 CRT/SDK 文件，用户需确认符合微软许可条款
- 使用 LLD 作为链接器，调试信息（PDB）支持可能略逊于原生 link.exe
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
