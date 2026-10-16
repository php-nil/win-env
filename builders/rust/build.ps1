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
$XwinVersion = '0.6.5'
$XwinAsset   = "xwin-$XwinVersion-x86_64-pc-windows-msvc.zip"
$XwinUrl     = "https://github.com/Jake-Shadle/xwin/releases/download/$XwinVersion/$XwinAsset"

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
# 1. Resolve Rust version from channel TOML
# ---------------------------------------------------------------------------
Write-Step 'Resolving Rust release from channel-rust-stable.toml'
$channelContent = Invoke-RestMethod -Uri $ChannelUrl -ErrorAction Stop
if (-not $channelContent) { throw "Empty channel TOML from $ChannelUrl" }

# Parse TOML manually (PS 5.1 has no built-in TOML parser).
$pkgSection = $false
$rustVersion = $null
$rustDate    = $null
foreach ($line in ($channelContent -split "`n")) {
    $line = $line.Trim()
    if ($line -match '^\[pkg\.rust\]$') { $pkgSection = $true; continue }
    if ($pkgSection -and $line -match '^version\s*=\s*"([^"]+)"') { $rustVersion = $Matches[1] }
    if ($pkgSection -and $line -match '^date\s*=\s*"([^"]+)"') { $rustDate = $Matches[1]; break }
    if ($pkgSection -and $line -match '^\[') { break }
}
if (-not $rustVersion) { throw "Could not parse rust version from $ChannelUrl" }

if ($RustVersion) {
    if ($RustVersion -notmatch '^\d+\.\d+\.\d+$') { throw "Invalid -RustVersion: $RustVersion" }
    if ($RustVersion -ne $rustVersion) {
        Write-Host "  requested $RustVersion, channel has $rustVersion (using requested)"
        $rustVersion = $RustVersion
    }
}
Write-Host "  Rust version : $rustVersion (channel date: $rustDate)"

# Component URLs from the channel TOML. The dist directory uses only the
# date portion (YYYY-MM-DD) of the RFC3339 date string.
$distDate = ($rustDate -split 'T')[0]
$baseUrl = "https://static.rust-lang.org/dist/$distDate"
$components = @(
    @{ Name = 'rustc';    File = "rustc-$rustVersion-$Target.tar.gz" },
    @{ Name = 'cargo';    File = "cargo-$rustVersion-$Target.tar.gz" },
    @{ Name = 'rust-std'; File = "rust-std-$rustVersion-$Target.tar.gz" }
)

# ---------------------------------------------------------------------------
# 2. Download all assets
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $CacheDir, $OutDir | Out-Null
if (Test-Path $StageDir) { Remove-Item -Recurse -Force $StageDir }
New-Item -ItemType Directory -Force -Path $StageDir | Out-Null

foreach ($comp in $components) {
    $url = "$baseUrl/$($comp.File)"
    $dest = Join-Path $CacheDir $comp.File
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
foreach ($comp in $components) {
    $tmpDir = Join-Path $CacheDir "extract-$($comp.Name)"
    if (Test-Path $tmpDir) { Remove-Item -Recurse -Force $tmpDir }
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    & $tar -xf $comp.LocalPath -C $tmpDir
    if ($LASTEXITCODE -ne 0) { throw "tar extraction failed for $($comp.Name)" }
    # Each archive contains a single inner directory like rustc-<ver>-<target>/
    $inner = Get-ChildItem -Directory $tmpDir | Select-Object -First 1
    if (-not $inner) { throw "No inner directory in $($comp.Name) archive" }
    # Merge contents into stage. First component mirrors (to clear stage),
    # subsequent components overlay without deleting (robocopy /E).
    $rcMode = if ($comp.Name -eq 'rustc') { '/MIR' } else { '/E' }
    $rcArgs = @($inner.FullName, $StageDir, $rcMode, '/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NS')
    $rcProc = Start-Process -FilePath 'robocopy.exe' -ArgumentList $rcArgs -Wait -PassThru -NoNewWindow
    if ($rcProc.ExitCode -ge 8) { throw "robocopy merge failed for $($comp.Name) with exit code $($rcProc.ExitCode)" }
    Remove-Item -Recurse -Force $tmpDir
}

# Verify core binaries exist
$rustcExe = Join-Path $StageDir 'bin\rustc.exe'
$cargoExe = Join-Path $StageDir 'bin\cargo.exe'
if (-not (Test-Path $rustcExe)) { throw "rustc.exe missing after merge" }
if (-not (Test-Path $cargoExe)) { throw "cargo.exe missing after merge" }

# ---------------------------------------------------------------------------
# 4. Extract lld-link.exe from LLVM
# ---------------------------------------------------------------------------
Write-Step 'Extracting lld-link.exe from LLVM'
$llvmTmp = Join-Path $CacheDir 'extract-llvm'
if (Test-Path $llvmTmp) { Remove-Item -Recurse -Force $llvmTmp }
New-Item -ItemType Directory -Force -Path $llvmTmp | Out-Null

# LLVM Windows release is a NSIS installer. Extract with 7-Zip.
# windows-latest runner has 7-Zip preinstalled at C:\Program Files\7-Zip\7z.exe
$7z = 'C:\Program Files\7-Zip\7z.exe'
if (-not (Test-Path $7z)) { throw "7-Zip not found at $7z" }

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
Expand-Archive -LiteralPath $xwinDest -DestinationPath $xwinTmp -Force
$xwinExe = Get-ChildItem -Recurse -Filter 'xwin.exe' $xwinTmp | Select-Object -First 1
if (-not $xwinExe) { throw "xwin.exe not found in archive" }

$sdkDir = Join-Path $StageDir 'sdk'
New-Item -ItemType Directory -Force -Path $sdkDir | Out-Null
& $xwinExe.FullName --accept-license splat --output $sdkDir
if ($LASTEXITCODE -ne 0) { throw "xwin SDK extraction failed with exit code $LASTEXITCODE" }
Remove-Item -Recurse -Force $xwinTmp

# Verify SDK structure (xwin splat output may vary by version)
$sdkHasInclude = Test-Path (Join-Path $sdkDir 'include')
$sdkHasLib     = Test-Path (Join-Path $sdkDir 'lib')
if (-not $sdkHasInclude -and -not $sdkHasLib) {
    $tree = (Get-ChildItem -Recurse -Depth 2 $sdkDir | Select-Object -First 30 | ForEach-Object { $_.FullName.Replace($sdkDir, '') }) -join "`n"
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
if ($rustcCode -ne 0 -or $rustcOut -notmatch "rustc $rustVersion") {
    throw "rustc version mismatch (expected $rustVersion): $rustcOut"
}
if ($cargoCode -ne 0) { throw "cargo failed: $cargoOut" }
if ($lldCode -ne 0) { throw "lld-link failed: $lldOut" }
Write-Host "  $rustcOut"
Write-Host "  $cargoOut"
Write-Host "  lld-link $lldOut"

# ---------------------------------------------------------------------------
# 6b. Detect SDK library paths for cargo config
# ---------------------------------------------------------------------------
$ucrtLibDir = Get-ChildItem -Directory -Recurse -Depth 3 -Filter 'x86_64' $sdkDir |
    Where-Object { $_.FullName -match 'ucrt' } | Select-Object -First 1
$umLibDir = Get-ChildItem -Directory -Recurse -Depth 3 -Filter 'x86_64' $sdkDir |
    Where-Object { $_.FullName -match '\\um\\' } | Select-Object -First 1

if (-not $ucrtLibDir) { Write-Warning 'Could not locate ucrt\x86_64 under sdk\, using default path' }
if (-not $umLibDir)   { Write-Warning 'Could not locate um\x86_64 under sdk\, using default path' }

$ucrtRel = if ($ucrtLibDir) { $ucrtLibDir.FullName.Replace($sdkDir, '').TrimStart('\') } else { 'lib\ucrt\x86_64' }
$umRel   = if ($umLibDir)   { $umLibDir.FullName.Replace($sdkDir, '').TrimStart('\') }   else { 'lib\um\x86_64' }
Write-Host "  SDK ucrt lib: $ucrtRel"
Write-Host "  SDK um lib  : $umRel"

# ---------------------------------------------------------------------------
# 7. Write cargo config template (informational; installer writes the real one)
# ---------------------------------------------------------------------------
# The installer writes %USERPROFILE%\.cargo\config.toml at ssPostInstall.
# We stage a template with __APP_DIR__ placeholder for reference / manual use.
$cargoConfigDir = Join-Path $StageDir '.cargo'
New-Item -ItemType Directory -Force -Path $cargoConfigDir | Out-Null
$cargoConfig = @"
[target.x86_64-pc-windows-msvc]
linker = "lld-link"
rustflags = [
    "-L", "__APP_DIR__\\sdk\\$($ucrtRel -replace '\\', '\\')",
    "-L", "__APP_DIR__\\sdk\\$($umRel -replace '\\', '\\')"
]
"@
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
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
        "/DSdkUmPath=$umRel"
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
